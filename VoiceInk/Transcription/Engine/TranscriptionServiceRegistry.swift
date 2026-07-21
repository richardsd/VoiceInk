import Foundation
import SwiftData
import SwiftUI
import os

@MainActor
class TranscriptionServiceRegistry {
    private weak var modelProvider: (any WhisperModelProvider)?
    private let modelsDirectory: URL
    private let modelContext: ModelContext
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionServiceRegistry")

    private(set) lazy var localTranscriptionService = WhisperTranscriptionService(
        modelsDirectory: modelsDirectory,
        modelProvider: modelProvider
    )
    private(set) lazy var cloudTranscriptionService = CloudTranscriptionService(modelContext: modelContext)
    private(set) lazy var nativeAppleTranscriptionService = NativeAppleTranscriptionService()
    private(set) lazy var fluidAudioTranscriptionService = FluidAudioTranscriptionService()
    private var cachedTranscribeCppTranscriptionService: TranscribeCppTranscriptionService?

    var transcribeCppTranscriptionService: TranscribeCppTranscriptionService {
        if let cachedTranscribeCppTranscriptionService {
            return cachedTranscribeCppTranscriptionService
        }
        let service = TranscribeCppTranscriptionService()
        cachedTranscribeCppTranscriptionService = service
        return service
    }
    private(set) lazy var inMemoryTranscriptionService: any InMemoryTranscriptionServicing =
        RoutedInMemoryTranscriptionService(
            cloudService: BatchCloudInMemoryTranscriptionService(),
            localService: LocalInMemoryTranscriptionService(
                whisperService: localTranscriptionService,
                fluidAudioService: fluidAudioTranscriptionService
            )
        )
    private lazy var audioSourceRouter = TranscriptionAudioSourceRouter(
        fileTranscriber: { [unowned self] audioURL, model, context in
            try await self.transcribeFile(
                audioURL: audioURL,
                model: model,
                context: context
            )
        },
        inMemoryService: inMemoryTranscriptionService
    )

    init(modelProvider: any WhisperModelProvider, modelsDirectory: URL, modelContext: ModelContext) {
        self.modelProvider = modelProvider
        self.modelsDirectory = modelsDirectory
        self.modelContext = modelContext
    }

    func service(for provider: ModelProvider) -> TranscriptionService {
        switch provider {
        case .whisper:
            return localTranscriptionService
        case .fluidAudio:
            return fluidAudioTranscriptionService
        case .transcribeCpp:
            return transcribeCppTranscriptionService
        case .nativeApple:
            return nativeAppleTranscriptionService
        default:
            return cloudTranscriptionService
        }
    }

    func transcribe(
        audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext = .currentDefaults
    ) async throws -> String {
        try await transcribe(
            source: .file(audioURL),
            model: model,
            context: context
        ).text
    }

    /// Shared source boundary for normal recordings and memory-only Time-Shift
    /// capture. The router selects exactly one path and never retries through a
    /// different source, model, provider, or authentication route.
    func transcribe(
        source: TranscriptionAudioSource,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext = .currentDefaults,
        requestID: UUID = UUID(),
        customVocabulary: [String] = []
    ) async throws -> InMemoryTranscriptionResult {
        try await audioSourceRouter.transcribe(
            TranscriptionAudioSourceRequest(
                id: requestID,
                source: source,
                model: model,
                context: context.scoped(to: model),
                customVocabulary: customVocabulary
            )
        )
    }

    private func transcribeFile(
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        let service = service(for: model.provider)
        logger.debug(
            "Transcribing with \(model.displayName, privacy: .public) using \(String(describing: type(of: service)), privacy: .public)"
        )
        return try await service.transcribe(audioURL: audioURL, model: model, context: context.scoped(to: model))
    }

    /// Creates a streaming or file-based session for the resolved transcription configuration.
    func createSession(
        for configuration: TranscriptionRuntimeConfiguration, onPartialTranscript: ((String) -> Void)? = nil
    ) -> TranscriptionSession {
        let model = configuration.model

        if shouldUseRealtimeTranscription(for: configuration) {
            let streamingService = StreamingTranscriptionService(
                modelContext: modelContext,
                fluidAudioService: model.provider == .fluidAudio ? fluidAudioTranscriptionService : nil,
                onPartialTranscript: onPartialTranscript
            )
            let fallback = service(for: model.provider)
            return StreamingTranscriptionSession(streamingService: streamingService, fallbackService: fallback)
        } else {
            return FileTranscriptionSession(service: service(for: model.provider))
        }
    }

    /// Whether the resolved transcription configuration should use real-time transcription.
    func shouldUseRealtimeTranscription(for configuration: TranscriptionRuntimeConfiguration) -> Bool {
        configuration.isRealtimeEnabled
    }

    func cleanup() async {
        await fluidAudioTranscriptionService.cleanup()
        cachedTranscribeCppTranscriptionService?.cleanup()
    }
}
