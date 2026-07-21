import Foundation
import LLMkit

enum TranscriptionAudioSource {
    case file(URL)
    case pcm16(PCM16Snapshot)

    var kind: TranscriptionAudioSourceKind {
        switch self {
        case .file: return .file
        case .pcm16: return .pcm16Memory
        }
    }
}

enum TranscriptionAudioSourceKind: Equatable, Sendable {
    case file
    case pcm16Memory
}

struct InMemoryTranscriptionModelRoute: Equatable {
    let provider: ModelProvider
    let modelName: String

    init(provider: ModelProvider, modelName: String) {
        self.provider = provider
        self.modelName = modelName
    }

    init(model: any TranscriptionModel) {
        provider = model.provider
        modelName = model.name
    }
}

enum InMemoryTranscriptionAdapterKind: Equatable, Sendable {
    /// The existing provider accepts an in-memory WAV payload as `Data`.
    case batchCloudWAVData

    /// The local engine accepts normalized Float32 samples without a file.
    case localPCM16
}

enum InMemoryTranscriptionUnsupportedReason: Equatable, Sendable {
    case streamingOnly
    case fileBackedServiceOnly
    case pcmAdapterUnavailable
    case providerNotRegistered
    case providerIdentityMismatch
    case modelNotRegistered
}

enum InMemoryTranscriptionCapabilityDecision: Equatable, Sendable {
    case supported(InMemoryTranscriptionAdapterKind)
    case unsupported(InMemoryTranscriptionUnsupportedReason)
}

/// Explicit allowlist for memory-only transcription. New providers remain
/// unavailable until they deliberately add a safe adapter here.
enum InMemoryTranscriptionCapabilityRegistry {
    static func decision(
        for route: InMemoryTranscriptionModelRoute
    ) -> InMemoryTranscriptionCapabilityDecision {
        switch route.provider {
        case .groq, .elevenLabs, .deepgram, .mistral, .gemini, .soniox,
            .speechmatics, .assemblyAI, .xai:
            return .supported(.batchCloudWAVData)

        case .cartesia:
            return .unsupported(.streamingOnly)

        case .nativeApple, .custom:
            return .unsupported(.fileBackedServiceOnly)

        case .whisper, .fluidAudio:
            return .supported(.localPCM16)
        }
    }
}

enum StrictTranscriptionModelResolutionError: Error, Equatable, Sendable {
    case modelNotSelected
    case modelUnavailable
    case ambiguousModelName
    case unsupported(InMemoryTranscriptionUnsupportedReason)
}

/// Resolves a transcription model without adopting the fallback behavior used
/// by normal recordings. Time-Shift must either use the explicitly selected
/// model or remain unavailable.
enum StrictTranscriptionModelRouteResolver {
    static func resolve(
        selectedModelName: String?,
        availableModels: [any TranscriptionModel],
        capabilityResolver: (InMemoryTranscriptionModelRoute) -> InMemoryTranscriptionCapabilityDecision = {
            InMemoryTranscriptionCapabilityRegistry.decision(for: $0)
        }
    ) throws -> (model: any TranscriptionModel, route: InMemoryTranscriptionModelRoute) {
        guard let selectedModelName, !selectedModelName.isEmpty else {
            throw StrictTranscriptionModelResolutionError.modelNotSelected
        }

        let matches = availableModels.filter { $0.name == selectedModelName }
        guard !matches.isEmpty else {
            throw StrictTranscriptionModelResolutionError.modelUnavailable
        }
        guard matches.count == 1, let model = matches.first else {
            throw StrictTranscriptionModelResolutionError.ambiguousModelName
        }

        let route = InMemoryTranscriptionModelRoute(model: model)
        let decision = capabilityResolver(route)
        guard case .supported = decision else {
            guard case .unsupported(let reason) = decision else {
                throw StrictTranscriptionModelResolutionError.modelUnavailable
            }
            throw StrictTranscriptionModelResolutionError.unsupported(reason)
        }
        return (model, route)
    }
}

struct TranscriptionAudioSourceRequest {
    let id: UUID
    let source: TranscriptionAudioSource
    let model: any TranscriptionModel
    let context: TranscriptionRequestContext
    let customVocabulary: [String]

    init(
        id: UUID = UUID(),
        source: TranscriptionAudioSource,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext,
        customVocabulary: [String] = []
    ) {
        self.id = id
        self.source = source
        self.model = model
        self.context = context
        self.customVocabulary = customVocabulary
    }
}

struct InMemoryTranscriptionRequest {
    let id: UUID
    let source: TranscriptionAudioSource
    let route: InMemoryTranscriptionModelRoute
    /// The exact already-resolved model. Local engines require the concrete
    /// frozen value; cloud tests may omit it and rely on the validated route.
    let model: (any TranscriptionModel)?
    let context: TranscriptionRequestContext
    let customVocabulary: [String]

    init(
        id: UUID = UUID(),
        source: TranscriptionAudioSource,
        route: InMemoryTranscriptionModelRoute,
        model: (any TranscriptionModel)? = nil,
        context: TranscriptionRequestContext,
        customVocabulary: [String] = []
    ) {
        self.id = id
        self.source = source
        self.route = route
        self.model = model
        self.context = context
        self.customVocabulary = customVocabulary
    }
}

struct InMemoryTranscriptionResult: Equatable, Sendable {
    let requestID: UUID
    let text: String
}

enum InMemoryTranscriptionError: Error, Equatable, Sendable {
    case unsupported(InMemoryTranscriptionUnsupportedReason)
    case fileSourceNotAllowed
    case emptyAudio
    case audioEncodingFailed
    case credentialsUnavailable
    case authenticationExpired
    case rateLimited
    case timedOut
    case networkUnavailable
    case serverUnavailable
    case malformedResponse
    case emptyResult
    case cancelled
    case failed

    static func sanitized(_ error: Error) -> InMemoryTranscriptionError {
        if error is CancellationError {
            return .cancelled
        }
        if let error = error as? InMemoryTranscriptionError {
            return error
        }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            default: return .networkUnavailable
            }
        }
        guard let error = error as? CloudTranscriptionError else {
            guard let error = error as? LLMKitError else {
                return .failed
            }
            switch error {
            case .missingAPIKey:
                return .credentialsUnavailable
            case .httpError(let statusCode, _):
                switch statusCode {
                case 401, 403: return .authenticationExpired
                case 408: return .timedOut
                case 429: return .rateLimited
                case 500...599: return .serverUnavailable
                default: return .failed
                }
            case .noResultReturned, .encodingError, .decodingError:
                return .malformedResponse
            case .timeout:
                return .timedOut
            case .networkError:
                return .networkUnavailable
            case .invalidURL:
                return .failed
            }
        }

        switch error {
        case .unsupportedProvider:
            return .unsupported(.providerNotRegistered)
        case .missingAPIKey:
            return .credentialsUnavailable
        case .invalidAPIKey:
            return .authenticationExpired
        case .audioFileNotFound:
            // A Data adapter must never ask a provider to read a file.
            return .fileSourceNotAllowed
        case .apiRequestFailed(let statusCode, _):
            switch statusCode {
            case 401, 403: return .authenticationExpired
            case 429: return .rateLimited
            case 500...599: return .serverUnavailable
            default: return .failed
            }
        case .networkError(let underlyingError):
            if underlyingError is CancellationError {
                return .cancelled
            }
            if let urlError = underlyingError as? URLError,
                urlError.code == .timedOut
            {
                return .timedOut
            }
            if let urlError = underlyingError as? URLError,
                urlError.code == .cancelled
            {
                return .cancelled
            }
            return .networkUnavailable
        case .noTranscriptionReturned, .dataEncodingError:
            return .malformedResponse
        }
    }
}

@MainActor
protocol InMemoryTranscriptionServicing: AnyObject {
    func transcribe(
        _ request: InMemoryTranscriptionRequest
    ) async throws -> InMemoryTranscriptionResult
}

/// Owns the provider payload and clears it even if a test or provider facade
/// retains the payload object beyond the request. The scoped `Data` passed to
/// Foundation networking is also overwritten immediately after the provider
/// call returns.
final class InMemoryBatchCloudPayload: @unchecked Sendable {
    let fileName: String
    let apiKey: String
    let modelName: String
    let language: String?
    let customVocabulary: [String]

    private let lock = NSLock()
    private var audioStorage: Data

    init(
        audioData: Data,
        fileName: String,
        apiKey: String,
        modelName: String,
        language: String?,
        customVocabulary: [String]
    ) {
        audioStorage = audioData.withUnsafeBytes { Data($0) }
        self.fileName = fileName
        self.apiKey = apiKey
        self.modelName = modelName
        self.language = language
        self.customVocabulary = customVocabulary
    }

    deinit {
        zeroizeAudio()
    }

    var isAudioZeroized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return audioStorage.isEmpty
    }

    func withAudioData<Result>(
        _ operation: (Data) async throws -> Result
    ) async rethrows -> Result {
        var scopedData = audioDataCopy()

        defer { Self.zeroize(&scopedData) }
        return try await operation(scopedData)
    }

    func zeroizeAudio() {
        lock.lock()
        defer { lock.unlock() }
        Self.zeroize(&audioStorage)
    }

    private func audioDataCopy() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return audioStorage.withUnsafeBytes { Data($0) }
    }

    private static func zeroize(_ data: inout Data) {
        guard !data.isEmpty else { return }
        data.resetBytes(in: 0..<data.count)
        data.removeAll(keepingCapacity: false)
    }
}

/// Closure-backed facade over an existing `CloudProvider`. It is the only live
/// adapter added here because that protocol already accepts audio `Data`.
struct InMemoryBatchCloudProvider {
    let modelProvider: ModelProvider
    let providerKey: String
    let isStreamingOnly: Bool
    let supportedModelNames: Set<String>
    let transcribe: @MainActor (InMemoryBatchCloudPayload) async throws -> String
}

@MainActor
final class BatchCloudInMemoryTranscriptionService: InMemoryTranscriptionServicing {
    typealias CapabilityResolver =
        (InMemoryTranscriptionModelRoute) -> InMemoryTranscriptionCapabilityDecision
    typealias ProviderLookup = (ModelProvider) -> InMemoryBatchCloudProvider?
    typealias CredentialLookup = (String) -> String?

    private let capabilityResolver: CapabilityResolver
    private let providerLookup: ProviderLookup
    private let credentialLookup: CredentialLookup

    init(
        capabilityResolver: @escaping CapabilityResolver = {
            InMemoryTranscriptionCapabilityRegistry.decision(for: $0)
        },
        providerLookup: @escaping ProviderLookup = { modelProvider in
            guard let provider = CloudProviderRegistry.provider(for: modelProvider) else {
                return nil
            }
            return InMemoryBatchCloudProvider(
                modelProvider: provider.modelProvider,
                providerKey: provider.providerKey,
                isStreamingOnly: provider.isStreamingOnly,
                supportedModelNames: Set(provider.models.map(\.name)),
                transcribe: { payload in
                    try await payload.withAudioData { audioData in
                        try await provider.transcribe(
                            audioData: audioData,
                            fileName: payload.fileName,
                            apiKey: payload.apiKey,
                            model: payload.modelName,
                            language: payload.language,
                            customVocabulary: payload.customVocabulary
                        )
                    }
                }
            )
        },
        credentialLookup: @escaping CredentialLookup = {
            APIKeyManager.shared.getAPIKey(forProvider: $0)
        }
    ) {
        self.capabilityResolver = capabilityResolver
        self.providerLookup = providerLookup
        self.credentialLookup = credentialLookup
    }

    func transcribe(
        _ request: InMemoryTranscriptionRequest
    ) async throws -> InMemoryTranscriptionResult {
        guard case .pcm16(let snapshot) = request.source else {
            throw InMemoryTranscriptionError.fileSourceNotAllowed
        }
        defer { snapshot.zeroize() }

        guard !snapshot.isEmpty else {
            throw InMemoryTranscriptionError.emptyAudio
        }

        let decision = capabilityResolver(request.route)
        guard decision == .supported(.batchCloudWAVData) else {
            guard case .unsupported(let reason) = decision else {
                throw InMemoryTranscriptionError.failed
            }
            throw InMemoryTranscriptionError.unsupported(reason)
        }

        guard let provider = providerLookup(request.route.provider) else {
            throw InMemoryTranscriptionError.unsupported(.providerNotRegistered)
        }
        guard provider.modelProvider == request.route.provider else {
            throw InMemoryTranscriptionError.unsupported(.providerIdentityMismatch)
        }
        guard !provider.isStreamingOnly else {
            throw InMemoryTranscriptionError.unsupported(.streamingOnly)
        }
        guard provider.supportedModelNames.contains(request.route.modelName) else {
            throw InMemoryTranscriptionError.unsupported(.modelNotRegistered)
        }
        guard let apiKey = credentialLookup(provider.providerKey),
            !apiKey.isEmpty
        else {
            throw InMemoryTranscriptionError.credentialsUnavailable
        }

        var wavData: Data
        do {
            wavData = try PCM16WAVEncoder.encode(snapshot)
        } catch {
            throw InMemoryTranscriptionError.audioEncodingFailed
        }
        defer { Self.zeroize(&wavData) }

        let language = request.context.language.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == "auto" ? nil : trimmed
        }

        do {
            try Task.checkCancellation()
            let payload = InMemoryBatchCloudPayload(
                audioData: wavData,
                fileName: "time-shift.wav",
                apiKey: apiKey,
                modelName: request.route.modelName,
                language: language,
                customVocabulary: request.customVocabulary
            )
            defer { payload.zeroizeAudio() }
            let text = try await provider.transcribe(payload)
            try Task.checkCancellation()

            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                throw InMemoryTranscriptionError.emptyResult
            }
            return InMemoryTranscriptionResult(
                requestID: request.id,
                text: trimmedText
            )
        } catch {
            throw InMemoryTranscriptionError.sanitized(error)
        }
    }

    private static func zeroize(_ data: inout Data) {
        guard !data.isEmpty else { return }
        data.resetBytes(in: 0..<data.count)
        data.removeAll(keepingCapacity: false)
    }
}

/// Dispatches direct PCM to the existing local engines. It requires the exact
/// resolved model object and never performs a registry lookup or fallback.
@MainActor
final class LocalInMemoryTranscriptionService: InMemoryTranscriptionServicing {
    typealias ServiceLookup = (ModelProvider) -> (any LocalPCM16TranscriptionServicing)?

    private let serviceLookup: ServiceLookup

    init(serviceLookup: @escaping ServiceLookup) {
        self.serviceLookup = serviceLookup
    }

    convenience init(
        whisperService: any LocalPCM16TranscriptionServicing,
        fluidAudioService: any LocalPCM16TranscriptionServicing
    ) {
        self.init { provider in
            switch provider {
            case .whisper:
                return whisperService
            case .fluidAudio:
                return fluidAudioService
            default:
                return nil
            }
        }
    }

    func transcribe(
        _ request: InMemoryTranscriptionRequest
    ) async throws -> InMemoryTranscriptionResult {
        guard case .pcm16(let snapshot) = request.source else {
            throw InMemoryTranscriptionError.fileSourceNotAllowed
        }
        defer { snapshot.zeroize() }

        guard !snapshot.isEmpty else {
            throw InMemoryTranscriptionError.emptyAudio
        }
        guard case .supported(.localPCM16) =
            InMemoryTranscriptionCapabilityRegistry.decision(for: request.route)
        else {
            throw InMemoryTranscriptionError.unsupported(.pcmAdapterUnavailable)
        }
        guard let model = request.model,
            model.provider == request.route.provider,
            model.name == request.route.modelName
        else {
            throw InMemoryTranscriptionError.unsupported(.providerIdentityMismatch)
        }
        guard let service = serviceLookup(request.route.provider) else {
            throw InMemoryTranscriptionError.unsupported(.pcmAdapterUnavailable)
        }

        do {
            try Task.checkCancellation()
            let text = try await service.transcribe(
                pcm16Snapshot: snapshot,
                model: model,
                context: request.context
            )
            try Task.checkCancellation()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw InMemoryTranscriptionError.emptyResult
            }
            return InMemoryTranscriptionResult(requestID: request.id, text: trimmed)
        } catch let error as LocalPCM16TranscriptionAdapterError {
            switch error {
            case .emptyAudio:
                throw InMemoryTranscriptionError.emptyAudio
            case .providerMismatch:
                throw InMemoryTranscriptionError.unsupported(.providerIdentityMismatch)
            }
        } catch {
            throw InMemoryTranscriptionError.sanitized(error)
        }
    }
}

/// Central memory-only dispatcher. Capability selection is explicit and each
/// adapter is retried exactly zero times, preventing cross-engine fallback.
@MainActor
final class RoutedInMemoryTranscriptionService: InMemoryTranscriptionServicing {
    private let cloudService: any InMemoryTranscriptionServicing
    private let localService: any InMemoryTranscriptionServicing
    private let capabilityResolver: (
        InMemoryTranscriptionModelRoute
    ) -> InMemoryTranscriptionCapabilityDecision

    init(
        cloudService: any InMemoryTranscriptionServicing,
        localService: any InMemoryTranscriptionServicing,
        capabilityResolver: @escaping (
            InMemoryTranscriptionModelRoute
        ) -> InMemoryTranscriptionCapabilityDecision = {
            InMemoryTranscriptionCapabilityRegistry.decision(for: $0)
        }
    ) {
        self.cloudService = cloudService
        self.localService = localService
        self.capabilityResolver = capabilityResolver
    }

    func transcribe(
        _ request: InMemoryTranscriptionRequest
    ) async throws -> InMemoryTranscriptionResult {
        switch capabilityResolver(request.route) {
        case .supported(.batchCloudWAVData):
            return try await cloudService.transcribe(request)
        case .supported(.localPCM16):
            return try await localService.transcribe(request)
        case .unsupported(let reason):
            if case .pcm16(let snapshot) = request.source {
                snapshot.zeroize()
            }
            throw InMemoryTranscriptionError.unsupported(reason)
        }
    }
}

/// The shared source boundary used by normal file transcription and Time-Shift
/// memory transcription. Switching on the source is exhaustive: neither path
/// is permitted to retry through the other.
@MainActor
final class TranscriptionAudioSourceRouter {
    typealias FileTranscriber = @MainActor (
        URL,
        any TranscriptionModel,
        TranscriptionRequestContext
    ) async throws -> String

    private let fileTranscriber: FileTranscriber
    private let inMemoryService: any InMemoryTranscriptionServicing

    init(
        fileTranscriber: @escaping FileTranscriber,
        inMemoryService: any InMemoryTranscriptionServicing
    ) {
        self.fileTranscriber = fileTranscriber
        self.inMemoryService = inMemoryService
    }

    convenience init(
        fileService: any TranscriptionService,
        inMemoryService: any InMemoryTranscriptionServicing
    ) {
        self.init(
            fileTranscriber: { audioURL, model, context in
                try await fileService.transcribe(
                    audioURL: audioURL,
                    model: model,
                    context: context
                )
            },
            inMemoryService: inMemoryService
        )
    }

    func transcribe(
        _ request: TranscriptionAudioSourceRequest
    ) async throws -> InMemoryTranscriptionResult {
        switch request.source {
        case .file(let audioURL):
            let text = try await fileTranscriber(
                audioURL,
                request.model,
                request.context
            )
            return InMemoryTranscriptionResult(
                requestID: request.id,
                text: text
            )

        case .pcm16:
            return try await inMemoryService.transcribe(
                InMemoryTranscriptionRequest(
                    id: request.id,
                    source: request.source,
                    route: InMemoryTranscriptionModelRoute(model: request.model),
                    model: request.model,
                    context: request.context,
                    customVocabulary: request.customVocabulary
                )
            )
        }
    }
}
