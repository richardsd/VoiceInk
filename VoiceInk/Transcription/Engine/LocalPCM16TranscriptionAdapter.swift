import Darwin
import Foundation

/// A local transcription engine that can consume VoiceInk's canonical PCM16
/// snapshot without materializing a temporary audio file.
///
/// Implementations must use the supplied model and request context exactly as
/// provided. Route selection happens before this boundary and must never be
/// repeated or replaced by a fallback here.
protocol LocalPCM16TranscriptionServicing: AnyObject {
    func transcribe(
        pcm16Snapshot: PCM16Snapshot,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String
}

enum LocalPCM16TranscriptionAdapterError: Error, Equatable {
    case emptyAudio
    case providerMismatch(expected: ModelProvider, actual: ModelProvider)
}

/// Closure-backed conversion and ownership boundary shared by the local
/// Whisper and FluidAudio services.
///
/// The closure may suspend, so this adapter intentionally owns the normalized
/// Float32 array for the complete asynchronous operation. Both that array and
/// the source snapshot are overwritten immediately after the operation exits,
/// including cancellation and failure paths. The closure must not retain the
/// sample array after returning.
final class LocalPCM16TranscriptionAdapter {
    typealias SampleTranscriber = (
        [Float],
        any TranscriptionModel,
        TranscriptionRequestContext
    ) async throws -> String

    private let provider: ModelProvider
    private let sampleTranscriber: SampleTranscriber

    init(
        provider: ModelProvider,
        sampleTranscriber: @escaping SampleTranscriber
    ) {
        self.provider = provider
        self.sampleTranscriber = sampleTranscriber
    }

    func transcribe(
        snapshot: PCM16Snapshot,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        defer { snapshot.zeroize() }

        guard model.provider == provider else {
            throw LocalPCM16TranscriptionAdapterError.providerMismatch(
                expected: provider,
                actual: model.provider
            )
        }
        guard !snapshot.isEmpty else {
            throw LocalPCM16TranscriptionAdapterError.emptyAudio
        }

        var samples = snapshot.withNormalizedFloatSamples { Array($0) }
        defer { Self.zeroize(&samples) }

        try Task.checkCancellation()
        let text = try await sampleTranscriber(samples, model, context)
        try Task.checkCancellation()
        return text
    }

    static func zeroize(_ samples: inout [Float]) {
        samples.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress, !bytes.isEmpty else { return }
            memset(baseAddress, 0, bytes.count)
        }
        samples.removeAll(keepingCapacity: false)
    }
}
