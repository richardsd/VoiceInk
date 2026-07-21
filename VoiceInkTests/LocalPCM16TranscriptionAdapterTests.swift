import Foundation
import Testing
@testable import VoiceInk

struct LocalPCM16TranscriptionAdapterTests {
    @Test @MainActor
    func adapterKeepsSamplesAliveAcrossSuspensionAndPreservesFrozenRoute() async throws {
        let snapshot = PCM16Snapshot(
            pcmData: pcmData([-32_768, 0, 16_384, 32_767])
        )
        let model = makeWhisperModel(name: "time-shift-whisper")
        let context = TranscriptionRequestContext(
            language: "pt",
            prompt: "Keep VoiceInk and Halo unchanged."
        )
        var receivedModelName: String?
        var receivedProvider: ModelProvider?
        var receivedLanguage: String?
        var receivedPrompt: String?

        let adapter = LocalPCM16TranscriptionAdapter(provider: .whisper) { samples, model, context in
            await Task.yield()

            #expect(!snapshot.isZeroized)
            #expect(samples == [-1, 0, 0.5, Float(32_767) / 32_768])
            receivedModelName = model.name
            receivedProvider = model.provider
            receivedLanguage = context.language
            receivedPrompt = context.prompt
            return "transcribed"
        }

        let text = try await adapter.transcribe(
            snapshot: snapshot,
            model: model,
            context: context
        )

        #expect(text == "transcribed")
        #expect(receivedModelName == "time-shift-whisper")
        #expect(receivedProvider == .whisper)
        #expect(receivedLanguage == "pt")
        #expect(receivedPrompt == "Keep VoiceInk and Halo unchanged.")
        #expect(snapshot.isZeroized)
    }

    @Test @MainActor
    func routeMismatchNeverInvokesEngineAndStillZeroizesSnapshot() async {
        let snapshot = PCM16Snapshot(pcmData: pcmData([1, 2]))
        let fluidModel = makeFluidModel(name: "time-shift-parakeet")
        var invocationCount = 0
        let adapter = LocalPCM16TranscriptionAdapter(provider: .whisper) { _, _, _ in
            invocationCount += 1
            return "unexpected"
        }

        await #expect(
            throws: LocalPCM16TranscriptionAdapterError.providerMismatch(
                expected: .whisper,
                actual: .fluidAudio
            )
        ) {
            try await adapter.transcribe(
                snapshot: snapshot,
                model: fluidModel,
                context: TranscriptionRequestContext(language: "en", prompt: nil)
            )
        }

        #expect(invocationCount == 0)
        #expect(snapshot.isZeroized)
    }

    @Test @MainActor
    func emptySnapshotIsRejectedBeforeTheEngineRuns() async {
        let snapshot = PCM16Snapshot(pcmData: Data())
        var invocationCount = 0
        let adapter = LocalPCM16TranscriptionAdapter(provider: .fluidAudio) { _, _, _ in
            invocationCount += 1
            return "unexpected"
        }

        await #expect(throws: LocalPCM16TranscriptionAdapterError.emptyAudio) {
            try await adapter.transcribe(
                snapshot: snapshot,
                model: makeFluidModel(name: "empty-audio-model"),
                context: TranscriptionRequestContext(language: nil, prompt: nil)
            )
        }

        #expect(invocationCount == 0)
        #expect(snapshot.isZeroized)
    }

    @Test @MainActor
    func engineFailureZeroizesTheSourceSnapshot() async {
        enum ExpectedError: Error {
            case failed
        }

        let snapshot = PCM16Snapshot(pcmData: pcmData([100, -100]))
        let adapter = LocalPCM16TranscriptionAdapter(provider: .fluidAudio) { samples, model, context in
            #expect(samples.count == 2)
            #expect(model.name == "failing-parakeet")
            #expect(context.language == "en")
            throw ExpectedError.failed
        }

        await #expect(throws: ExpectedError.failed) {
            try await adapter.transcribe(
                snapshot: snapshot,
                model: makeFluidModel(name: "failing-parakeet"),
                context: TranscriptionRequestContext(language: "en", prompt: "ignored by FluidAudio")
            )
        }

        #expect(snapshot.isZeroized)
    }

    @Test @MainActor
    func cancellationBeforeDispatchZeroizesWithoutInvokingTheEngine() async {
        let snapshot = PCM16Snapshot(pcmData: pcmData([100]))
        var invocationCount = 0
        let adapter = LocalPCM16TranscriptionAdapter(provider: .whisper) { _, _, _ in
            invocationCount += 1
            return "unexpected"
        }
        let model = makeWhisperModel(name: "cancelled-whisper")
        let context = TranscriptionRequestContext(language: "en", prompt: nil)

        let task = Task { @MainActor in
            try await adapter.transcribe(
                snapshot: snapshot,
                model: model,
                context: context
            )
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(invocationCount == 0)
        #expect(snapshot.isZeroized)
    }

    @Test @MainActor
    func productionLocalServicesExposeTheSharedMemoryBoundary() {
        let whisper: any LocalPCM16TranscriptionServicing = WhisperTranscriptionService(
            modelsDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        let fluidAudio: any LocalPCM16TranscriptionServicing = FluidAudioTranscriptionService()

        #expect(whisper is WhisperTranscriptionService)
        #expect(fluidAudio is FluidAudioTranscriptionService)
    }

    @Test func explicitFloatZeroizationReleasesTheOwnedArray() {
        var samples: [Float] = [-1, 0.25, 1]

        LocalPCM16TranscriptionAdapter.zeroize(&samples)

        #expect(samples.isEmpty)
    }

    private func makeWhisperModel(name: String) -> WhisperModel {
        WhisperModel(
            name: name,
            displayName: "Test Whisper",
            size: "1 MB",
            supportedLanguages: ["en": "English", "pt": "Portuguese"],
            description: "Local test model",
            speed: 1,
            accuracy: 1,
            ramUsage: 1
        )
    }

    private func makeFluidModel(name: String) -> FluidAudioModel {
        FluidAudioModel(
            name: name,
            displayName: "Test FluidAudio",
            description: "Local test model",
            size: "1 MB",
            speed: 1,
            accuracy: 1,
            ramUsage: 1,
            supportedLanguages: ["en": "English"]
        )
    }

    private func pcmData(_ samples: [Int16]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
