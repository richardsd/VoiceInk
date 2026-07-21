import Foundation
import LLMkit
import Testing
@testable import VoiceInk

struct InMemoryTranscriptionCapabilityRegistryTests {
    @Test func everyProviderHasAnExplicitCapabilityDecision() {
        let expected: [ModelProvider: InMemoryTranscriptionCapabilityDecision] = [
            .groq: .supported(.batchCloudWAVData),
            .elevenLabs: .supported(.batchCloudWAVData),
            .deepgram: .supported(.batchCloudWAVData),
            .mistral: .supported(.batchCloudWAVData),
            .gemini: .supported(.batchCloudWAVData),
            .soniox: .supported(.batchCloudWAVData),
            .speechmatics: .supported(.batchCloudWAVData),
            .assemblyAI: .supported(.batchCloudWAVData),
            .xai: .supported(.batchCloudWAVData),
            .cartesia: .unsupported(.streamingOnly),
            .nativeApple: .unsupported(.fileBackedServiceOnly),
            .custom: .unsupported(.fileBackedServiceOnly),
            .whisper: .supported(.localPCM16),
            .fluidAudio: .supported(.localPCM16),
        ]

        #expect(expected.count == ModelProvider.allCases.count)
        for provider in ModelProvider.allCases {
            let route = InMemoryTranscriptionModelRoute(
                provider: provider,
                modelName: "test-model"
            )
            #expect(
                InMemoryTranscriptionCapabilityRegistry.decision(for: route)
                    == expected[provider]
            )
        }
    }

    @Test func audioSourceDistinguishesFileAndMemoryWithoutReadingEither() {
        let file = TranscriptionAudioSource.file(
            URL(fileURLWithPath: "/never-read.wav")
        )
        let memory = TranscriptionAudioSource.pcm16(PCM16Snapshot(pcmData: Data([0, 1])))

        #expect(file.kind == .file)
        #expect(memory.kind == .pcm16Memory)
    }

    @Test func strictRouteResolutionUsesOnlyTheExplicitModel() throws {
        let selected = model(name: "selected", provider: .groq)
        let fallback = model(name: "fallback", provider: .gemini)

        let resolved = try StrictTranscriptionModelRouteResolver.resolve(
            selectedModelName: "selected",
            availableModels: [fallback, selected]
        )

        #expect(resolved.model.name == "selected")
        #expect(resolved.route == InMemoryTranscriptionModelRoute(
            provider: .groq,
            modelName: "selected"
        ))
    }

    @Test func strictRouteResolutionNeverFallsBack() {
        let models: [any TranscriptionModel] = [
            model(name: "available", provider: .groq)
        ]

        #expect(throws: StrictTranscriptionModelResolutionError.modelNotSelected) {
            _ = try StrictTranscriptionModelRouteResolver.resolve(
                selectedModelName: nil,
                availableModels: models
            )
        }
        #expect(throws: StrictTranscriptionModelResolutionError.modelUnavailable) {
            _ = try StrictTranscriptionModelRouteResolver.resolve(
                selectedModelName: "missing",
                availableModels: models
            )
        }
    }

    @Test func strictRouteResolutionRejectsAmbiguousAndUnsupportedModels() {
        let duplicateModels: [any TranscriptionModel] = [
            model(name: "duplicate", provider: .groq),
            model(name: "duplicate", provider: .gemini),
        ]
        #expect(throws: StrictTranscriptionModelResolutionError.ambiguousModelName) {
            _ = try StrictTranscriptionModelRouteResolver.resolve(
                selectedModelName: "duplicate",
                availableModels: duplicateModels
            )
        }

        #expect(
            throws: StrictTranscriptionModelResolutionError.unsupported(.fileBackedServiceOnly)
        ) {
            _ = try StrictTranscriptionModelRouteResolver.resolve(
                selectedModelName: "native",
                availableModels: [model(name: "native", provider: .nativeApple)]
            )
        }
    }

    private func model(name: String, provider: ModelProvider) -> CloudModel {
        CloudModel(
            name: name,
            displayName: name,
            description: "Test model",
            provider: provider,
            speed: 1,
            accuracy: 1,
            isMultilingual: true,
            supportedLanguages: [:]
        )
    }
}

@MainActor
struct BatchCloudInMemoryTranscriptionServiceTests {
    @Test func supportedPCMIsEncodedAndSentThroughTheSameProviderRoute() async throws {
        let snapshot = PCM16Snapshot(pcmData: Data([0x00, 0x01, 0x02, 0x03]))
        var capturedPayload: InMemoryBatchCloudPayload?
        var capturedAudioPrefix = Data()
        let service = makeService { payload in
            capturedPayload = payload
            capturedAudioPrefix = try await payload.withAudioData { audioData in
                Data(audioData.prefix(4))
            }
            return "  Memory transcript  "
        }
        let requestID = UUID()

        let result = try await service.transcribe(
            request(
                id: requestID,
                source: .pcm16(snapshot),
                provider: .groq,
                modelName: "whisper-large-v3-turbo",
                language: "pt",
                vocabulary: ["VoiceInk", "Luna"]
            )
        )

        #expect(result == InMemoryTranscriptionResult(
            requestID: requestID,
            text: "Memory transcript"
        ))
        #expect(capturedPayload?.fileName == "time-shift.wav")
        #expect(capturedPayload?.modelName == "whisper-large-v3-turbo")
        #expect(capturedPayload?.language == "pt")
        #expect(capturedPayload?.customVocabulary == ["VoiceInk", "Luna"])
        #expect(capturedPayload?.apiKey == "test-key")
        #expect(capturedAudioPrefix == Data("RIFF".utf8))
        #expect(capturedPayload?.isAudioZeroized == true)
        #expect(snapshot.isZeroized)
    }

    @Test func fileSourceIsRejectedWithoutLookupOrFallback() async {
        var didLookupProvider = false
        let service = BatchCloudInMemoryTranscriptionService(
            providerLookup: { _ in
                didLookupProvider = true
                return nil
            },
            credentialLookup: { _ in
                Issue.record("File rejection must not resolve credentials")
                return nil
            }
        )

        do {
            _ = try await service.transcribe(
                request(
                    source: .file(URL(fileURLWithPath: "/never-read.wav")),
                    provider: .groq
                )
            )
            Issue.record("A file source must not enter the memory adapter")
        } catch let error as InMemoryTranscriptionError {
            #expect(error == .fileSourceNotAllowed)
        } catch {
            Issue.record("Unexpected error type")
        }

        #expect(!didLookupProvider)
    }

    @Test func unsupportedProviderZeroizesAudioWithoutLookingUpFallback() async {
        let snapshot = PCM16Snapshot(pcmData: Data([0, 1]))
        var didLookupProvider = false
        let service = BatchCloudInMemoryTranscriptionService(
            providerLookup: { _ in
                didLookupProvider = true
                return nil
            },
            credentialLookup: { _ in nil }
        )

        do {
            _ = try await service.transcribe(
                request(source: .pcm16(snapshot), provider: .cartesia)
            )
            Issue.record("Streaming-only provider must be rejected")
        } catch let error as InMemoryTranscriptionError {
            #expect(error == .unsupported(.streamingOnly))
        } catch {
            Issue.record("Unexpected error type")
        }

        #expect(!didLookupProvider)
        #expect(snapshot.isZeroized)
    }

    @Test func providerIdentityMismatchNeverReroutes() async {
        let snapshot = PCM16Snapshot(pcmData: Data([0, 1]))
        var didTranscribe = false
        let service = BatchCloudInMemoryTranscriptionService(
            providerLookup: { _ in
                InMemoryBatchCloudProvider(
                    modelProvider: .gemini,
                    providerKey: "Gemini",
                    isStreamingOnly: false,
                    supportedModelNames: ["test-model"],
                    transcribe: { _ in
                        didTranscribe = true
                        return "Wrong route"
                    }
                )
            },
            credentialLookup: { _ in "test-key" }
        )

        do {
            _ = try await service.transcribe(
                request(source: .pcm16(snapshot), provider: .groq)
            )
            Issue.record("A different provider must not be used")
        } catch let error as InMemoryTranscriptionError {
            #expect(error == .unsupported(.providerIdentityMismatch))
        } catch {
            Issue.record("Unexpected error type")
        }

        #expect(!didTranscribe)
        #expect(snapshot.isZeroized)
    }

    @Test func unknownModelIsRejectedBeforeCredentialLookupOrProviderCall() async {
        let snapshot = PCM16Snapshot(pcmData: Data([0, 1]))
        var didResolveCredential = false
        var didTranscribe = false
        let service = BatchCloudInMemoryTranscriptionService(
            providerLookup: { provider in
                InMemoryBatchCloudProvider(
                    modelProvider: provider,
                    providerKey: provider.rawValue,
                    isStreamingOnly: false,
                    supportedModelNames: ["known-model"],
                    transcribe: { _ in
                        didTranscribe = true
                        return "Unexpected"
                    }
                )
            },
            credentialLookup: { _ in
                didResolveCredential = true
                return "test-key"
            }
        )

        do {
            _ = try await service.transcribe(
                request(
                    source: .pcm16(snapshot),
                    provider: .groq,
                    modelName: "unknown-model"
                )
            )
            Issue.record("An unregistered model must not reach a provider")
        } catch let error as InMemoryTranscriptionError {
            #expect(error == .unsupported(.modelNotRegistered))
        } catch {
            Issue.record("Unexpected error type")
        }

        #expect(!didResolveCredential)
        #expect(!didTranscribe)
        #expect(snapshot.isZeroized)
    }

    @Test func missingCredentialDoesNotEncodeOrCallProvider() async {
        let snapshot = PCM16Snapshot(pcmData: Data([0, 1]))
        var didTranscribe = false
        let service = makeService(
            credential: nil,
            transcribe: { _ in
                didTranscribe = true
                return "Unexpected"
            }
        )

        do {
            _ = try await service.transcribe(
                request(source: .pcm16(snapshot), provider: .groq)
            )
            Issue.record("Missing credentials must fail")
        } catch let error as InMemoryTranscriptionError {
            #expect(error == .credentialsUnavailable)
        } catch {
            Issue.record("Unexpected error type")
        }

        #expect(!didTranscribe)
        #expect(snapshot.isZeroized)
    }

    @Test func rawBackendFailureIsReducedToSanitizedCategory() async {
        let snapshot = PCM16Snapshot(pcmData: Data([0, 1]))
        let service = makeService { _ in
            throw CloudTranscriptionError.apiRequestFailed(
                statusCode: 429,
                message: "raw provider response that must not escape"
            )
        }

        do {
            _ = try await service.transcribe(
                request(source: .pcm16(snapshot), provider: .groq)
            )
            Issue.record("Rate limit should fail")
        } catch let error as InMemoryTranscriptionError {
            #expect(error == .rateLimited)
        } catch {
            Issue.record("Unexpected error type")
        }

        #expect(snapshot.isZeroized)
    }

    @Test func emptyProviderResultIsRejectedAndAudioIsCleared() async {
        let snapshot = PCM16Snapshot(pcmData: Data([0, 1]))
        let service = makeService { _ in " \n " }

        do {
            _ = try await service.transcribe(
                request(source: .pcm16(snapshot), provider: .groq)
            )
            Issue.record("Empty result should fail")
        } catch let error as InMemoryTranscriptionError {
            #expect(error == .emptyResult)
        } catch {
            Issue.record("Unexpected error type")
        }

        #expect(snapshot.isZeroized)
    }

    @Test func llmKitErrorsAreSanitizedWithoutRawDetails() {
        #expect(
            InMemoryTranscriptionError.sanitized(LLMKitError.timeout)
                == .timedOut
        )
        #expect(
            InMemoryTranscriptionError.sanitized(
                LLMKitError.httpError(statusCode: 403, message: "secret backend body")
            ) == .authenticationExpired
        )
        #expect(
            InMemoryTranscriptionError.sanitized(
                LLMKitError.httpError(statusCode: 503, message: "secret backend body")
            ) == .serverUnavailable
        )
        #expect(
            InMemoryTranscriptionError.sanitized(
                LLMKitError.networkError("private network detail")
            ) == .networkUnavailable
        )
    }

    private func makeService(
        credential: String? = "test-key",
        transcribe: @escaping @MainActor (InMemoryBatchCloudPayload) async throws -> String
    ) -> BatchCloudInMemoryTranscriptionService {
        BatchCloudInMemoryTranscriptionService(
            providerLookup: { provider in
                InMemoryBatchCloudProvider(
                    modelProvider: provider,
                    providerKey: provider.rawValue,
                    isStreamingOnly: false,
                    supportedModelNames: ["test-model", "whisper-large-v3-turbo"],
                    transcribe: transcribe
                )
            },
            credentialLookup: { _ in credential }
        )
    }

    private func request(
        id: UUID = UUID(),
        source: TranscriptionAudioSource,
        provider: ModelProvider,
        modelName: String = "test-model",
        language: String? = "auto",
        vocabulary: [String] = []
    ) -> InMemoryTranscriptionRequest {
        InMemoryTranscriptionRequest(
            id: id,
            source: source,
            route: InMemoryTranscriptionModelRoute(
                provider: provider,
                modelName: modelName
            ),
            context: TranscriptionRequestContext(
                language: language,
                prompt: "Frozen prompt"
            ),
            customVocabulary: vocabulary
        )
    }
}

@MainActor
struct TranscriptionAudioSourceRouterTests {
    @Test func fileSourceDelegatesOnlyToInjectedFileService() async throws {
        let memory = MemoryTranscriptionServiceSpy()
        let fileService = FileTranscriptionServiceSpy()
        let router = TranscriptionAudioSourceRouter(
            fileService: fileService,
            inMemoryService: memory
        )
        let url = URL(fileURLWithPath: "/injected/existing.wav")
        let requestID = UUID()

        let result = try await router.transcribe(
            sourceRequest(
                id: requestID,
                source: .file(url),
                model: model(name: "file-model", provider: .groq)
            )
        )

        #expect(result == InMemoryTranscriptionResult(
            requestID: requestID,
            text: "File transcript"
        ))
        #expect(fileService.receivedURL == url)
        #expect(fileService.receivedModelName == "file-model")
        #expect(memory.requests.isEmpty)
    }

    @Test func memorySourceDelegatesOnlyToApprovedMemoryAdapter() async throws {
        let memory = MemoryTranscriptionServiceSpy(resultText: "Memory transcript")
        var didUseFileService = false
        let router = TranscriptionAudioSourceRouter(
            fileTranscriber: { _, _, _ in
                didUseFileService = true
                return "Unexpected fallback"
            },
            inMemoryService: memory
        )
        let snapshot = PCM16Snapshot(pcmData: Data([0, 1]))
        let requestID = UUID()

        let result = try await router.transcribe(
            sourceRequest(
                id: requestID,
                source: .pcm16(snapshot),
                model: model(name: "memory-model", provider: .groq)
            )
        )

        #expect(result.requestID == requestID)
        #expect(result.text == "Memory transcript")
        #expect(!didUseFileService)
        #expect(memory.requests.count == 1)
        #expect(memory.requests.first?.route == InMemoryTranscriptionModelRoute(
            provider: .groq,
            modelName: "memory-model"
        ))
    }

    private func sourceRequest(
        id: UUID,
        source: TranscriptionAudioSource,
        model: any TranscriptionModel
    ) -> TranscriptionAudioSourceRequest {
        TranscriptionAudioSourceRequest(
            id: id,
            source: source,
            model: model,
            context: TranscriptionRequestContext(language: "en", prompt: nil),
            customVocabulary: ["VoiceInk"]
        )
    }

    private func model(name: String, provider: ModelProvider) -> CloudModel {
        CloudModel(
            name: name,
            displayName: name,
            description: "Test model",
            provider: provider,
            speed: 1,
            accuracy: 1,
            isMultilingual: true,
            supportedLanguages: [:]
        )
    }
}

@MainActor
struct RoutedInMemoryTranscriptionServiceTests {
    @Test func localRouteUsesOnlyTheLocalAdapterAndPreservesExactModel() async throws {
        let cloud = MemoryTranscriptionServiceSpy(resultText: "wrong cloud route")
        let localEngine = LocalPCM16ServiceSpy(resultText: "  local result  ")
        let local = LocalInMemoryTranscriptionService { provider in
            provider == .whisper ? localEngine : nil
        }
        let service = RoutedInMemoryTranscriptionService(
            cloudService: cloud,
            localService: local
        )
        let snapshot = PCM16Snapshot(pcmData: Data([0, 1]))
        let model = WhisperModel(
            name: "ggml-tiny",
            displayName: "Tiny",
            size: "1 MB",
            supportedLanguages: ["en": "English"],
            description: "Test",
            speed: 1,
            accuracy: 1,
            ramUsage: 1
        )

        let result = try await service.transcribe(
            InMemoryTranscriptionRequest(
                source: .pcm16(snapshot),
                route: InMemoryTranscriptionModelRoute(model: model),
                model: model,
                context: TranscriptionRequestContext(language: "en", prompt: "Exact prompt")
            )
        )

        #expect(result.text == "local result")
        #expect(localEngine.receivedModelName == "ggml-tiny")
        #expect(localEngine.receivedPrompt == "Exact prompt")
        #expect(cloud.requests.isEmpty)
        #expect(snapshot.isZeroized)
    }

    @Test func cloudRouteNeverTouchesTheLocalAdapter() async throws {
        let cloud = MemoryTranscriptionServiceSpy(resultText: "cloud result")
        let localEngine = LocalPCM16ServiceSpy(resultText: "wrong local route")
        let local = LocalInMemoryTranscriptionService { _ in localEngine }
        let service = RoutedInMemoryTranscriptionService(
            cloudService: cloud,
            localService: local
        )
        let model = CloudModel(
            name: "cloud-model",
            displayName: "Cloud",
            description: "Test",
            provider: .groq,
            speed: 1,
            accuracy: 1,
            isMultilingual: true,
            supportedLanguages: [:]
        )

        let result = try await service.transcribe(
            InMemoryTranscriptionRequest(
                source: .pcm16(PCM16Snapshot(pcmData: Data([0, 1]))),
                route: InMemoryTranscriptionModelRoute(model: model),
                model: model,
                context: TranscriptionRequestContext(language: nil, prompt: nil)
            )
        )

        #expect(result.text == "cloud result")
        #expect(cloud.requests.count == 1)
        #expect(localEngine.invocationCount == 0)
    }
}

@MainActor
private final class MemoryTranscriptionServiceSpy: InMemoryTranscriptionServicing {
    private(set) var requests: [InMemoryTranscriptionRequest] = []
    private let resultText: String

    init(resultText: String = "Unused") {
        self.resultText = resultText
    }

    func transcribe(
        _ request: InMemoryTranscriptionRequest
    ) async throws -> InMemoryTranscriptionResult {
        requests.append(request)
        return InMemoryTranscriptionResult(
            requestID: request.id,
            text: resultText
        )
    }
}

@MainActor
private final class LocalPCM16ServiceSpy: LocalPCM16TranscriptionServicing {
    private let resultText: String
    private(set) var invocationCount = 0
    private(set) var receivedModelName: String?
    private(set) var receivedPrompt: String?

    init(resultText: String) {
        self.resultText = resultText
    }

    func transcribe(
        pcm16Snapshot: PCM16Snapshot,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        invocationCount += 1
        receivedModelName = model.name
        receivedPrompt = context.prompt
        pcm16Snapshot.zeroize()
        return resultText
    }
}

private final class FileTranscriptionServiceSpy: TranscriptionService {
    private(set) var receivedURL: URL?
    private(set) var receivedModelName: String?

    func transcribe(
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        receivedURL = audioURL
        receivedModelName = model.name
        return "File transcript"
    }
}
