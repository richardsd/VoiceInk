import AVFoundation
import AppKit
import Foundation
import SwiftData
import SwiftUI
import os

private final class RealtimeAudioChunkGate: @unchecked Sendable {
    private struct State {
        var bufferedChunks: [Data] = []
        var callback: ((Data) -> Void)?
        var isActive = false
        var droppedChunks = 0
    }

    private let maxBufferedChunks = 2_048
    private let state = OSAllocatedUnfairLock(initialState: State())

    func receive(_ data: Data) {
        let callback = state.withLock { state -> ((Data) -> Void)? in
            guard state.isActive else {
                if state.bufferedChunks.count < maxBufferedChunks {
                    state.bufferedChunks.append(data)
                } else {
                    state.droppedChunks += 1
                }
                return nil
            }
            return state.callback
        }
        callback?(data)
    }

    func activate(_ callback: @escaping (Data) -> Void) -> Int {
        let initialState = state.withLock { state -> (chunks: [Data], droppedChunks: Int) in
            state.callback = callback
            state.isActive = false
            let chunks = state.bufferedChunks
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.droppedChunks = 0
            return (chunks, droppedChunks)
        }
        var chunksToSend = initialState.chunks
        var droppedChunks = initialState.droppedChunks

        while true {
            for chunk in chunksToSend {
                callback(chunk)
            }

            let nextState = state.withLock { state -> (chunks: [Data], droppedChunks: Int, finished: Bool) in
                let droppedChunks = state.droppedChunks
                state.droppedChunks = 0
                guard !state.bufferedChunks.isEmpty else {
                    state.isActive = true
                    return ([], droppedChunks, true)
                }
                let chunks = state.bufferedChunks
                state.bufferedChunks.removeAll()
                return (chunks, droppedChunks, false)
            }
            droppedChunks += nextState.droppedChunks

            if nextState.finished {
                return droppedChunks
            }
            chunksToSend = nextState.chunks
        }
    }

    func reset() -> Int {
        state.withLock { state -> Int in
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.callback = nil
            state.isActive = false
            state.droppedChunks = 0
            return droppedChunks
        }
    }
}

@MainActor
class VoiceInkEngine: NSObject, ObservableObject {
    private enum RecordingUseCase {
        case newSession
        case assistantFollowUp

        var isAssistantFollowUp: Bool {
            self == .assistantFollowUp
        }
    }

    @Published var recordingState: RecordingState = .idle
    @Published var shouldCancelRecording = false
    @Published var partialTranscript: String = ""
    @Published private(set) var pendingPasteReview: PendingPasteReview?
    @Published private(set) var haloReviewState: HaloReviewState?
    @Published private(set) var pasteReviewFeedback: PasteReviewFeedback?
    @Published private(set) var pasteReviewSecondsRemaining: Int?
    @Published private(set) var isPasteReviewRefocusing = false
    @Published private(set) var haloSessionDeliveryOverride: HaloSessionDeliveryOverride?
    @Published private(set) var isHaloVoiceRefinementReady = false
    @Published private(set) var haloVoiceInstructionAudioMeter = AudioMeter(
        averagePower: 0,
        peakPower: 0
    )
    @Published private(set) var haloVoiceInstructionPartialTranscript = ""
    @Published private(set) var haloVoiceCommandConfirmation: HaloVoiceCommandConfirmation?
    @Published private(set) var haloCapabilitySnapshot: HaloCapabilitySnapshot
    var currentSession: TranscriptionSession?
    private var currentSessionTranscriptionConfiguration: TranscriptionRuntimeConfiguration?
    private var activeRecordingStartID: UUID?
    private var activePipelineTranscriptionID: UUID?
    private var canceledPipelineTranscriptionIDs = Set<UUID>()
    private var activeRecordingUseCase: RecordingUseCase = .newSession
    private var activePipelineUseCase: RecordingUseCase = .newSession
    private var activeRecordingContextStore: RecordingContextSnapshotStore?
    private var activeRecordingContextTasks: [Task<Void, Never>] = []
    private var voiceInkRefinePreparationTask: Task<Void, Never>?
    private var pendingPasteReviewExpirationTask: Task<Void, Never>?
    private var haloRefinementTask: Task<Void, Never>?
    private var activeHaloRefinementRequestID: UUID?
    private var haloVoiceRefinementTask: Task<Void, Never>?
    private var activeHaloVoiceRefinementRequestID: UUID?
    private var pendingHaloVoiceStopRequestID: UUID?
    private var isResolvingPasteReview = false
    private var pasteReviewResolutionGate = PasteReviewResolutionGate()
    private var activePasteReviewDestination: PasteReviewDestinationSnapshot?

    let recorder = Recorder()
    var recordedFile: URL? = nil
    let recordingsDirectory: URL

    // Injected managers
    let whisperModelManager: WhisperModelManager
    let transcriptionModelManager: TranscriptionModelManager
    weak var recorderUIManager: RecorderPanelPresenting?

    let modelContext: ModelContext
    internal let serviceRegistry: TranscriptionServiceRegistry
    let enhancementService: AIEnhancementService?
    let assistantSession = AssistantSession()
    let assistantChat: AssistantChatService?
    private let pasteDeliveryService: any PasteDeliveryServicing
    private let pasteReviewDestinationService: any PasteReviewDestinationServicing
    private let haloDestinationRecoveryService: any HaloDestinationRecoveryServicing
    private let haloRefinementService: (any HaloRefinementServicing)?
    private let haloVoiceInstructionCaptureService: any HaloVoiceInstructionCaptureServicing
    private let haloOutcomeRecorder: any HaloOutcomeRecording
    private let haloCapabilityStore: HaloCapabilityStore
    private let pipeline: TranscriptionPipeline

    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VoiceInkEngine")

    init(
        modelContext: ModelContext,
        whisperModelManager: WhisperModelManager,
        transcriptionModelManager: TranscriptionModelManager,
        enhancementService: AIEnhancementService? = nil,
        pasteDeliveryService: (any PasteDeliveryServicing)? = nil,
        pasteReviewDestinationService: (any PasteReviewDestinationServicing)? = nil,
        haloDestinationRecoveryService: (any HaloDestinationRecoveryServicing)? = nil,
        haloRefinementService: (any HaloRefinementServicing)? = nil,
        haloVoiceInstructionCaptureService: (any HaloVoiceInstructionCaptureServicing)? = nil,
        haloOutcomeRecorder: (any HaloOutcomeRecording)? = nil,
        haloCapabilityStore: HaloCapabilityStore? = nil
    ) {
        self.modelContext = modelContext
        self.whisperModelManager = whisperModelManager
        self.transcriptionModelManager = transcriptionModelManager
        self.enhancementService = enhancementService
        if let aiService = enhancementService?.getAIService() {
            self.assistantChat = AssistantChatService(
                modelContext: modelContext,
                aiService: aiService
            )
        } else {
            self.assistantChat = nil
        }

        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
        self.recordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings")

        let serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: whisperModelManager,
            modelsDirectory: whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )
        self.serviceRegistry = serviceRegistry
        let resolvedPasteDeliveryService = pasteDeliveryService ?? PasteDeliveryService()
        self.pasteDeliveryService = resolvedPasteDeliveryService
        self.pasteReviewDestinationService = pasteReviewDestinationService ?? PasteReviewDestinationService()
        self.haloDestinationRecoveryService = haloDestinationRecoveryService
            ?? HaloDestinationRecoveryService()
        self.haloRefinementService = haloRefinementService
            ?? enhancementService.map(HaloRefinementService.init(enhancementService:))
        self.haloVoiceInstructionCaptureService = haloVoiceInstructionCaptureService
            ?? HaloVoiceInstructionCaptureService(serviceRegistry: serviceRegistry)
        self.haloOutcomeRecorder = haloOutcomeRecorder ?? HaloOutcomeMetricsStore.shared
        let resolvedHaloCapabilityStore = haloCapabilityStore ?? HaloCapabilityStore()
        self.haloCapabilityStore = resolvedHaloCapabilityStore
        self.haloCapabilitySnapshot = resolvedHaloCapabilityStore.snapshot
        self.pipeline = TranscriptionPipeline(
            modelContext: modelContext,
            serviceRegistry: serviceRegistry,
            enhancementService: enhancementService,
            pasteDeliveryService: resolvedPasteDeliveryService
        )

        super.init()

        setupNotifications()
        createRecordingsDirectoryIfNeeded()
    }

    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: recordingsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("❌ Error creating recordings directory: \(error, privacy: .public)")
        }
    }

    func getEnhancementService() -> AIEnhancementService? {
        return enhancementService
    }

    var pasteReviewIsExpiringSoon: Bool {
        pasteReviewSecondsRemaining.map(PasteReviewExpiration.isInWarningWindow) ?? false
    }

    var haloSessionDeliveryOverrideLabel: String? {
        switch haloSessionDeliveryOverride {
        case .forceDirect:
            return String(localized: "Quick Apply armed")
        case .forceReview:
            return String(localized: "Review this result")
        case nil:
            return nil
        }
    }

    func toggleHaloSessionDeliveryOverride() {
        guard recorderUIManager?.isHaloPanelActive == true else { return }
        switch recordingState {
        case .starting, .recording, .transcribing, .enhancing:
            let policy = ModeRuntimeResolver.outputConfiguration().haloDeliveryPolicy
            haloSessionDeliveryOverride = HaloSessionDeliveryOverrideResolver.toggled(
                current: haloSessionDeliveryOverride,
                policy: policy
            )
        case .idle, .busy, .reviewing:
            break
        }
    }

    func clearHaloSessionDeliveryOverride() {
        haloSessionDeliveryOverride = nil
    }

    // MARK: - Toggle Record

    func toggleRecord(modeId: UUID? = nil, isAssistantFollowUp: Bool = false) async {
        // Starting and stopping are only valid in the three interactive recorder
        // states. In particular, a consumed Halo review remains `.busy` until
        // both paste resolution and the originating pipeline cleanup finish.
        guard recordingState == .idle
            || recordingState == .starting
            || recordingState == .recording
        else {
            return
        }

        if recordingState == .starting {
            await cancelRecording()
            return
        }

        if recordingState == .recording {
            activePipelineUseCase = activeRecordingUseCase
            activeRecordingUseCase = .newSession
            activeRecordingStartID = nil
            partialTranscript = ""
            recordingState = .transcribing
            await recorder.stopRecording()

            if let recordedFile {
                if !shouldCancelRecording {
                    let transcription = makeRecordingTranscription(
                        for: recordedFile,
                        text: "",
                        duration: 0,
                        transcriptionStatus: .pending
                    )
                    modelContext.insert(transcription)
                    try? modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

                    await runPipeline(
                        on: transcription,
                        audioURL: recordedFile,
                        contextStore: activeRecordingContextStore
                    )
                } else {
                    await finishActiveRecorderCancellation()
                }
            } else {
                cancelCurrentSession()
                if !shouldCancelRecording {
                    logger.error("❌ No recorded file found after stopping recording")
                }
                recordingState = .idle
                await cleanupResources()
            }
        } else {
            let canContinueAssistantSession = isAssistantFollowUp && assistantSession.canSendFollowUp
            let recordingUseCase: RecordingUseCase = canContinueAssistantSession ? .assistantFollowUp : .newSession

            activePipelineTranscriptionID = nil
            haloSessionDeliveryOverride = nil
            activePasteReviewDestination = recordingUseCase.isAssistantFollowUp
                ? nil
                : ((recorderUIManager as? any PasteReviewDestinationProviding)?.pasteReviewDestinationSnapshot
                    ?? pasteReviewDestinationService.frontmostApplicationSnapshot())
            shouldCancelRecording = false
            partialTranscript = ""
            activeRecordingUseCase = recordingUseCase
            clearActiveRecordingContext()

            if !recordingUseCase.isAssistantFollowUp {
                assistantSession.reset()
            }

            requestRecordPermission { [self] granted in
                if granted {
                    Task { @MainActor [self] in
                        guard await self.passesRecordingPreflight() else {
                            return
                        }

                        let startID = UUID()
                        self.activeRecordingStartID = startID
                        let activeModeTask = ActiveWindowService.shared.beginApplyingConfiguration(modeId: modeId) {
                            [weak self] in
                            guard let self else { return false }
                            return self.activeRecordingStartID == startID && !self.shouldCancelRecording
                        }

                        do {
                            let fileName = "\(UUID().uuidString).wav"
                            let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
                            self.recordedFile = permanentURL

                            let realtimeAudioGate = RealtimeAudioChunkGate()
                            self.recorder.onAudioChunk = realtimeAudioGate.receive

                            self.recordingState = .starting

                            try await self.recorder.startRecording(toOutputFile: permanentURL)

                            guard self.activeRecordingStartID == startID,
                                self.recorderUIManager?.isRecorderPanelVisible ?? false,
                                !self.shouldCancelRecording
                            else {
                                activeModeTask.cancel()
                                let shouldKeepRecordingFile = self.shouldCancelRecording
                                if self.activeRecordingStartID == startID {
                                    await self.recorder.stopRecording()
                                    if !shouldKeepRecordingFile {
                                        self.recordedFile = nil
                                    }
                                    self.recordingState = .idle
                                    self.activeRecordingStartID = nil
                                }
                                return
                            }

                            self.recordingState = .recording

                            await activeModeTask.value

                            guard self.recordingState == .recording,
                                self.activeRecordingStartID == startID,
                                !self.shouldCancelRecording
                            else {
                                return
                            }

                            self.recorderUIManager?.reconcileRecorderPanel(
                                for: ModeRuntimeResolver.outputConfiguration().outputMode
                            )

                            self.startRecordingContextCapture()

                            let modelResolution = ModeRuntimeResolver.transcriptionModelResolution(
                                transcriptionModelManager: self.transcriptionModelManager
                            )
                            guard
                                let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                                    from: modelResolution
                                )
                            else {
                                let failure = self.recordingModelFailure(for: modelResolution)
                                NotificationManager.shared.showNotification(
                                    title: failure.title,
                                    type: .error,
                                    duration: 7.0,
                                    actionButton: (failure.actionLabel, failure.action)
                                )
                                await self.recorder.stopRecording()
                                try? FileManager.default.removeItem(at: permanentURL)
                                self.recordedFile = nil
                                self.recordingState = .idle
                                self.activeRecordingStartID = nil
                                self.clearActiveRecordingContext()
                                await self.cleanupResources()
                                await self.recorderUIManager?.dismissRecorderPanel()
                                return
                            }

                            if self.serviceRegistry.shouldUseRealtimeTranscription(for: transcriptionConfiguration) {
                                let session = self.serviceRegistry.createSession(
                                    for: transcriptionConfiguration,
                                    onPartialTranscript: { [weak self] partial in
                                        Task { @MainActor in
                                            guard let self,
                                                self.activeRecordingStartID == startID,
                                                self.recordingState == .recording
                                            else {
                                                return
                                            }
                                            self.partialTranscript = partial
                                        }
                                    }
                                )
                                self.currentSession = session
                                self.currentSessionTranscriptionConfiguration = transcriptionConfiguration
                                let realCallback = try await session.prepare(
                                    configuration: transcriptionConfiguration
                                )

                                if let realCallback {
                                    let droppedStartupChunks = realtimeAudioGate.activate(realCallback)
                                    if droppedStartupChunks > 0 {
                                        self.logger.warning(
                                            "Realtime startup audio gate dropped \(droppedStartupChunks, privacy: .public) chunks before streaming became active"
                                        )
                                    }
                                } else {
                                    _ = realtimeAudioGate.reset()
                                    self.recorder.onAudioChunk = nil
                                }
                            } else {
                                self.currentSession = nil
                                self.currentSessionTranscriptionConfiguration = nil
                                self.recorder.onAudioChunk = nil
                                _ = realtimeAudioGate.reset()
                            }

                            self.scheduleVoiceInkRefinePreparation(for: startID)

                            Task { @MainActor [weak self] in
                                guard let self else { return }

                                let currentModel = ModeRuntimeResolver.transcriptionConfiguration(
                                    transcriptionModelManager: self.transcriptionModelManager
                                )?.model

                                if let model = currentModel,
                                    model.provider == .whisper
                                {
                                    if let localWhisperModel = self.whisperModelManager.availableModels.first(where: {
                                        $0.name == model.name
                                    }),
                                        self.whisperModelManager.whisperContext == nil
                                    {
                                        do {
                                            try await self.whisperModelManager.loadModel(localWhisperModel)
                                        } catch {
                                            self.logger.error("❌ Model loading failed: \(error, privacy: .public)")
                                        }
                                    }
                                } else if let fluidAudioModel = currentModel as? FluidAudioModel {
                                    try? await self.serviceRegistry.fluidAudioTranscriptionService.loadModel(
                                        for: fluidAudioModel)
                                } else if let transcribeCppModel = currentModel as? TranscribeCppModel {
                                    try? await self.serviceRegistry.transcribeCppTranscriptionService.loadModel(
                                        for: transcribeCppModel)
                                }

                            }

                        } catch {
                            activeModeTask.cancel()
                            self.logger.error("Recording failed to start: \(error, privacy: .public)")
                            let audioFailure = self.recordingAudioFailure(for: error)
                            if audioFailure == nil {
                                await self.recorder.stopRecording()
                            }
                            self.cancelCurrentSession()
                            if let recordedFile = self.recordedFile {
                                try? FileManager.default.removeItem(at: recordedFile)
                            }
                            self.recordingState = .idle
                            self.recordedFile = nil
                            self.activeRecordingStartID = nil
                            self.clearActiveRecordingContext()
                            await self.cleanupResources()
                            if let failure = audioFailure {
                                NotificationManager.shared.showNotification(
                                    title: failure.title,
                                    type: .error,
                                    duration: 7.0,
                                    actionButton: (failure.actionLabel, failure.action)
                                )
                            } else {
                                NotificationManager.shared.showNotification(
                                    title: String(localized: "Recording failed to start"), type: .error)
                            }
                            await self.recorderUIManager?.dismissRecorderPanel()
                        }
                    }
                } else {
                    logger.error("Recording permission denied")
                }
            }
        }
    }

    private func requestRecordPermission(response: @escaping (Bool) -> Void) {
        response(true)
    }

    @MainActor
    private func recordingModelFailure(
        for resolution: ModeTranscriptionModelResolution
    ) -> (title: String, actionLabel: String, action: () -> Void) {
        switch resolution {
        case .noMode:
            return (
                String(localized: "No mode configured"),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .noSelection(let mode):
            return (
                String(
                    format: String(localized: "No transcription model is selected for the '%@' mode"),
                    mode.name
                ),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .modelNotFound(let mode):
            return (
                String(
                    format: String(localized: "The transcription model selected for the '%@' mode is unavailable"),
                    mode.name
                ),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .unavailable(let mode, let model), .available(let mode, let model):
            return (
                String(
                    format: String(localized: "'%@' is not available for the %@ mode"),
                    model.displayName,
                    mode.name
                ),
                String(localized: "Manage AI Models"),
                ModeSetupNavigator.openModelsSettings
            )
        }
    }

    /// Checks requirements that do not depend on asynchronous app and URL mode resolution.
    @MainActor
    private func passesRecordingPreflight() async -> Bool {
        if !ModeManager.shared.hasEnabledConfiguration {
            await failRecordingPreflight(
                title: String(localized: "No mode configured"),
                actionLabel: String(localized: "Manage Modes"),
                action: ModeSetupNavigator.openModesSettings
            )
            return false
        }

        return true
    }

    @MainActor
    private func failRecordingPreflight(
        title: String,
        actionLabel: String,
        action: @escaping () -> Void
    ) async {
        logger.error("❌ Recording preflight failed: \(title, privacy: .public)")
        recordingState = .idle
        NotificationManager.shared.showNotification(
            title: title,
            type: .error,
            duration: 7.0,
            actionButton: (actionLabel, action)
        )
        await recorderUIManager?.dismissRecorderPanel()
    }

    // MARK: - Recording Context

    private func startRecordingContextCapture() {
        clearActiveRecordingContext()

        let store = RecordingContextSnapshotStore()
        activeRecordingContextStore = store
        activeRecordingContextTasks = RecordingContextCaptureService.startCapture(into: store)
    }

    private func clearActiveRecordingContext() {
        activeRecordingContextTasks.forEach { $0.cancel() }
        activeRecordingContextTasks.removeAll()
        activeRecordingContextStore = nil
    }

    // MARK: - Pipeline Dispatch

    private func runPipeline(
        on transcription: Transcription,
        audioURL: URL,
        contextStore: RecordingContextSnapshotStore?
    ) async {
        guard
            let transcriptionConfiguration = currentSessionTranscriptionConfiguration
                ?? ModeRuntimeResolver.transcriptionConfiguration(transcriptionModelManager: transcriptionModelManager)
        else {
            transcription.text = String(localized: "Transcription Failed: No model selected")
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            try? modelContext.save()
            recordingState = .idle
            activePipelineUseCase = .newSession
            return
        }

        let session = currentSession
        let transcriptionID = transcription.id
        activePipelineTranscriptionID = transcriptionID

        let pipelineOutcome = await pipeline.run(
            transcription: transcription,
            audioURL: audioURL,
            transcriptionConfiguration: transcriptionConfiguration,
            formattingConfiguration: {
                ModeRuntimeResolver.transcriptionFormattingConfiguration()
            },
            session: session,
            triggerWordModeSelection: { [weak self] text in
                self?.selectTriggerWordModeIfNeeded(for: text)
            },
            enhancementConfiguration: { [weak self] in
                guard let self,
                    let enhancementService = self.enhancementService,
                    let aiService = enhancementService.getAIService()
                else {
                    return nil
                }
                return ModeRuntimeResolver.currentEnhancementConfiguration(
                    enhancementService: enhancementService,
                    aiService: aiService
                )
            },
            recordingContextSnapshot: {
                await MainActor.run {
                    contextStore?.snapshot
                }
            },
            outputConfiguration: {
                ModeRuntimeResolver.outputConfiguration()
            },
            onOutputConfigurationResolved: { [weak self] output in
                guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                self.recorderUIManager?.reconcileRecorderPanel(for: output.outputMode)
            },
            onStateChange: { [weak self] state in
                guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                self.recordingState = state
            },
            shouldCancel: { [weak self] in
                guard let self else { return false }
                return self.canceledPipelineTranscriptionIDs.contains(transcriptionID)
                    || (self.activePipelineTranscriptionID == transcriptionID && self.shouldCancelRecording)
            },
            onCancel: { [weak self, session] in
                guard let self else { return }
                self.cancelPipelineSession(transcriptionID: transcriptionID, session: session)
            },
            onDismiss: { [weak self] in
                guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                await self.recorderUIManager?.dismissRecorderPanel()
            },
            shouldUseHaloDelivery: { [weak self] output in
                output.outputMode == .paste
                    && self?.recorderUIManager?.isHaloPanelActive == true
            },
            haloSessionOverride: { [weak self] in
                self?.haloSessionDeliveryOverride
            },
            handleHaloPaste: { [weak self] review, route in
                guard let self, self.activePipelineTranscriptionID == transcriptionID else { return false }
                return await self.handleHaloPaste(review, route: route)
            },
            assistant: TranscriptionPipeline.AssistantHooks(
                isFollowUp: activePipelineUseCase.isAssistantFollowUp,
                sendFollowUp: { [weak self] text, transcription in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    await self.sendAssistantFollowUp(text, transcription: transcription)
                },
                startResponse: { [weak self] transcript, configuration in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    self.assistantSession.beginInitialResponse(
                        transcript: transcript,
                        provider: configuration.provider,
                        modelName: configuration.modelName ?? configuration.provider?.defaultModel,
                        modeName: configuration.mode?.name,
                        modeEmoji: configuration.mode?.icon.value,
                        promptName: configuration.prompt?.title
                    )
                },
                showResponse: { [weak self] response, systemPrompt in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    await self.completeAssistantResponse(response, systemPrompt: systemPrompt)
                },
                failResponse: { [weak self] message in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    self.assistantSession.fail(message)
                }
            )
        )

        let didFinishActivePipeline = activePipelineTranscriptionID == transcriptionID
        if didFinishActivePipeline {
            // A trigger word can switch an armed Halo session to Respond or
            // Custom Command after the override was chosen. Those routes never
            // enter `handleHaloPaste`, so clear the session-only choice when
            // their delivery completes as well.
            haloSessionDeliveryOverride = nil
            await cleanupResources()
            activePipelineTranscriptionID = nil
            currentSession = nil
            currentSessionTranscriptionConfiguration = nil
            recordedFile = nil
            shouldCancelRecording = false
            activePipelineUseCase = .newSession
            activePasteReviewDestination = nil
            clearActiveRecordingContext()
            if pendingPasteReview?.transcriptionID == transcriptionID {
                isHaloVoiceRefinementReady = haloReviewState?.session.transcriptionConfiguration != nil
            }
        }
        canceledPipelineTranscriptionIDs.remove(transcriptionID)

        if didFinishActivePipeline
            && pipelineOutcome == .noSpeechDetected
        {
            recordingState = .idle
            recorderUIManager?.showNoSpeechDetected()
        } else if didFinishActivePipeline
            && PasteReviewLifecycle.canReturnToIdle(
                hasActivePipeline: false,
                isResolvingReview: isResolvingPasteReview
            )
            && (recordingState == .transcribing || recordingState == .enhancing || recordingState == .busy)
        {
            recordingState = .idle
        }
    }

    private func selectTriggerWordModeIfNeeded(for text: String) -> String? {
        guard let (triggeredMode, processedText) = ModeManager.shared.getConfigurationForTriggerWord(text) else {
            return nil
        }

        ModeManager.shared.setActiveConfiguration(triggeredMode)
        return processedText
    }

    // MARK: - Halo Paste Review

    private func handleHaloPaste(
        _ review: PendingPasteReview,
        route: HaloDeliveryRoute
    ) async -> Bool {
        guard pendingPasteReview == nil,
            recorderUIManager?.isHaloPanelActive == true
        else {
            return false
        }

        let capturedDestination = (recorderUIManager as? any PasteReviewDestinationProviding)?
            .pasteReviewDestinationSnapshot
            ?? activePasteReviewDestination
            ?? pasteReviewDestinationService.frontmostApplicationSnapshot()
        let stagedReview = review.withDestination(capturedDestination)

        // The route has now consumed the explicit session choice. A later Mode
        // change cannot alter this delivery, and the next recording starts clean.
        haloSessionDeliveryOverride = nil

        switch route {
        case .review:
            return stagePasteReview(stagedReview, notifyReady: true)
        case .direct:
            return await deliverHaloDirect(stagedReview)
        }
    }

    /// Internal to support deterministic review-orchestration tests without
    /// Accessibility access, keyboard events, or a live transcription run.
    func stagePasteReview(
        _ review: PendingPasteReview,
        feedback: PasteReviewFeedback? = nil,
        notifyReady: Bool
    ) -> Bool {
        guard pendingPasteReview == nil,
            recorderUIManager?.isHaloPanelActive == true
        else {
            return false
        }

        // Keyboard shortcuts are additive. If the event tap cannot be installed,
        // Halo remains in the safe review route and its mouse controls stay usable.
        _ = recorderUIManager?.preparePasteReviewKeyboardHandling()
        guard pasteReviewResolutionGate.stage(review.id) else {
            recorderUIManager?.finishPasteReviewKeyboardHandling()
            return false
        }

        pendingPasteReview = review
        haloReviewState = makeHaloReviewState(from: review)
        isHaloVoiceRefinementReady = activePipelineTranscriptionID == nil
            && review.transcriptionConfiguration != nil
        haloVoiceCommandConfirmation = nil
        resetHaloVoiceInstructionPresentation()
        pasteReviewFeedback = feedback
        haloOutcomeRecorder.record(.reviewShown)
        if feedback?.allowsRefocus == true {
            haloOutcomeRecorder.record(.destinationMismatch)
        }
        recordingState = .reviewing
        recorderUIManager?.presentPasteReview(review)
        schedulePasteReviewInactivity(for: review.id)
        if notifyReady {
            pasteDeliveryService.notifyReviewReady()
        }
        announcePasteReviewReady()
        return true
    }

    private func makeHaloReviewState(from review: PendingPasteReview) -> HaloReviewState {
        let metadata = HaloReviewModelMetadata(
            modeName: review.modeName,
            modeEmoji: review.modeEmoji,
            providerLabel: review.providerLabel,
            connectionLabel: review.connectionLabel,
            modelLabel: review.modelLabel
        )
        let session = HaloReviewSession(
            id: review.id,
            transcriptionID: review.transcriptionID,
            rawText: review.rawText,
            initialEnhancement: review.enhancementWarning == nil ? review.finalText : nil,
            destination: review.destination,
            metadata: metadata,
            enhancementWarning: review.enhancementWarning,
            deliveryReviewReason: review.deliveryReviewReason,
            output: review.output,
            transcriptionConfiguration: review.transcriptionConfiguration,
            enhancementConfiguration: review.enhancementConfiguration,
            refinementInputSnapshot: review.refinementInputSnapshot,
            frozenContext: review.frozenContext
        )
        let revision = HaloReviewRevision(
            parentID: nil,
            action: .initial,
            text: review.finalText,
            metadata: metadata,
            payload: review.payload
        )
        return HaloReviewState(session: session, initialRevision: revision)
    }

    private func deliverHaloDirect(_ review: PendingPasteReview) async -> Bool {
        if let destination = review.destination {
            let validation = await pasteReviewDestinationService.validate(destination)

            guard activePipelineTranscriptionID == review.transcriptionID,
                pendingPasteReview == nil
            else {
                return true
            }

            if case .mismatch(let mismatch) = validation {
                return stagePasteReview(
                    review,
                    feedback: .destinationChanged(mismatch),
                    notifyReady: true
                )
            }
        }

        guard let recoveryPresenter = recorderUIManager as? any PasteReviewRecoveryPresenting else {
            return stagePasteReview(
                review,
                feedback: .deliveryUnavailable,
                notifyReady: true
            )
        }

        recordingState = .busy
        let outcome = await pasteDeliveryService.deliver(
            review.payload,
            dismiss: {
                recoveryPresenter.hidePasteReviewForDelivery()
            },
            playStopSound: true
        )
        HaloTranscriptionFinalizer.finalizeIfCommandPosted(
            outcome: outcome,
            transcriptionID: review.transcriptionID,
            payload: review.payload,
            modelContext: modelContext
        )

        switch outcome {
        case .commandPosted:
            haloOutcomeRecorder.record(.directPaste)
            if review.enhancementWarning != nil {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Enhancement was unavailable. Pasted the raw transcript."),
                    type: .warning
                )
            }
            recorderUIManager?.showHaloPasteConfirmation()
            return true

        case .commandNotPosted:
            recordingState = .reviewing
            let staged = stagePasteReview(
                review,
                feedback: .pasteFailed,
                notifyReady: false
            )
            if staged {
                recoveryPresenter.restorePasteReviewAfterFailedDelivery()
            }
            return staged
        }
    }

    func approvePendingPasteReview() async {
        if haloVoiceCommandConfirmation != nil {
            _ = await confirmHaloVoiceCommandIfActive()
            return
        }

        guard let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            let reviewState = haloReviewState,
            reviewState.session.id == review.id,
            !reviewState.isRefining,
            !reviewState.isVoiceRefinementActive,
            !reviewState.isEditingManually,
            let approvedRevision = reviewState.selectedRevision
        else {
            return
        }

        // Bind this Apply action to exactly one immutable revision before AX
        // destination validation suspends. A refinement that starts or selects
        // a replacement while validation is in flight requires a fresh Apply.
        let approvedRevisionID = approvedRevision.id
        let payload = approvedRevision.payload

        guard !reviewState.isExpired,
            reviewState.secondsRemaining() > 0
        else {
            await cancelPendingPasteReview(reason: .expiry)
            return
        }

        if isPasteReviewRefocusing {
            await completePasteReviewFocusRecovery(review: review)
            return
        }

        if let destination = review.destination {
            let validation = await pasteReviewDestinationService.validate(destination)

            // Validation suspends while AX is queried. Re-check both review and
            // revision identity so Apply cannot cross a refinement boundary.
            guard pendingPasteReview?.id == review.id,
                pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
                let currentState = haloReviewState,
                currentState.session.id == review.id,
                !currentState.isRefining,
                !currentState.isVoiceRefinementActive,
                !currentState.isEditingManually,
                currentState.selectedRevision?.id == approvedRevisionID
            else {
                return
            }

            if case .mismatch(let mismatch) = validation {
                haloOutcomeRecorder.record(.destinationMismatch)
                pasteReviewFeedback = .destinationChanged(mismatch)
                return
            }
        }

        guard let recoveryPresenter = recorderUIManager as? any PasteReviewRecoveryPresenting else {
            pasteReviewFeedback = .deliveryUnavailable
            return
        }

        guard pasteReviewResolutionGate.beginDelivery(review.id) else { return }
        pendingPasteReviewExpirationTask?.cancel()
        pendingPasteReviewExpirationTask = nil
        pasteReviewSecondsRemaining = nil
        pasteReviewFeedback = nil
        isResolvingPasteReview = true
        recordingState = .busy

        let outcome = await pasteDeliveryService.deliver(
            payload,
            dismiss: {
                recoveryPresenter.hidePasteReviewForDelivery()
            },
            playStopSound: false
        )
        HaloTranscriptionFinalizer.finalizeIfCommandPosted(
            outcome: outcome,
            transcriptionID: review.transcriptionID,
            payload: payload,
            modelContext: modelContext
        )

        switch outcome {
        case .commandPosted:
            haloOutcomeRecorder.record(.apply)
            guard pasteReviewResolutionGate.completeDelivery(review.id) else { return }
            clearPendingPasteReviewPresentation()
            await recorderUIManager?.dismissRecorderPanel()
            finishPasteReviewResolution()

        case .commandNotPosted:
            guard pendingPasteReview?.id == review.id else { return }

            guard haloReviewState?.isExpired != true,
                (haloReviewState?.secondsRemaining() ?? 0) > 0
            else {
                _ = pasteReviewResolutionGate.completeDelivery(review.id)
                clearPendingPasteReviewPresentation()
                await recorderUIManager?.dismissRecorderPanel()
                finishPasteReviewResolution()
                return
            }

            guard pasteReviewResolutionGate.restoreAfterFailure(review.id) else { return }
            isResolvingPasteReview = false
            recordingState = .reviewing
            pasteReviewFeedback = .pasteFailed
            resetPasteReviewInactivity()
            recoveryPresenter.restorePasteReviewAfterFailedDelivery()
        }
    }

    func retryPendingPasteReview() async {
        guard pasteReviewFeedback == .pasteFailed else { return }
        haloOutcomeRecorder.record(.retry)
        await approvePendingPasteReview()
    }

    @discardableResult
    func beginPasteReviewFocusRecovery() -> Bool {
        guard recordingState == .reviewing,
            let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            pasteReviewFeedback?.allowsRefocus == true,
            !isPasteReviewRefocusing,
            haloReviewState?.isRefining != true,
            haloReviewState?.isVoiceRefinementActive != true,
            haloReviewState?.isEditingManually != true,
            let recoveryPresenter = recorderUIManager as? any PasteReviewRecoveryPresenting
        else {
            return false
        }

        isPasteReviewRefocusing = true
        resetPasteReviewInactivity()
        recoveryPresenter.beginPasteReviewFocusRecovery()
        announcePasteReviewFocusRecovery()

        if haloCapabilitySnapshot.guidedRecoveryEnabled,
            let destination = review.destination,
            haloDestinationRecoveryService.activateDestinationApplication(
                for: destination
            ) == .activated
        {
            scheduleGuidedDestinationReadinessCheck(
                reviewID: review.id,
                destination: destination
            )
        }
        return true
    }

    private func scheduleGuidedDestinationReadinessCheck(
        reviewID: UUID,
        destination: PasteReviewDestinationSnapshot
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard self.isPasteReviewRefocusing,
                self.pendingPasteReview?.id == reviewID,
                self.pasteReviewResolutionGate.permitsNonDeliveryAction(for: reviewID)
            else {
                return
            }

            let validation = await self.pasteReviewDestinationService.validate(destination)
            guard self.isPasteReviewRefocusing,
                self.pendingPasteReview?.id == reviewID,
                self.pasteReviewResolutionGate.permitsNonDeliveryAction(for: reviewID),
                validation.permitsDelivery,
                let recoveryPresenter = self.recorderUIManager
                    as? any PasteReviewRecoveryPresenting
            else {
                // Application activation succeeded, but VoiceInk cannot prove
                // the original field is focused. Keep the collapsed manual
                // Continue/Copy/Cancel recovery surface available.
                return
            }

            self.isPasteReviewRefocusing = false
            self.pasteReviewFeedback = nil
            self.resetPasteReviewInactivity()
            recoveryPresenter.endPasteReviewFocusRecovery()
            self.announceHaloVoiceRefinement(
                String(localized: "Original field is ready. Choose Apply to paste.")
            )
        }
    }

    private func completePasteReviewFocusRecovery(review: PendingPasteReview) async {
        guard isPasteReviewRefocusing,
            pendingPasteReview?.id == review.id,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            let recoveryPresenter = recorderUIManager as? any PasteReviewRecoveryPresenting
        else {
            return
        }

        let validation: PasteReviewDestinationValidation
        if let destination = review.destination {
            validation = await pasteReviewDestinationService.validate(destination)
        } else {
            validation = .validationUnavailable
        }

        guard isPasteReviewRefocusing,
            pendingPasteReview?.id == review.id,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id)
        else {
            return
        }

        isPasteReviewRefocusing = false
        if case .mismatch(let mismatch) = validation {
            haloOutcomeRecorder.record(.destinationMismatch)
            pasteReviewFeedback = .destinationChanged(mismatch)
        } else {
            pasteReviewFeedback = nil
        }
        resetPasteReviewInactivity()
        recoveryPresenter.endPasteReviewFocusRecovery()
    }

    @discardableResult
    func selectHaloReviewLens(
        _ lens: HaloReviewLens,
        at date: Date = Date()
    ) -> Bool {
        guard recordingState == .reviewing,
            let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            var state = haloReviewState,
            state.session.id == review.id,
            !state.isExpired,
            !state.isRefining,
            !state.isVoiceRefinementActive,
            !state.isEditingManually,
            state.lens != lens
        else {
            return false
        }

        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .selectLens(lens, at: date)
        )
        guard effect != .ignored else { return false }

        haloReviewState = state
        schedulePasteReviewInactivity(for: review.id)
        return true
    }

    @discardableResult
    func moveHaloReviewRevision(
        by offset: Int,
        at date: Date = Date()
    ) -> Bool {
        guard offset != 0,
            recordingState == .reviewing,
            let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            var state = haloReviewState,
            state.session.id == review.id,
            !state.isExpired,
            !state.isRefining,
            !state.isVoiceRefinementActive,
            !state.isEditingManually
        else {
            return false
        }

        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .moveRevision(offset, at: date)
        )
        guard effect != .ignored else { return false }

        haloReviewState = state
        schedulePasteReviewInactivity(for: review.id)
        return true
    }

    @discardableResult
    func beginHaloRefinement(
        _ action: HaloRefinementAction,
        at date: Date = Date()
    ) -> Bool {
        beginHaloRefinementOperation(kind: .preset(action), at: date)
    }

    @discardableResult
    func beginHaloAnotherTake(at date: Date = Date()) -> Bool {
        guard haloCapabilitySnapshot.anotherTakeEnabled else { return false }
        return beginHaloRefinementOperation(kind: .anotherTake, at: date)
    }

    private func beginHaloRefinementOperation(
        kind: HaloReviewRefinementKind,
        at date: Date
    ) -> Bool {
        guard recordingState == .reviewing,
            let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            let service = haloRefinementService,
            var state = haloReviewState,
            state.session.id == review.id,
            !state.isExpired,
            !state.isRefining,
            let configuration = state.session.enhancementConfiguration,
            let refinementInputSnapshot = state.session.refinementInputSnapshot,
            let selectedRevision = state.selectedRevision
        else {
            return false
        }

        // The timer updates once per second, so its published `isExpired` flag
        // can briefly lag the authoritative deadline. Reject and materialize
        // expiry here before any frozen context reaches the refinement service.
        guard date < state.expiresAt else {
            _ = HaloReviewReducer.reduce(
                state: &state,
                action: .timeout(at: date)
            )
            haloReviewState = state
            pasteReviewSecondsRemaining = 0
            return false
        }

        let requestID = UUID()
        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: {
                switch kind {
                case .preset(let action):
                    return .beginRefinement(action, requestID: requestID, at: date)
                case .anotherTake:
                    return .beginAnotherTake(requestID: requestID, at: date)
                }
            }()
        )
        guard case .refinementStarted(let reviewRequest) = effect else {
            haloReviewState = state
            return false
        }

        let request = HaloRefinementRequest(
            reviewRequest: reviewRequest,
            rawTranscript: state.session.rawText,
            selectedRevisionText: selectedRevision.text,
            configuration: configuration,
            contextSnapshot: state.session.frozenContext,
            inputSnapshot: refinementInputSnapshot
        )

        haloReviewState = state
        pasteReviewSecondsRemaining = nil
        schedulePasteReviewInactivity(for: review.id)

        // The reducer permits only one request. The explicit ID additionally
        // prevents a late cancelled task from clearing a newer task handle.
        haloRefinementTask?.cancel()
        activeHaloRefinementRequestID = requestID
        haloRefinementTask = Task { @MainActor [weak self] in
            do {
                let result = try await service.refine(request)
                self?.completeHaloRefinement(
                    result,
                    expectedRequestID: requestID,
                    reviewID: review.id,
                    at: Date()
                )
            } catch {
                self?.failHaloRefinement(
                    requestID: requestID,
                    reviewID: review.id,
                    error: error,
                    at: Date()
                )
            }
        }
        return true
    }

    @discardableResult
    func cancelHaloRefinementIfActive(at date: Date = Date()) -> Bool {
        guard recordingState == .reviewing,
            let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            var state = haloReviewState,
            state.session.id == review.id,
            state.isRefining
        else {
            return false
        }

        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .cancelRefinement(at: date)
        )
        guard effect != .ignored else { return false }

        stopActiveHaloRefinementTask()
        haloReviewState = state
        schedulePasteReviewInactivity(for: review.id)
        return true
    }

    // MARK: - Halo Voice Refinement

    /// Starts one ephemeral spoken instruction without entering the normal
    /// recording pipeline or creating another History item.
    @discardableResult
    func beginHaloVoiceRefinement(at date: Date = Date()) -> Bool {
        let canCaptureCommands = haloCapabilitySnapshot.voiceCommandsEnabled
        let canCaptureRefinement = haloCapabilitySnapshot.spokenRefinementEnabled
        guard recordingState == .reviewing,
            isHaloVoiceRefinementReady,
            canCaptureRefinement || canCaptureCommands,
            !isPasteReviewRefocusing,
            let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            var state = haloReviewState,
            state.session.id == review.id,
            !state.isExpired,
            let transcriptionConfiguration = state.session.transcriptionConfiguration,
            state.selectedRevision != nil,
            activeHaloVoiceRefinementRequestID == nil
        else {
            return false
        }

        guard date < state.expiresAt else {
            _ = HaloReviewReducer.reduce(
                state: &state,
                action: .timeout(at: date)
            )
            haloReviewState = state
            pasteReviewSecondsRemaining = 0
            return false
        }

        let requestID = UUID()
        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: canCaptureCommands
                ? .beginVoiceCommandCapture(requestID: requestID, at: date)
                : .beginVoiceRefinement(requestID: requestID, at: date)
        )
        guard case .voiceRefinementStarted = effect else {
            haloReviewState = state
            return false
        }

        activeHaloVoiceRefinementRequestID = requestID
        pendingHaloVoiceStopRequestID = nil
        haloVoiceCommandConfirmation = nil
        haloReviewState = state
        pasteReviewFeedback = nil
        pasteReviewSecondsRemaining = nil
        resetHaloVoiceInstructionPresentation()
        haloOutcomeRecorder.record(.voiceRefinementStarted)
        schedulePasteReviewInactivity(for: review.id)

        haloVoiceRefinementTask?.cancel()
        haloVoiceRefinementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let captureResult = await self.haloVoiceInstructionCaptureService.capture(
                requestID: requestID,
                configuration: transcriptionConfiguration,
                onEvent: { [weak self] event in
                    self?.handleHaloVoiceInstructionEvent(
                        event,
                        requestID: requestID,
                        reviewID: review.id
                    )
                }
            )

            guard self.activeHaloVoiceRefinementRequestID == requestID,
                self.pendingPasteReview?.id == review.id
            else {
                return
            }

            guard captureResult.requestID == requestID else {
                self.failHaloVoiceRefinement(
                    requestID: requestID,
                    reviewID: review.id,
                    failure: .transcriptionFailed,
                    metric: .voiceRefinementTranscriptionFailed,
                    at: Date()
                )
                return
            }

            switch captureResult.outcome {
            case .instruction(let instructionText):
                if self.haloCapabilitySnapshot.voiceCommandsEnabled,
                    let command = HaloVoiceCommandParser.parse(instructionText)
                {
                    self.routeRecognizedHaloVoiceCommand(
                        command,
                        requestID: requestID,
                        reviewID: review.id,
                        at: Date()
                    )
                    return
                }

                guard self.haloCapabilitySnapshot.spokenRefinementEnabled else {
                    self.finishHaloVoiceCaptureWithoutRefinement(
                        requestID: requestID,
                        reviewID: review.id,
                        notice: String(localized: "Command not recognized"),
                        at: Date()
                    )
                    return
                }

                guard self.haloRefinementService != nil,
                    self.haloReviewState?.session.enhancementConfiguration != nil,
                    self.haloReviewState?.session.refinementInputSnapshot != nil,
                    (self.haloReviewState?.revisions.count ?? HaloReviewState.maximumRevisionCount)
                        < HaloReviewState.maximumRevisionCount
                else {
                    self.finishHaloVoiceCaptureWithoutRefinement(
                        requestID: requestID,
                        reviewID: review.id,
                        notice: String(localized: "Spoken refinement is unavailable for this review."),
                        at: Date()
                    )
                    return
                }

                let directive: HaloFreeformRefinementDirective
                do {
                    directive = try HaloFreeformRefinementDirective(
                        validating: instructionText
                    )
                } catch let validationError as HaloFreeformRefinementDirective.ValidationError {
                    let failure: HaloVoiceRefinementFailure
                    let metric: HaloOutcomeMetric
                    switch validationError {
                    case .empty:
                        failure = .emptyInstruction
                        metric = .voiceRefinementEmpty
                    case .tooLong:
                        failure = .tooLongInstruction
                        metric = .voiceRefinementEnhancementFailed
                    }
                    self.failHaloVoiceRefinement(
                        requestID: requestID,
                        reviewID: review.id,
                        failure: failure,
                        metric: metric,
                        at: Date()
                    )
                    return
                } catch {
                    self.failHaloVoiceRefinement(
                        requestID: requestID,
                        reviewID: review.id,
                        failure: .refinementFailed,
                        metric: .voiceRefinementEnhancementFailed,
                        at: Date()
                    )
                    return
                }

                guard self.stageHaloVoiceInstructionForConfirmation(
                    requestID: requestID,
                    reviewID: review.id,
                    text: directive.text,
                    at: Date()
                ) else {
                    return
                }

            case .empty:
                self.failHaloVoiceRefinement(
                    requestID: requestID,
                    reviewID: review.id,
                    failure: .emptyInstruction,
                    metric: .voiceRefinementEmpty,
                    at: Date()
                )

            case .cancelled:
                _ = self.cancelHaloVoiceRefinementIfActive(at: Date())

            case .failed(let failure):
                let mappedFailure: HaloVoiceRefinementFailure
                let metric: HaloOutcomeMetric
                switch failure {
                case .captureUnavailable:
                    mappedFailure = .captureUnavailable
                    metric = .voiceRefinementTranscriptionFailed
                case .temporaryStorageUnavailable, .alreadyActive:
                    mappedFailure = .captureFailed
                    metric = .voiceRefinementTranscriptionFailed
                case .transcriptionUnavailable, .transcriptionTimedOut:
                    mappedFailure = .transcriptionFailed
                    metric = .voiceRefinementTranscriptionFailed
                }
                self.failHaloVoiceRefinement(
                    requestID: requestID,
                    reviewID: review.id,
                    failure: mappedFailure,
                    metric: metric,
                    at: Date()
                )
            }
        }
        return true
    }

    /// Opens a memory-only typed instruction editor against the currently
    /// selected revision. No model request is made until the user submits it.
    @discardableResult
    func beginHaloTypedInstruction(at date: Date = Date()) -> Bool {
        guard recordingState == .reviewing,
            haloCapabilitySnapshot.typedRefinementEnabled,
            !isPasteReviewRefocusing,
            let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            haloRefinementService != nil,
            var state = haloReviewState,
            state.session.id == review.id,
            !state.isExpired,
            state.session.enhancementConfiguration != nil,
            state.session.refinementInputSnapshot != nil,
            activeHaloVoiceRefinementRequestID == nil
        else {
            return false
        }

        let requestID = UUID()
        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .beginTypedInstruction(requestID: requestID, at: date)
        )
        guard effect != .ignored else {
            haloReviewState = state
            return false
        }

        activeHaloVoiceRefinementRequestID = requestID
        haloReviewState = state
        pasteReviewFeedback = nil
        pasteReviewSecondsRemaining = Int(HaloReviewState.inactivityLifetime)
        recorderUIManager?.refreshPasteReviewKeyboardHandling()
        schedulePasteReviewInactivity(for: review.id)
        return true
    }

    @discardableResult
    func editHaloInstructionDraft(at date: Date = Date()) -> Bool {
        guard recordingState == .reviewing,
            let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            var state = haloReviewState,
            state.session.id == review.id
        else {
            return false
        }
        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .editInstructionDraft(at: date)
        )
        guard effect != .ignored else { return false }
        haloReviewState = state
        recorderUIManager?.refreshPasteReviewKeyboardHandling()
        schedulePasteReviewInactivity(for: review.id)
        return true
    }

    @discardableResult
    func updateHaloInstructionDraft(
        requestID: UUID,
        text: String,
        at date: Date = Date()
    ) -> Bool {
        guard recordingState == .reviewing,
            let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            var state = haloReviewState,
            state.session.id == review.id
        else {
            return false
        }
        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .updateInstructionDraft(
                requestID: requestID,
                text: text,
                at: date
            )
        )
        guard effect != .ignored else { return false }
        haloReviewState = state
        schedulePasteReviewInactivity(for: review.id)
        return true
    }

    /// Confirms either a recognized voice instruction or the typed editor and
    /// sends exactly one refinement request through the frozen session route.
    @discardableResult
    func submitHaloInstructionDraft(at date: Date = Date()) -> Bool {
        guard recordingState == .reviewing,
            let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            let service = haloRefinementService,
            var state = haloReviewState,
            state.session.id == review.id,
            let draft = state.voiceRefinementPhase.instructionDraft,
            activeHaloVoiceRefinementRequestID == draft.requestID,
            let configuration = state.session.enhancementConfiguration,
            let refinementInputSnapshot = state.session.refinementInputSnapshot,
            let baseRevision = state.revisions.first(where: { $0.id == draft.baseRevisionID })
        else {
            return false
        }

        guard date < state.expiresAt else {
            let effect = HaloReviewReducer.reduce(
                state: &state,
                action: .timeout(at: date)
            )
            haloReviewState = state
            pasteReviewSecondsRemaining = 0
            recorderUIManager?.refreshPasteReviewKeyboardHandling()
            if effect == .expired {
                Task { @MainActor [weak self] in
                    await self?.cancelPendingPasteReview(reason: .expiry)
                }
            }
            return false
        }

        let sourceEnabled = draft.source == .voice
            ? haloCapabilitySnapshot.spokenRefinementEnabled
            : haloCapabilitySnapshot.typedRefinementEnabled
        guard sourceEnabled else {
            _ = cancelHaloVoiceRefinementIfActive(at: date)
            return false
        }

        let directive: HaloFreeformRefinementDirective
        do {
            directive = try HaloFreeformRefinementDirective(validating: draft.text)
        } catch let validationError as HaloFreeformRefinementDirective.ValidationError {
            let message: String
            switch validationError {
            case .empty:
                message = String(localized: "Enter a change before refining.")
            case .tooLong(let maximumCharacterCount):
                message = String(
                    format: String(localized: "Keep the instruction to %d characters."),
                    maximumCharacterCount
                )
            }
            state.setNotice(.instructionValidation(message), at: date)
            haloReviewState = state
            return false
        } catch {
            state.setNotice(
                .instructionValidation(String(localized: "This instruction cannot be used.")),
                at: date
            )
            haloReviewState = state
            return false
        }

        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .submitInstructionDraft(at: date)
        )
        guard case .instructionSubmitted(let submittedDraft) = effect,
            submittedDraft.requestID == draft.requestID
        else {
            return false
        }

        let request = HaloRefinementRequest(
            requestID: draft.requestID,
            baseRevisionID: draft.baseRevisionID,
            freeformDirective: directive,
            source: draft.source,
            rawTranscript: state.session.rawText,
            selectedRevisionText: baseRevision.text,
            configuration: configuration,
            contextSnapshot: state.session.frozenContext,
            inputSnapshot: refinementInputSnapshot
        )

        haloReviewState = state
        pasteReviewSecondsRemaining = nil
        recorderUIManager?.refreshPasteReviewKeyboardHandling()
        schedulePasteReviewInactivity(for: review.id)
        announceHaloVoiceRefinement(String(localized: "Applying your change"))

        haloVoiceRefinementTask?.cancel()
        haloVoiceRefinementTask = Task { @MainActor [weak self] in
            do {
                let result = try await service.refine(request)
                self?.completeHaloVoiceRefinement(
                    result,
                    expectedRequestID: draft.requestID,
                    reviewID: review.id,
                    at: Date()
                )
            } catch {
                guard self?.activeHaloVoiceRefinementRequestID == draft.requestID else {
                    return
                }
                self?.failHaloVoiceRefinement(
                    requestID: draft.requestID,
                    reviewID: review.id,
                    failure: .refinementFailed,
                    metric: .voiceRefinementEnhancementFailed,
                    at: Date()
                )
            }
        }
        return true
    }

    /// Mouse and shortcut controls use the same deterministic Start/Stop path.
    @discardableResult
    func toggleHaloVoiceRefinementCapture() -> Bool {
        if case .listening = haloReviewState?.voiceRefinementPhase {
            return requestStopHaloVoiceRefinementCapture()
        }
        guard haloReviewState?.isVoiceRefinementActive != true else { return false }
        return beginHaloVoiceRefinement()
    }

    @discardableResult
    func requestStopHaloVoiceRefinementCapture() -> Bool {
        guard case .listening(let request) = haloReviewState?.voiceRefinementPhase else {
            return false
        }
        if haloVoiceInstructionCaptureService.requestStop(requestID: request.id) {
            pendingHaloVoiceStopRequestID = nil
        } else {
            // The shortcut key-up can arrive before the capture task has
            // completed preparation. Preserve that intent and apply it when
            // the matching service publishes its listening phase.
            pendingHaloVoiceStopRequestID = request.id
        }
        return true
    }

    @discardableResult
    func cancelHaloVoiceRefinementIfActive(at date: Date = Date()) -> Bool {
        guard recordingState == .reviewing,
            let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            var state = haloReviewState,
            state.session.id == review.id,
            let request = state.voiceRefinementPhase.activeRequest
        else {
            return false
        }

        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .cancelVoiceRefinement(at: date)
        )
        guard effect == .voiceRefinementCancelled(request.id) else { return false }

        _ = haloVoiceInstructionCaptureService.cancel(requestID: request.id)
        haloVoiceRefinementTask?.cancel()
        haloVoiceRefinementTask = nil
        activeHaloVoiceRefinementRequestID = nil
        pendingHaloVoiceStopRequestID = nil
        resetHaloVoiceInstructionPresentation()
        haloReviewState = state
        haloOutcomeRecorder.record(.voiceRefinementCancelled)
        recorderUIManager?.refreshPasteReviewKeyboardHandling()
        schedulePasteReviewInactivity(for: review.id)
        announceHaloVoiceRefinement(
            request.source == .voice
                ? String(localized: "Voice refinement cancelled")
                : String(localized: "Typed refinement cancelled")
        )
        return true
    }

    private func handleHaloVoiceInstructionEvent(
        _ event: HaloVoiceInstructionCaptureEvent,
        requestID: UUID,
        reviewID: UUID
    ) {
        guard activeHaloVoiceRefinementRequestID == requestID,
            pendingPasteReview?.id == reviewID,
            var state = haloReviewState,
            state.session.id == reviewID
        else {
            return
        }

        switch event {
        case .phase(.listening):
            guard case .listening(let request) = state.voiceRefinementPhase,
                request.id == requestID
            else { return }
            if pendingHaloVoiceStopRequestID == requestID {
                pendingHaloVoiceStopRequestID = nil
                _ = haloVoiceInstructionCaptureService.requestStop(
                    requestID: requestID
                )
            }

        case .phase(.transcribing):
            guard case .listening(let request) = state.voiceRefinementPhase,
                request.id == requestID
            else { return }
            let effect = HaloReviewReducer.reduce(
                state: &state,
                action: .finishVoiceCapture(requestID: requestID, at: Date())
            )
            guard effect != .ignored else { return }
            haloReviewState = state
            haloVoiceInstructionAudioMeter = AudioMeter(
                averagePower: 0,
                peakPower: 0
            )
            announceHaloVoiceRefinement(
                String(localized: "Understanding your request")
            )

        case .audioLevel(let meter):
            guard case .listening(let request) = state.voiceRefinementPhase,
                request.id == requestID
            else { return }
            haloVoiceInstructionAudioMeter = meter

        case .partialTranscript(let partial):
            switch state.voiceRefinementPhase {
            case .listening(let request), .transcribing(let request):
                guard request.id == requestID else { return }
            case .idle, .awaitingConfirmation, .editingInstruction, .refining, .failed:
                return
            }
            haloVoiceInstructionPartialTranscript = partial
        }
    }

    private func stageHaloVoiceInstructionForConfirmation(
        requestID: UUID,
        reviewID: UUID,
        text: String,
        at date: Date
    ) -> Bool {
        guard activeHaloVoiceRefinementRequestID == requestID,
            pendingPasteReview?.id == reviewID,
            var state = haloReviewState,
            state.session.id == reviewID
        else {
            return false
        }

        // Injectable capture services may finish without publishing their
        // intermediate phase. Preserve reducer ordering while tolerating that
        // boundary in tests and provider-specific implementations.
        if case .listening = state.voiceRefinementPhase {
            _ = HaloReviewReducer.reduce(
                state: &state,
                action: .finishVoiceCapture(requestID: requestID, at: date)
            )
        }
        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .stageVoiceInstruction(requestID: requestID, text: text, at: date)
        )
        guard effect != .ignored else { return false }

        haloVoiceRefinementTask = nil
        resetHaloVoiceInstructionPresentation()
        haloReviewState = state
        pasteReviewSecondsRemaining = Int(HaloReviewState.inactivityLifetime)
        recorderUIManager?.refreshPasteReviewKeyboardHandling()
        schedulePasteReviewInactivity(for: reviewID)
        announceHaloVoiceRefinement(
            String(localized: "Spoken change ready for confirmation")
        )
        return true
    }

    private func finishHaloVoiceCaptureWithoutRefinement(
        requestID: UUID,
        reviewID: UUID,
        notice: String,
        at date: Date
    ) {
        guard activeHaloVoiceRefinementRequestID == requestID,
            pendingPasteReview?.id == reviewID,
            var state = haloReviewState,
            state.session.id == reviewID
        else {
            return
        }

        if case .listening = state.voiceRefinementPhase {
            _ = HaloReviewReducer.reduce(
                state: &state,
                action: .finishVoiceCapture(requestID: requestID, at: date)
            )
        }
        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .completeVoiceCommandCapture(requestID: requestID, at: date)
        )
        guard effect != .ignored else { return }

        state.setNotice(.instructionValidation(notice), at: date)
        clearHaloVoiceRefinementTaskHandle(ifMatching: requestID)
        resetHaloVoiceInstructionPresentation()
        haloReviewState = state
        recorderUIManager?.refreshPasteReviewKeyboardHandling()
        schedulePasteReviewInactivity(for: reviewID)
        announceHaloVoiceRefinement(notice)
    }

    private func routeRecognizedHaloVoiceCommand(
        _ command: HaloVoiceCommand,
        requestID: UUID,
        reviewID: UUID,
        at date: Date
    ) {
        guard activeHaloVoiceRefinementRequestID == requestID,
            pendingPasteReview?.id == reviewID,
            var state = haloReviewState,
            state.session.id == reviewID
        else {
            return
        }

        if case .listening = state.voiceRefinementPhase {
            _ = HaloReviewReducer.reduce(
                state: &state,
                action: .finishVoiceCapture(requestID: requestID, at: date)
            )
        }
        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .completeVoiceCommandCapture(requestID: requestID, at: date)
        )
        guard effect != .ignored else { return }

        clearHaloVoiceRefinementTaskHandle(ifMatching: requestID)
        resetHaloVoiceInstructionPresentation()
        haloReviewState = state
        recorderUIManager?.refreshPasteReviewKeyboardHandling()
        schedulePasteReviewInactivity(for: reviewID)

        switch command {
        case .apply, .cancel:
            haloVoiceCommandConfirmation = HaloVoiceCommandConfirmation(
                reviewID: reviewID,
                command: command
            )
            announceHaloVoiceRefinement(
                command == .apply
                    ? String(localized: "Confirm Apply")
                    : String(localized: "Confirm Cancel review")
            )
        case .copy:
            copyPendingPasteReview()
        case .showLens(let lens):
            _ = selectHaloReviewLens(lens, at: date)
        case .previousRevision:
            _ = moveHaloReviewRevision(by: -1, at: date)
        case .nextRevision:
            _ = moveHaloReviewRevision(by: 1, at: date)
        }
    }

    @discardableResult
    func cancelHaloVoiceCommandConfirmationIfActive(at date: Date = Date()) -> Bool {
        guard let confirmation = haloVoiceCommandConfirmation,
            pendingPasteReview?.id == confirmation.reviewID
        else {
            return false
        }
        haloVoiceCommandConfirmation = nil
        resetPasteReviewInactivity(at: date)
        announceHaloVoiceRefinement(String(localized: "Voice command cancelled"))
        return true
    }

    @discardableResult
    func confirmHaloVoiceCommandIfActive() async -> Bool {
        guard let confirmation = haloVoiceCommandConfirmation,
            pendingPasteReview?.id == confirmation.reviewID,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: confirmation.reviewID)
        else {
            return false
        }

        haloVoiceCommandConfirmation = nil
        switch confirmation.command {
        case .apply:
            await approvePendingPasteReview()
        case .cancel:
            await cancelPendingPasteReview()
        case .copy, .showLens, .previousRevision, .nextRevision:
            return false
        }
        return true
    }

    private func advanceHaloVoiceRefinementToRefining(
        requestID: UUID,
        reviewID: UUID,
        at date: Date
    ) -> Bool {
        guard activeHaloVoiceRefinementRequestID == requestID,
            pendingPasteReview?.id == reviewID,
            var state = haloReviewState,
            state.session.id == reviewID
        else {
            return false
        }

        // A test service may produce a result without a phase callback. Keep
        // the reducer authoritative while tolerating that injectable boundary.
        if case .listening = state.voiceRefinementPhase {
            _ = HaloReviewReducer.reduce(
                state: &state,
                action: .finishVoiceCapture(requestID: requestID, at: date)
            )
        }
        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .finishVoiceTranscription(requestID: requestID, at: date)
        )
        guard effect != .ignored else { return false }

        haloReviewState = state
        haloVoiceInstructionPartialTranscript = ""
        announceHaloVoiceRefinement(
            String(localized: "Applying your spoken change")
        )
        return true
    }

    private func completeHaloVoiceRefinement(
        _ result: HaloRefinementResult,
        expectedRequestID: UUID,
        reviewID: UUID,
        at date: Date
    ) {
        guard activeHaloVoiceRefinementRequestID == expectedRequestID,
            pendingPasteReview?.id == reviewID,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: reviewID),
            var state = haloReviewState,
            state.session.id == reviewID,
            let request = state.voiceRefinementPhase.activeRequest,
            request.id == expectedRequestID
        else {
            return
        }

        guard result.requestID == expectedRequestID,
            result.baseRevisionID == request.baseRevisionID
        else {
            failHaloVoiceRefinement(
                requestID: expectedRequestID,
                reviewID: reviewID,
                failure: .refinementFailed,
                metric: .voiceRefinementEnhancementFailed,
                at: date
            )
            return
        }

        let payload = pasteDeliveryService.prepare(
            text: result.replacementText,
            output: state.session.output
        )
        let revision = HaloReviewRevision(
            parentID: result.baseRevisionID,
            action: request.source == .voice ? .voiceRefinement : .typedRefinement,
            text: result.replacementText,
            metadata: state.session.metadata,
            payload: payload
        )
        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .completeVoiceRefinement(
                requestID: result.requestID,
                revision: revision,
                at: date
            )
        )

        clearHaloVoiceRefinementTaskHandle(ifMatching: expectedRequestID)
        resetHaloVoiceInstructionPresentation()
        haloReviewState = state
        if effect == .revisionAppended(revision.id) {
            haloOutcomeRecorder.record(.voiceRefinementCompleted)
            announceHaloVoiceRefinement(
                request.source == .voice
                    ? String(localized: "Spoken change applied. Changes are selected.")
                    : String(localized: "Typed change applied. Changes are selected.")
            )
        } else {
            let metric: HaloOutcomeMetric = state.voiceRefinementPhase == .failed(.emptyResult)
                ? .voiceRefinementEmpty
                : .voiceRefinementEnhancementFailed
            haloOutcomeRecorder.record(metric)
        }
        schedulePasteReviewInactivity(for: reviewID)
    }

    private func failHaloVoiceRefinement(
        requestID: UUID,
        reviewID: UUID,
        failure: HaloVoiceRefinementFailure,
        metric: HaloOutcomeMetric,
        at date: Date
    ) {
        guard activeHaloVoiceRefinementRequestID == requestID,
            pendingPasteReview?.id == reviewID,
            var state = haloReviewState,
            state.session.id == reviewID
        else {
            return
        }

        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .failVoiceRefinement(
                requestID: requestID,
                failure: failure,
                at: date
            )
        )
        guard effect != .ignored else { return }

        clearHaloVoiceRefinementTaskHandle(ifMatching: requestID)
        resetHaloVoiceInstructionPresentation()
        haloReviewState = state
        haloOutcomeRecorder.record(metric)
        schedulePasteReviewInactivity(for: reviewID)
        announceHaloVoiceRefinement(failure.message)
    }

    private func clearHaloVoiceRefinementTaskHandle(ifMatching requestID: UUID) {
        guard activeHaloVoiceRefinementRequestID == requestID else { return }
        activeHaloVoiceRefinementRequestID = nil
        if pendingHaloVoiceStopRequestID == requestID {
            pendingHaloVoiceStopRequestID = nil
        }
        haloVoiceRefinementTask = nil
    }

    private func stopActiveHaloVoiceRefinementTask() {
        if let requestID = activeHaloVoiceRefinementRequestID {
            _ = haloVoiceInstructionCaptureService.cancel(requestID: requestID)
        }
        haloVoiceRefinementTask?.cancel()
        haloVoiceRefinementTask = nil
        activeHaloVoiceRefinementRequestID = nil
        pendingHaloVoiceStopRequestID = nil
        resetHaloVoiceInstructionPresentation()
    }

    private func resetHaloVoiceInstructionPresentation() {
        haloVoiceInstructionAudioMeter = AudioMeter(
            averagePower: 0,
            peakPower: 0
        )
        haloVoiceInstructionPartialTranscript = ""
    }

    private func announceHaloVoiceRefinement(_ message: String) {
        guard let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    @discardableResult
    func useOriginalHaloReview(at date: Date = Date()) -> Bool {
        guard recordingState == .reviewing,
            let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            var state = haloReviewState,
            state.session.id == review.id,
            !state.isExpired,
            !state.isRefining,
            !state.isVoiceRefinementActive,
            !state.isEditingManually,
            let selectedRevision = state.selectedRevision,
            selectedRevision.text != state.session.rawText
        else {
            return false
        }

        let payload = pasteDeliveryService.prepare(
            text: state.session.rawText,
            output: state.session.output
        )
        let revision = HaloReviewRevision(
            parentID: selectedRevision.id,
            action: .original,
            text: state.session.rawText,
            metadata: state.session.metadata,
            payload: payload
        )
        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .useOriginal(revision, at: date)
        )
        guard effect != .ignored else {
            haloReviewState = state
            return false
        }

        haloReviewState = state
        pasteReviewFeedback = nil
        haloOutcomeRecorder.record(.useOriginal)
        schedulePasteReviewInactivity(for: review.id)
        return true
    }

    @discardableResult
    func beginHaloManualEdit(at date: Date = Date()) -> Bool {
        guard recordingState == .reviewing,
            let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            var state = haloReviewState,
            state.session.id == review.id,
            !state.isExpired
        else {
            return false
        }

        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .beginManualEdit(at: date)
        )
        guard effect != .ignored else {
            haloReviewState = state
            return false
        }
        haloReviewState = state
        pasteReviewFeedback = nil
        recorderUIManager?.refreshPasteReviewKeyboardHandling()
        schedulePasteReviewInactivity(for: review.id)
        return true
    }

    @discardableResult
    func updateHaloManualEdit(_ text: String, at date: Date = Date()) -> Bool {
        guard recordingState == .reviewing,
            let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            var state = haloReviewState,
            state.session.id == review.id,
            state.isEditingManually
        else {
            return false
        }

        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .updateManualEdit(text, at: date)
        )
        guard effect != .ignored else { return false }
        haloReviewState = state
        schedulePasteReviewInactivity(for: review.id)
        return true
    }

    @discardableResult
    func saveHaloManualEdit(at date: Date = Date()) -> Bool {
        guard recordingState == .reviewing,
            let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            var state = haloReviewState,
            state.session.id == review.id,
            let edit = state.manualEdit
        else {
            return false
        }

        let payload = pasteDeliveryService.prepare(
            text: edit.text,
            output: state.session.output
        )
        let revision = HaloReviewRevision(
            parentID: edit.baseRevisionID,
            action: .manualEdit,
            text: edit.text,
            metadata: state.session.metadata,
            payload: payload
        )
        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .completeManualEdit(revision, at: date)
        )
        haloReviewState = state
        recorderUIManager?.refreshPasteReviewKeyboardHandling()
        schedulePasteReviewInactivity(for: review.id)
        if effect != .ignored {
            haloOutcomeRecorder.record(.manualEdit)
        }
        return effect != .ignored
    }

    @discardableResult
    func cancelHaloManualEditIfActive(at date: Date = Date()) -> Bool {
        guard recordingState == .reviewing,
            let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            var state = haloReviewState,
            state.session.id == review.id,
            state.isEditingManually
        else {
            return false
        }

        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .cancelManualEdit(at: date)
        )
        guard effect != .ignored else { return false }
        haloReviewState = state
        recorderUIManager?.refreshPasteReviewKeyboardHandling()
        schedulePasteReviewInactivity(for: review.id)
        return true
    }

    private func completeHaloRefinement(
        _ result: HaloRefinementResult,
        expectedRequestID: UUID,
        reviewID: UUID,
        at date: Date
    ) {
        guard activeHaloRefinementRequestID == expectedRequestID,
            let review = pendingPasteReview,
            review.id == reviewID,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: reviewID),
            var state = haloReviewState,
            state.session.id == reviewID,
            let refinementRequest = state.refinementRequest,
            refinementRequest.id == expectedRequestID
        else {
            return
        }

        // A service implementation must echo both immutable request IDs. Treat
        // a mismatch as a malformed response for the expected active request;
        // otherwise the reducer would remain permanently stuck in refining.
        guard result.requestID == expectedRequestID,
            result.baseRevisionID == refinementRequest.baseRevisionID
        else {
            failHaloRefinement(
                requestID: expectedRequestID,
                reviewID: reviewID,
                error: HaloRefinementError.malformedResponse,
                at: date
            )
            return
        }

        let payload = pasteDeliveryService.prepare(
            text: result.replacementText,
            output: state.session.output
        )
        let revision = HaloReviewRevision(
            parentID: result.baseRevisionID,
            action: refinementRequest.kind.revisionAction,
            text: result.replacementText,
            metadata: state.session.metadata,
            payload: payload
        )
        let effect = HaloReviewReducer.reduce(
            state: &state,
            action: .completeRefinement(
                requestID: result.requestID,
                revision: revision,
                at: date
            )
        )

        clearHaloRefinementTaskHandle(ifMatching: result.requestID)
        haloReviewState = state
        haloOutcomeRecorder.record(
            effect == .revisionAppended(revision.id) ? .refinementSuccess : .refinementFailure
        )
        schedulePasteReviewInactivity(for: reviewID)
    }

    private func failHaloRefinement(
        requestID: UUID,
        reviewID: UUID,
        error: Error,
        at date: Date
    ) {
        guard activeHaloRefinementRequestID == requestID,
            let review = pendingPasteReview,
            review.id == reviewID,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: reviewID),
            var state = haloReviewState,
            state.session.id == reviewID,
            state.refinementRequest?.id == requestID
        else {
            return
        }

        let sanitized = (error as? HaloRefinementError)
            ?? HaloRefinementError.sanitized(error)
        let notice: HaloReviewNotice
        if sanitized == .cancelled {
            notice = .refinementCancelled
        } else {
            notice = .refinementFailed(
                sanitized.errorDescription
                    ?? String(localized: "The refinement could not be completed. Your current version is unchanged.")
            )
        }
        _ = HaloReviewReducer.reduce(
            state: &state,
            action: .failRefinement(
                requestID: requestID,
                notice: notice,
                at: date
            )
        )

        clearHaloRefinementTaskHandle(ifMatching: requestID)
        haloReviewState = state
        haloOutcomeRecorder.record(.refinementFailure)
        schedulePasteReviewInactivity(for: reviewID)
    }

    private func clearHaloRefinementTaskHandle(ifMatching requestID: UUID) {
        guard activeHaloRefinementRequestID == requestID else { return }
        activeHaloRefinementRequestID = nil
        haloRefinementTask = nil
    }

    private func stopActiveHaloRefinementTask() {
        haloRefinementTask?.cancel()
        haloRefinementTask = nil
        activeHaloRefinementRequestID = nil
    }

    func copyPendingPasteReview() {
        guard let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id),
            haloReviewState?.isRefining != true,
            haloReviewState?.isVoiceRefinementActive != true,
            haloReviewState?.isEditingManually != true,
            !isPasteReviewRefocusing
        else {
            return
        }

        let didCopy = pasteDeliveryService.copy(
            haloReviewState?.selectedRevision?.payload ?? review.payload
        )
        pasteReviewFeedback = didCopy ? .copied : .copyFailed
        haloOutcomeRecorder.record(.copy)
        mutateHaloReviewState { state in
            _ = HaloReviewReducer.reduce(
                state: &state,
                action: .copied(succeeded: didCopy, at: Date())
            )
        }
        schedulePasteReviewInactivity(for: review.id)
    }

    func cancelPendingPasteReview(
        reason: HaloReviewCancellationReason = .user
    ) async {
        guard let review = pendingPasteReview,
            pasteReviewResolutionGate.cancel(review.id)
        else {
            return
        }

        isResolvingPasteReview = true
        haloOutcomeRecorder.record(reason == .expiry ? .expiry : .cancel)
        recordingState = .busy
        clearPendingPasteReviewPresentation()
        await recorderUIManager?.dismissRecorderPanel()
        finishPasteReviewResolution()
    }

    private func finishPasteReviewResolution() {
        isResolvingPasteReview = false
        if PasteReviewLifecycle.canReturnToIdle(
            hasActivePipeline: activePipelineTranscriptionID != nil,
            isResolvingReview: isResolvingPasteReview
        ), recordingState == .busy {
            recordingState = .idle
        }
    }

    private func clearPendingPasteReviewPresentation() {
        stopActiveHaloRefinementTask()
        stopActiveHaloVoiceRefinementTask()
        haloVoiceCommandConfirmation = nil
        isPasteReviewRefocusing = false
        isHaloVoiceRefinementReady = false
        resetHaloVoiceInstructionPresentation()
        pendingPasteReview = nil
        haloReviewState = nil
        pendingPasteReviewExpirationTask?.cancel()
        pendingPasteReviewExpirationTask = nil
        pasteReviewSecondsRemaining = nil
        pasteReviewFeedback = nil
        recorderUIManager?.clearPasteReview()
        recorderUIManager?.finishPasteReviewKeyboardHandling()
    }

    private func discardPendingPasteReview() {
        clearPendingPasteReviewPresentation()
        pasteReviewResolutionGate.reset()
        isResolvingPasteReview = false
    }

    private func mutateHaloReviewState(
        _ mutation: (inout HaloReviewState) -> Void
    ) {
        guard var state = haloReviewState else { return }
        mutation(&state)
        haloReviewState = state
    }

    private func resetPasteReviewInactivity(at date: Date = Date()) {
        guard let reviewID = pendingPasteReview?.id else { return }
        mutateHaloReviewState { state in
            _ = HaloReviewReducer.reduce(
                state: &state,
                action: .touch(at: date)
            )
        }
        schedulePasteReviewInactivity(for: reviewID)
    }

    private func schedulePasteReviewInactivity(for reviewID: UUID) {
        pendingPasteReviewExpirationTask?.cancel()
        pasteReviewSecondsRemaining = haloReviewState.map {
            $0.isRefining || $0.voiceRefinementPhase.isProcessing
        } == true
            ? nil
            : haloReviewState?.secondsRemaining()
        pendingPasteReviewExpirationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while self.pendingPasteReview?.id == reviewID,
                self.pasteReviewResolutionGate.permitsNonDeliveryAction(for: reviewID)
            {
                guard var state = self.haloReviewState else { return }
                if state.isRefining || state.voiceRefinementPhase.isProcessing {
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch {
                        return
                    }
                    continue
                }

                let seconds = state.secondsRemaining()
                self.pasteReviewSecondsRemaining = seconds

                if seconds == 0 {
                    _ = HaloReviewReducer.reduce(
                        state: &state,
                        action: .timeout(at: Date())
                    )
                    self.haloReviewState = state
                    await self.cancelPendingPasteReview(reason: .expiry)
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func announcePasteReviewReady() {
        guard let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: String(localized: "Transcript review ready. Press Return to apply or Escape to cancel."),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func announcePasteReviewFocusRecovery() {
        guard let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: String(
                    localized: "Focus the original field, then press Return or choose Continue to recheck it."
                ),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    // MARK: - Cancellation

    func cancelRecording() async {
        haloSessionDeliveryOverride = nil
        let shouldFinishSessionImmediately: Bool
        switch recordingState {
        case .starting, .recording:
            requestRecordingCancellation()
            await finishActiveRecorderCancellation()
            shouldFinishSessionImmediately = false
        case .transcribing, .enhancing:
            requestRecordingCancellation()
            partialTranscript = ""
            recordingState = .idle
            shouldFinishSessionImmediately = false
        case .reviewing:
            await cancelPendingPasteReview()
            return
        case .idle, .busy:
            partialTranscript = ""
            shouldCancelRecording = false
            recordingState = .idle
            shouldFinishSessionImmediately = true
        }

        if shouldFinishSessionImmediately {
            await finishRecorderSession()
        }
    }

    func resetRecordingSession() async {
        haloSessionDeliveryOverride = nil
        discardPendingPasteReview()
        cancelCurrentSession()
        activeRecordingStartID = nil
        activePipelineTranscriptionID = nil
        canceledPipelineTranscriptionIDs.removeAll()
        shouldCancelRecording = false
        partialTranscript = ""
        assistantSession.reset()
        activeRecordingUseCase = .newSession
        activePipelineUseCase = .newSession
        activePasteReviewDestination = nil
        clearActiveRecordingContext()
        await recorder.stopRecording()
        recordedFile = nil
        recordingState = .idle
        await cleanupResources()
    }

    private func requestRecordingCancellation() {
        shouldCancelRecording = true

        if (recordingState == .transcribing || recordingState == .enhancing),
            let activePipelineTranscriptionID
        {
            canceledPipelineTranscriptionIDs.insert(activePipelineTranscriptionID)
        }

        cancelCurrentSession()
    }

    private func finishActiveRecorderCancellation() async {
        activeRecordingStartID = nil
        clearActiveRecordingContext()
        await recorder.stopRecording()
        await saveCanceledRecording()
        recordedFile = nil
        partialTranscript = ""
        activePasteReviewDestination = nil
        recordingState = .idle
        await cleanupResources()
    }

    private func saveCanceledRecording() async {
        guard let recordedFile,
            FileManager.default.fileExists(atPath: recordedFile.path)
        else { return }

        let duration = await AudioFileMetadata.duration(for: recordedFile)
        let transcription = makeRecordingTranscription(
            for: recordedFile,
            text: Transcription.canceledTranscriptionText,
            duration: duration,
            transcriptionStatus: .canceled
        )

        modelContext.insert(transcription)

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
        } catch {
            logger.error("Failed to save canceled recording: \(error, privacy: .public)")
        }
    }

    private func makeRecordingTranscription(
        for audioURL: URL,
        text: String,
        duration: TimeInterval,
        transcriptionStatus: TranscriptionStatus
    ) -> Transcription {
        let modeMetadata = currentModeMetadata()

        return Transcription(
            text: text,
            duration: duration,
            audioFileURL: audioURL.absoluteString,
            transcriptionModelName: ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            )?.model.displayName,
            modeName: modeMetadata.name,
            modeEmoji: modeMetadata.emoji,
            transcriptionStatus: transcriptionStatus
        )
    }

    private func currentModeMetadata() -> (name: String?, emoji: String?) {
        guard let mode = ModeManager.shared.currentEffectiveConfiguration,
            mode.isEnabled
        else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
    }

    private func scheduleVoiceInkRefinePreparation(for recordingStartID: UUID) {
        voiceInkRefinePreparationTask?.cancel()

        voiceInkRefinePreparationTask = Task { @MainActor [weak self] in
            guard let self,
                self.recordingState == .recording,
                self.activeRecordingStartID == recordingStartID,
                !self.shouldCancelRecording,
                let enhancementService = self.enhancementService,
                let aiService = enhancementService.getAIService()
            else {
                return
            }

            let initialConfiguration = ModeRuntimeResolver.currentEnhancementConfiguration(
                enhancementService: enhancementService,
                aiService: aiService
            )
            guard initialConfiguration.isEnabled,
                initialConfiguration.provider == .voiceInkRefine
            else {
                return
            }

            // Preserve an already-warm XPC model immediately, while retaining the
            // debounce below before any new model preparation begins.
            await aiService.voiceInkRefineService.keepPreparedModelWarmForRecording()

            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }

            guard self.recordingState == .recording,
                self.activeRecordingStartID == recordingStartID,
                !self.shouldCancelRecording
            else {
                return
            }

            let configuration = ModeRuntimeResolver.currentEnhancementConfiguration(
                enhancementService: enhancementService,
                aiService: aiService
            )
            guard configuration.isEnabled, configuration.provider == .voiceInkRefine else {
                return
            }

            await aiService.voiceInkRefineService.prepareForRecording()
        }
    }

    // MARK: - Resource Cleanup

    private func cancelPipelineSession(transcriptionID: UUID, session: TranscriptionSession?) {
        session?.cancel()

        guard activePipelineTranscriptionID == transcriptionID else {
            logger.notice("Skipping stale pipeline cleanup")
            return
        }

        currentSession = nil
        currentSessionTranscriptionConfiguration = nil
    }

    private func cancelCurrentSession() {
        currentSession?.cancel()
        currentSession = nil
        currentSessionTranscriptionConfiguration = nil
    }

    private func finishRecorderSession() async {
        let preparationTask = voiceInkRefinePreparationTask
        voiceInkRefinePreparationTask = nil
        preparationTask?.cancel()
        await preparationTask?.value

        enhancementService?.clearCapturedContexts()
        await enhancementService?
            .getAIService()?
            .voiceInkRefineService
            .unloadPreparedModelIfNeeded()
    }

    func cleanupResources() async {
        logger.notice("cleanupResources: releasing model resources")
        activeRecordingStartID = nil
        activeRecordingUseCase = .newSession
        await finishRecorderSession()
        await whisperModelManager.cleanupResources()
        await serviceRegistry.cleanup()
        logger.notice("cleanupResources: completed")
    }

    // MARK: - Notification Handling

    func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptChange),
            name: .promptDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHaloCapabilitiesDidChange),
            name: .haloCapabilitiesDidChange,
            object: haloCapabilityStore
        )
    }

    @objc func handlePromptChange() {
        Task {
            let currentPrompt =
                UserDefaults.standard.string(forKey: "TranscriptionPrompt")
                ?? whisperModelManager.whisperPrompt.transcriptionPrompt
            if let context = whisperModelManager.whisperContext {
                await context.setPrompt(currentPrompt)
            }
        }
    }

    @objc private func handleHaloCapabilitiesDidChange() {
        let previous = haloCapabilitySnapshot
        let updated = haloCapabilityStore.snapshot
        haloCapabilitySnapshot = updated

        guard previous != updated else {
            return
        }

        if !updated.voiceCommandsEnabled {
            haloVoiceCommandConfirmation = nil
        }
        if previous.anotherTakeEnabled,
            !updated.anotherTakeEnabled,
            haloReviewState?.refinementRequest?.kind == .anotherTake
        {
            _ = cancelHaloRefinementIfActive()
        }

        guard let phase = haloReviewState?.voiceRefinementPhase,
            let source = phase.activeRequest?.source
        else { return }

        let sourceRemainsEnabled: Bool
        switch source {
        case .voice:
            switch phase {
            case .listening, .transcribing:
                sourceRemainsEnabled = updated.spokenRefinementEnabled
                    || updated.voiceCommandsEnabled
            case .awaitingConfirmation, .editingInstruction, .refining:
                sourceRemainsEnabled = updated.spokenRefinementEnabled
            case .idle, .failed:
                sourceRemainsEnabled = true
            }
        case .typed:
            sourceRemainsEnabled = updated.typedRefinementEnabled
        }
        if !sourceRemainsEnabled {
            _ = cancelHaloVoiceRefinementIfActive()
        }
    }

    @objc private func handleApplicationWillTerminate() {
        stopActiveHaloRefinementTask()
        discardPendingPasteReview()
        clearActiveRecordingContext()
    }
}

enum AudioFileMetadata {
    static func duration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }
}

extension VoiceInkEngine: HaloReviewVoiceShortcutRouting {
    var isHaloReviewVoiceShortcutRoutingActive: Bool {
        recordingState == .reviewing && pendingPasteReview != nil
    }

    var isHaloReviewVoiceCaptureActive: Bool {
        if case .listening = haloReviewState?.voiceRefinementPhase {
            return true
        }
        return false
    }

    @discardableResult
    func handleHaloReviewVoiceShortcutCommand(
        _ command: HaloReviewVoiceShortcutCommand
    ) -> Bool {
        switch command {
        case .startCapture:
            return beginHaloVoiceRefinement()
        case .stopCapture:
            return requestStopHaloVoiceRefinementCapture()
        case .cancelCapture:
            return cancelHaloVoiceRefinementIfActive()
        }
    }
}
