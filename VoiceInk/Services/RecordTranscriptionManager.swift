import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import os

@MainActor
class RecordTranscriptionManager: ObservableObject {
    static let shared = RecordTranscriptionManager()

    @Published var recordingState: RecordTranscriptionState = .idle
    @Published var currentTranscription: Transcription?
    @Published var errorMessage: String?
    @Published var recordingDuration: TimeInterval = 0

    let recorder = Recorder()

    private var currentTask: Task<Void, Error>?
    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    private var recordedFileURL: URL?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecordTranscriptionManager")

    enum RecordTranscriptionState: Equatable {
        case idle
        case recording
        case processingAudio
        case transcribing
        case enhancing
        case completed
        case error
    }

    enum ProcessingPhase {
        case processingAudio
        case transcribing
        case enhancing
        case completed

        var message: String {
            switch self {
            case .processingAudio:
                return "Processing recorded audio..."
            case .transcribing:
                return "Transcribing audio..."
            case .enhancing:
                return "Enhancing transcription with AI..."
            case .completed:
                return "Transcription completed!"
            }
        }
    }

    var processingPhaseMessage: String {
        switch recordingState {
        case .processingAudio: return ProcessingPhase.processingAudio.message
        case .transcribing: return ProcessingPhase.transcribing.message
        case .enhancing: return ProcessingPhase.enhancing.message
        case .completed: return ProcessingPhase.completed.message
        default: return ""
        }
    }

    var isProcessing: Bool {
        switch recordingState {
        case .processingAudio, .transcribing, .enhancing:
            return true
        default:
            return false
        }
    }

    private init() {}

    func startRecording() async {
        guard recordingState == .idle || recordingState == .completed || recordingState == .error else { return }

        let recordingsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("Recordings")

        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create recordings directory: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Failed to create recordings directory"
            recordingState = .error
            return
        }

        let fileName = "\(UUID().uuidString).wav"
        let fileURL = recordingsDirectory.appendingPathComponent(fileName)
        recordedFileURL = fileURL

        currentTranscription = nil
        errorMessage = nil
        recordingDuration = 0

        do {
            try await recorder.startRecording(toOutputFile: fileURL)
            recordingState = .recording
            recordingStartTime = Date()
            startDurationTimer()
            logger.notice("Recording started: \(fileName, privacy: .public)")
        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            recordingState = .error
            cleanupRecordedFile()
        }
    }

    func stopRecording(modelContext: ModelContext, engine: VoiceInkEngine) async {
        guard recordingState == .recording else { return }

        await recorder.stopRecording()
        stopDurationTimer()

        guard let fileURL = recordedFileURL else {
            errorMessage = "No recorded file found"
            recordingState = .error
            return
        }

        recordingState = .processingAudio
        logger.notice("Recording stopped, starting transcription pipeline")

        currentTask = Task {
            do {
                try await transcribe(fileURL: fileURL, modelContext: modelContext, engine: engine)
            } catch {
                handleError(error)
            }
        }
    }

    func cancelRecording() async {
        if recordingState == .recording {
            await recorder.stopRecording()
            stopDurationTimer()
        }

        currentTask?.cancel()
        currentTask = nil
        recordingState = .idle
        recordingDuration = 0
        cleanupRecordedFile()
        logger.notice("Recording cancelled")
    }

    func reset() {
        currentTask?.cancel()
        currentTask = nil
        recordingState = .idle
        currentTranscription = nil
        errorMessage = nil
        recordingDuration = 0
        recordedFileURL = nil
    }

    // MARK: - Private

    private func transcribe(fileURL: URL, modelContext: ModelContext, engine: VoiceInkEngine) async throws {
        guard let currentModel = engine.transcriptionModelManager.currentTranscriptionModel else {
            throw TranscriptionError.noModelSelected
        }

        let serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: engine.whisperModelManager,
            modelsDirectory: engine.whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )
        defer { Task { await serviceRegistry.cleanup() } }

        // Calculate audio duration
        let audioAsset = AVURLAsset(url: fileURL)
        let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))

        // Transcribe
        recordingState = .transcribing
        let transcriptionStart = Date()
        var text = try await serviceRegistry.transcribe(audioURL: fileURL, model: currentModel)
        let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)

        text = TranscriptionOutputFilter.filter(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let mode = ModeManager.shared.currentEffectiveConfiguration
        let modeMetadata: (name: String?, emoji: String?) = mode.map { mode -> (name: String?, emoji: String?) in
            guard mode.isEnabled else { return (nil, nil) }
            return (mode.name, mode.icon.legacyEmojiValue)
        } ?? (nil, nil)
        let formattingConfiguration = ModeRuntimeResolver.transcriptionFormattingConfiguration(mode: mode)

        if formattingConfiguration.isTextFormattingEnabled {
            text = ParagraphFormatter.format(text)
        }

        text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
        let cleanedText = TranscriptionOutputFilter.applyCleanupPreferences(
            text,
            punctuationMode: formattingConfiguration.punctuationCleanupMode,
            shouldLowercase: formattingConfiguration.lowercaseTranscription
        )

        // Enhancement
        let enhancementConfiguration = engine.enhancementService
            .flatMap { enhancementService in
                enhancementService.getAIService().map { aiService in
                    ModeRuntimeResolver.currentEnhancementConfiguration(
                        mode: mode,
                        enhancementService: enhancementService,
                        aiService: aiService
                    )
                }
            }

        if let enhancementService = engine.enhancementService,
           let enhancementConfiguration,
           enhancementConfiguration.isEnabled,
           enhancementService.isConfigured(for: enhancementConfiguration) {
            recordingState = .enhancing
            do {
                let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(
                    text,
                    configuration: enhancementConfiguration
                )
                let transcription = Transcription(
                    text: cleanedText,
                    duration: duration,
                    enhancedText: enhancedText,
                    audioFileURL: fileURL.absoluteString,
                    transcriptionModelName: currentModel.displayName,
                    aiEnhancementModelName: enhancementConfiguration.modelName ?? enhancementConfiguration.provider?.defaultModel,
                    promptName: promptName,
                    transcriptionDuration: transcriptionDuration,
                    enhancementDuration: enhancementDuration,
                    aiRequestSystemMessage: enhancementService.lastSystemMessageSent,
                    aiRequestUserMessage: enhancementService.lastUserMessageSent,
                    modeName: modeMetadata.name,
                    modeEmoji: modeMetadata.emoji
                )
                saveTranscription(transcription, modelContext: modelContext)
            } catch {
                logger.error("Enhancement failed: \(error.localizedDescription, privacy: .public)")
                let transcription = Transcription(
                    text: cleanedText,
                    duration: duration,
                    audioFileURL: fileURL.absoluteString,
                    transcriptionModelName: currentModel.displayName,
                    transcriptionDuration: transcriptionDuration,
                    modeName: modeMetadata.name,
                    modeEmoji: modeMetadata.emoji
                )
                saveTranscription(transcription, modelContext: modelContext)
            }
        } else {
            let transcription = Transcription(
                text: cleanedText,
                duration: duration,
                audioFileURL: fileURL.absoluteString,
                transcriptionModelName: currentModel.displayName,
                transcriptionDuration: transcriptionDuration,
                modeName: modeMetadata.name,
                modeEmoji: modeMetadata.emoji
            )
            saveTranscription(transcription, modelContext: modelContext)
        }

        recordingState = .completed
    }

    private func saveTranscription(_ transcription: Transcription, modelContext: ModelContext) {
        modelContext.insert(transcription)
        try? modelContext.save()
        NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
        NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
        currentTranscription = transcription
    }

    private func handleError(_ error: Error) {
        logger.error("Transcription error: \(error.localizedDescription, privacy: .public)")
        errorMessage = error.localizedDescription
        recordingState = .error
        currentTask = nil
    }

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func cleanupRecordedFile() {
        guard let url = recordedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
        recordedFileURL = nil
    }
}
