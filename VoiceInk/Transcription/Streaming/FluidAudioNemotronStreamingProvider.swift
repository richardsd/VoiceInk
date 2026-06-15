import Foundation

/// Placeholder retained for project compatibility while the local FluidAudio
/// fork does not expose StreamingNemotronMultilingualAsrManager.
final class FluidAudioNemotronStreamingProvider: StreamingTranscriptionProvider {
    private let stream: AsyncStream<StreamingTranscriptionEvent>

    var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent> {
        stream
    }

    init() {
        self.stream = AsyncStream { continuation in
            continuation.finish()
        }
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        throw StreamingTranscriptionError.connectionFailed(
            String(localized: "This FluidAudio streaming model is not available in the bundled FluidAudio build.")
        )
    }

    func sendAudioChunk(_ data: Data) async throws {}

    func commit() async throws {}

    func disconnect() async {}
}
