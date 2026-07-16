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
    @Published private(set) var haloSessionDeliveryOverride: HaloSessionDeliveryOverride?
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
    private let pipeline: TranscriptionPipeline

    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VoiceInkEngine")

    init(
        modelContext: ModelContext,
        whisperModelManager: WhisperModelManager,
        transcriptionModelManager: TranscriptionModelManager,
        enhancementService: AIEnhancementService? = nil,
        pasteDeliveryService: (any PasteDeliveryServicing)? = nil,
        pasteReviewDestinationService: (any PasteReviewDestinationServicing)? = nil
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

        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: whisperModelManager,
            modelsDirectory: whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )
        let resolvedPasteDeliveryService = pasteDeliveryService ?? PasteDeliveryService()
        self.pasteDeliveryService = resolvedPasteDeliveryService
        self.pasteReviewDestinationService = pasteReviewDestinationService ?? PasteReviewDestinationService()
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

        await pipeline.run(
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
            await cleanupResources()
            activePipelineTranscriptionID = nil
            currentSession = nil
            currentSessionTranscriptionConfiguration = nil
            recordedFile = nil
            shouldCancelRecording = false
            activePipelineUseCase = .newSession
            activePasteReviewDestination = nil
            clearActiveRecordingContext()
        }
        canceledPipelineTranscriptionIDs.remove(transcriptionID)

        if didFinishActivePipeline
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

    private func stagePasteReview(
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
        pasteReviewFeedback = feedback
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
            output: review.output,
            enhancementConfiguration: review.enhancementConfiguration,
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
        guard let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id)
        else {
            return
        }

        guard haloReviewState?.isExpired != true,
            (haloReviewState?.secondsRemaining() ?? 1) > 0
        else {
            await cancelPendingPasteReview()
            return
        }

        if let destination = review.destination {
            let validation = await pasteReviewDestinationService.validate(destination)

            // Validation suspends while AX is queried. A concurrent Escape or
            // Apply may already have resolved this review, so re-check identity.
            guard pendingPasteReview?.id == review.id,
                pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id)
            else {
                return
            }

            if case .mismatch(let mismatch) = validation {
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

        let payload = haloReviewState?.selectedRevision?.payload ?? review.payload
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
        await approvePendingPasteReview()
    }

    func copyPendingPasteReview() {
        guard let review = pendingPasteReview,
            pasteReviewResolutionGate.permitsNonDeliveryAction(for: review.id)
        else {
            return
        }

        let didCopy = pasteDeliveryService.copy(
            haloReviewState?.selectedRevision?.payload ?? review.payload
        )
        pasteReviewFeedback = didCopy ? .copied : .copyFailed
        mutateHaloReviewState { state in
            _ = HaloReviewReducer.reduce(
                state: &state,
                action: .copied(succeeded: didCopy, at: Date())
            )
        }
        schedulePasteReviewInactivity(for: review.id)
    }

    func cancelPendingPasteReview() async {
        guard let review = pendingPasteReview,
            pasteReviewResolutionGate.cancel(review.id)
        else {
            return
        }

        isResolvingPasteReview = true
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
        pasteReviewSecondsRemaining = haloReviewState?.secondsRemaining()
        pendingPasteReviewExpirationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while self.pendingPasteReview?.id == reviewID,
                self.pasteReviewResolutionGate.permitsNonDeliveryAction(for: reviewID)
            {
                guard var state = self.haloReviewState else { return }
                if state.isRefining {
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
                    await self.cancelPendingPasteReview()
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
}

enum AudioFileMetadata {
    static func duration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }
}
