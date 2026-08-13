import Foundation

enum HaloVoiceInstructionCapturePhase: Equatable {
    case listening
    case transcribing
}

enum HaloVoiceInstructionCaptureEvent: Equatable {
    case phase(HaloVoiceInstructionCapturePhase)
    case audioLevel(AudioMeter)
    case partialTranscript(String)
}

enum HaloVoiceInstructionCaptureFailure: Equatable {
    case alreadyActive
    case temporaryStorageUnavailable
    case captureUnavailable
    case transcriptionUnavailable
    case transcriptionTimedOut
}

enum HaloVoiceInstructionCaptureOutcome: Equatable {
    case instruction(String)
    case empty
    case cancelled
    case failed(HaloVoiceInstructionCaptureFailure)
}

struct HaloVoiceInstructionCaptureResult: Equatable {
    let requestID: UUID
    let outcome: HaloVoiceInstructionCaptureOutcome
}

@MainActor
protocol HaloVoiceInstructionCaptureServicing: AnyObject {
    var activeRequestID: UUID? { get }

    func capture(
        requestID: UUID,
        configuration: TranscriptionRuntimeConfiguration,
        onEvent: @escaping (HaloVoiceInstructionCaptureEvent) -> Void
    ) async -> HaloVoiceInstructionCaptureResult

    @discardableResult
    func requestStop(requestID: UUID) -> Bool

    @discardableResult
    func cancel(requestID: UUID) -> Bool
}

@MainActor
protocol HaloVoiceInstructionAudioRecording: AnyObject {
    var onAudioChunk: ((Data) -> Void)? { get set }
    var onAudioMeter: ((AudioMeter) -> Void)? { get set }

    func startRecording(toOutputFile url: URL) async throws
    func stopRecording() async
}

@MainActor
protocol HaloVoiceInstructionAudioRecorderCreating: AnyObject {
    func makeAudioRecorder() -> any HaloVoiceInstructionAudioRecording
}

@MainActor
protocol HaloVoiceInstructionTranscriptionSessionCreating: AnyObject {
    func makeTranscriptionSession(
        for configuration: TranscriptionRuntimeConfiguration,
        onPartialTranscript: ((String) -> Void)?
    ) -> any TranscriptionSession
}

@MainActor
protocol HaloVoiceInstructionTemporaryFileManaging: AnyObject {
    func createAudioURL() throws -> URL
    func removeAudio(at url: URL)
}

@MainActor
protocol HaloVoiceInstructionDeadline: AnyObject {
    func cancel()
}

@MainActor
protocol HaloVoiceInstructionDeadlineScheduling: AnyObject {
    func schedule(
        after interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any HaloVoiceInstructionDeadline
}

@MainActor
final class RecorderHaloVoiceInstructionAudioRecorder: HaloVoiceInstructionAudioRecording {
    private let recorder: Recorder
    private var audioMeterTask: Task<Void, Never>?

    var onAudioChunk: ((Data) -> Void)? {
        didSet {
            recorder.onAudioChunk = onAudioChunk
        }
    }

    var onAudioMeter: ((AudioMeter) -> Void)?

    init(recorder: Recorder) {
        self.recorder = recorder
    }

    func startRecording(toOutputFile url: URL) async throws {
        try await recorder.startRecording(toOutputFile: url)
        startAudioMeterUpdates()
    }

    func stopRecording() async {
        audioMeterTask?.cancel()
        audioMeterTask = nil
        await recorder.stopRecording()
    }

    private func startAudioMeterUpdates() {
        audioMeterTask?.cancel()
        audioMeterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.onAudioMeter?(self.recorder.audioMeterSnapshot())
                do {
                    try await Task.sleep(for: .milliseconds(17))
                } catch {
                    return
                }
            }
        }
    }
}

@MainActor
final class DefaultHaloVoiceInstructionAudioRecorderFactory: HaloVoiceInstructionAudioRecorderCreating {
    private let audioCaptureLeaseCoordinator: any AudioCaptureLeaseCoordinating

    init(
        audioCaptureLeaseCoordinator: any AudioCaptureLeaseCoordinating = AudioCaptureLeaseCoordinator.applicationShared
    ) {
        self.audioCaptureLeaseCoordinator = audioCaptureLeaseCoordinator
    }

    func makeAudioRecorder() -> any HaloVoiceInstructionAudioRecording {
        RecorderHaloVoiceInstructionAudioRecorder(
            recorder: Recorder(
                audioCaptureLeaseCoordinator: audioCaptureLeaseCoordinator,
                audioCaptureLeaseOwner: nil
            )
        )
    }
}

extension TranscriptionServiceRegistry: HaloVoiceInstructionTranscriptionSessionCreating {
    func makeTranscriptionSession(
        for configuration: TranscriptionRuntimeConfiguration,
        onPartialTranscript: ((String) -> Void)?
    ) -> any TranscriptionSession {
        createSession(
            for: configuration,
            onPartialTranscript: onPartialTranscript
        )
    }
}

@MainActor
final class DefaultHaloVoiceInstructionTemporaryFileManager: HaloVoiceInstructionTemporaryFileManaging {
    private let fileManager: FileManager
    private let baseDirectory: URL

    init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("VoiceInk", isDirectory: true)
                .appendingPathComponent("HaloVoiceRefinement", isDirectory: true)
        purgeStaleAudioFiles()
    }

    func createAudioURL() throws -> URL {
        try fileManager.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        return baseDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
    }

    func removeAudio(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    /// A process can terminate before the capture service's asynchronous
    /// recorder shutdown reaches its normal file-removal step. On the next
    /// launch, remove only regular WAV files owned by Halo's dedicated
    /// directory. Preserve nested directories and every other file type so
    /// cleanup cannot escape this feature's temporary-storage boundary.
    private func purgeStaleAudioFiles() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return
        }

        for url in contents where url.pathExtension.lowercased() == "wav" {
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true
            else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }
}

@MainActor
final class SystemHaloVoiceInstructionDeadlineScheduler: HaloVoiceInstructionDeadlineScheduling {
    func schedule(
        after interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any HaloVoiceInstructionDeadline {
        SystemHaloVoiceInstructionDeadline(interval: interval, action: action)
    }
}

@MainActor
private final class SystemHaloVoiceInstructionDeadline: HaloVoiceInstructionDeadline {
    private var task: Task<Void, Never>?

    init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        let nanoseconds = UInt64(max(0, interval) * 1_000_000_000)
        task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

/// Owns one short-lived spoken-instruction operation. The recognized instruction,
/// partial text, callbacks, and audio URL exist only for the lifetime of `capture`.
/// Provider failures are deliberately collapsed into fixed categories so backend
/// payloads cannot escape through this boundary.
@MainActor
final class HaloVoiceInstructionCaptureService: HaloVoiceInstructionCaptureServicing {
    nonisolated static let defaultMaximumCaptureDuration: TimeInterval = 20
    nonisolated static let defaultPreparationTimeout: TimeInterval = 10
    nonisolated static let defaultRecordingStartTimeout: TimeInterval = 10
    nonisolated static let defaultTranscriptionTimeout: TimeInterval = 45

    private enum StopReason: Equatable {
        case requested
        case durationLimit
        case cancelled
    }

    private enum OperationPhase: Equatable {
        case preparing
        case starting
        case listening
        case transcribing
    }

    private final class StopGate {
        private(set) var reason: StopReason?
        private var continuation: CheckedContinuation<StopReason, Never>?

        func wait() async -> StopReason {
            if let reason {
                return reason
            }

            return await withCheckedContinuation { continuation in
                if let reason {
                    continuation.resume(returning: reason)
                } else {
                    self.continuation = continuation
                }
            }
        }

        @discardableResult
        func resolve(_ reason: StopReason) -> Bool {
            guard self.reason == nil else { return false }
            self.reason = reason
            continuation?.resume(returning: reason)
            continuation = nil
            return true
        }
    }

    private final class PreparationGate {
        enum Resolution {
            case prepared(((Data) -> Void)?)
            case failed
            case timedOut
            case cancelled
        }

        private(set) var resolution: Resolution?
        private var continuation: CheckedContinuation<Resolution, Never>?

        func wait() async -> Resolution {
            if let resolution {
                return resolution
            }

            return await withCheckedContinuation { continuation in
                if let resolution {
                    continuation.resume(returning: resolution)
                } else {
                    self.continuation = continuation
                }
            }
        }

        @discardableResult
        func resolve(_ resolution: Resolution) -> Bool {
            guard self.resolution == nil else { return false }
            self.resolution = resolution
            continuation?.resume(returning: resolution)
            continuation = nil
            return true
        }
    }

    private final class TranscriptionGate {
        enum Resolution {
            case transcript(String)
            case failed
            case timedOut
            case cancelled
        }

        private(set) var resolution: Resolution?
        private var continuation: CheckedContinuation<Resolution, Never>?

        func wait() async -> Resolution {
            if let resolution {
                return resolution
            }

            return await withCheckedContinuation { continuation in
                if let resolution {
                    continuation.resume(returning: resolution)
                } else {
                    self.continuation = continuation
                }
            }
        }

        @discardableResult
        func resolve(_ resolution: Resolution) -> Bool {
            guard self.resolution == nil else { return false }
            self.resolution = resolution
            continuation?.resume(returning: resolution)
            continuation = nil
            return true
        }
    }

    private final class RecordingStartGate {
        enum Resolution {
            case started
            case failed
            case timedOut
            case cancelled
        }

        private(set) var resolution: Resolution?
        private var continuation: CheckedContinuation<Resolution, Never>?

        func wait() async -> Resolution {
            if let resolution {
                return resolution
            }

            return await withCheckedContinuation { continuation in
                if let resolution {
                    continuation.resume(returning: resolution)
                } else {
                    self.continuation = continuation
                }
            }
        }

        @discardableResult
        func resolve(_ resolution: Resolution) -> Bool {
            guard self.resolution == nil else { return false }
            self.resolution = resolution
            continuation?.resume(returning: resolution)
            continuation = nil
            return true
        }
    }

    private final class Operation {
        let requestID: UUID
        let audioURL: URL
        let recorder: any HaloVoiceInstructionAudioRecording
        let session: any TranscriptionSession
        let gate = StopGate()
        let preparationGate = PreparationGate()
        let recordingStartGate = RecordingStartGate()
        let transcriptionGate = TranscriptionGate()
        let onEvent: (HaloVoiceInstructionCaptureEvent) -> Void
        let audioCaptureLease: AudioCaptureLease

        var phase: OperationPhase = .preparing
        var preparationDeadline: (any HaloVoiceInstructionDeadline)?
        var recordingStartDeadline: (any HaloVoiceInstructionDeadline)?
        var captureDeadline: (any HaloVoiceInstructionDeadline)?
        var transcriptionDeadline: (any HaloVoiceInstructionDeadline)?
        var preparationTask: Task<Void, Never>?
        var recordingStartTask: Task<Void, Never>?
        var transcriptionTask: Task<Void, Never>?
        var didStopRecorder = false
        var didReleaseAudioCaptureLease = false
        var wasCancelled = false
        var didTranscriptionTimeOut = false
        var lastPartialTranscript: String?

        init(
            requestID: UUID,
            audioURL: URL,
            recorder: any HaloVoiceInstructionAudioRecording,
            session: any TranscriptionSession,
            audioCaptureLease: AudioCaptureLease,
            onEvent: @escaping (HaloVoiceInstructionCaptureEvent) -> Void
        ) {
            self.requestID = requestID
            self.audioURL = audioURL
            self.recorder = recorder
            self.session = session
            self.audioCaptureLease = audioCaptureLease
            self.onEvent = onEvent
        }
    }

    private let audioRecorderFactory: any HaloVoiceInstructionAudioRecorderCreating
    private let sessionFactory: any HaloVoiceInstructionTranscriptionSessionCreating
    private let temporaryFiles: any HaloVoiceInstructionTemporaryFileManaging
    private let deadlineScheduler: any HaloVoiceInstructionDeadlineScheduling
    private let audioCaptureLeaseCoordinator: any AudioCaptureLeaseCoordinating
    private let maximumCaptureDuration: TimeInterval
    private let preparationTimeout: TimeInterval
    private let recordingStartTimeout: TimeInterval
    private let transcriptionTimeout: TimeInterval
    private var activeOperation: Operation?
    private var pendingLeaseRequestID: UUID?

    var activeRequestID: UUID? {
        activeOperation?.requestID
    }

    init(
        audioRecorderFactory: any HaloVoiceInstructionAudioRecorderCreating,
        sessionFactory: any HaloVoiceInstructionTranscriptionSessionCreating,
        temporaryFiles: any HaloVoiceInstructionTemporaryFileManaging,
        deadlineScheduler: any HaloVoiceInstructionDeadlineScheduling,
        audioCaptureLeaseCoordinator: any AudioCaptureLeaseCoordinating = AudioCaptureLeaseCoordinator.applicationShared,
        maximumCaptureDuration: TimeInterval = HaloVoiceInstructionCaptureService.defaultMaximumCaptureDuration,
        preparationTimeout: TimeInterval = HaloVoiceInstructionCaptureService.defaultPreparationTimeout,
        recordingStartTimeout: TimeInterval = HaloVoiceInstructionCaptureService.defaultRecordingStartTimeout,
        transcriptionTimeout: TimeInterval = HaloVoiceInstructionCaptureService.defaultTranscriptionTimeout
    ) {
        self.audioRecorderFactory = audioRecorderFactory
        self.sessionFactory = sessionFactory
        self.temporaryFiles = temporaryFiles
        self.deadlineScheduler = deadlineScheduler
        self.audioCaptureLeaseCoordinator = audioCaptureLeaseCoordinator
        self.maximumCaptureDuration = maximumCaptureDuration
        self.preparationTimeout = preparationTimeout
        self.recordingStartTimeout = recordingStartTimeout
        self.transcriptionTimeout = transcriptionTimeout
    }

    convenience init(
        audioRecorderFactory: any HaloVoiceInstructionAudioRecorderCreating,
        sessionFactory: any HaloVoiceInstructionTranscriptionSessionCreating
    ) {
        self.init(
            audioRecorderFactory: audioRecorderFactory,
            sessionFactory: sessionFactory,
            temporaryFiles: DefaultHaloVoiceInstructionTemporaryFileManager(),
            deadlineScheduler: SystemHaloVoiceInstructionDeadlineScheduler()
        )
    }

    convenience init(serviceRegistry: TranscriptionServiceRegistry) {
        let audioCaptureLeaseCoordinator = AudioCaptureLeaseCoordinator.applicationShared
        self.init(
            audioRecorderFactory: DefaultHaloVoiceInstructionAudioRecorderFactory(
                audioCaptureLeaseCoordinator: audioCaptureLeaseCoordinator
            ),
            sessionFactory: serviceRegistry,
            temporaryFiles: DefaultHaloVoiceInstructionTemporaryFileManager(),
            deadlineScheduler: SystemHaloVoiceInstructionDeadlineScheduler(),
            audioCaptureLeaseCoordinator: audioCaptureLeaseCoordinator
        )
    }

    func capture(
        requestID: UUID,
        configuration: TranscriptionRuntimeConfiguration,
        onEvent: @escaping (HaloVoiceInstructionCaptureEvent) -> Void
    ) async -> HaloVoiceInstructionCaptureResult {
        await withTaskCancellationHandler {
            await performCapture(
                requestID: requestID,
                configuration: configuration,
                onEvent: onEvent
            )
        } onCancel: { [weak self] in
            Task { @MainActor in
                _ = self?.cancel(requestID: requestID)
            }
        }
    }

    @discardableResult
    func requestStop(requestID: UUID) -> Bool {
        guard let operation = matchingOperation(requestID),
            operation.phase == .listening
        else {
            return false
        }
        return operation.gate.resolve(.requested)
    }

    @discardableResult
    func cancel(requestID: UUID) -> Bool {
        if pendingLeaseRequestID == requestID {
            pendingLeaseRequestID = nil
            return true
        }
        guard let operation = matchingOperation(requestID) else {
            return false
        }

        operation.wasCancelled = true
        operation.preparationDeadline?.cancel()
        operation.recordingStartDeadline?.cancel()
        operation.captureDeadline?.cancel()
        operation.transcriptionDeadline?.cancel()
        operation.preparationTask?.cancel()
        operation.recordingStartTask?.cancel()
        operation.transcriptionTask?.cancel()
        operation.session.cancel()
        _ = operation.gate.resolve(.cancelled)
        _ = operation.preparationGate.resolve(.cancelled)
        _ = operation.recordingStartGate.resolve(.cancelled)
        _ = operation.transcriptionGate.resolve(.cancelled)
        return true
    }

    private func performCapture(
        requestID: UUID,
        configuration: TranscriptionRuntimeConfiguration,
        onEvent: @escaping (HaloVoiceInstructionCaptureEvent) -> Void
    ) async -> HaloVoiceInstructionCaptureResult {
        guard activeOperation == nil, pendingLeaseRequestID == nil else {
            return result(requestID, .failed(.alreadyActive))
        }

        pendingLeaseRequestID = requestID
        let acquisition = await audioCaptureLeaseCoordinator.acquire(for: .haloVoice)
        guard pendingLeaseRequestID == requestID else {
            if let lease = acquisition.lease {
                _ = await audioCaptureLeaseCoordinator.release(lease)
            }
            return result(requestID, .cancelled)
        }
        pendingLeaseRequestID = nil

        guard let audioCaptureLease = acquisition.lease else {
            return result(requestID, .failed(.captureUnavailable))
        }
        guard !Task.isCancelled else {
            _ = await audioCaptureLeaseCoordinator.release(audioCaptureLease)
            return result(requestID, .cancelled)
        }

        let audioURL: URL
        do {
            audioURL = try temporaryFiles.createAudioURL()
        } catch {
            _ = await audioCaptureLeaseCoordinator.release(audioCaptureLease)
            return result(requestID, .failed(.temporaryStorageUnavailable))
        }

        let recorder = audioRecorderFactory.makeAudioRecorder()
        let partialTranscriptHandler: ((String) -> Void)?
        if configuration.isRealtimeEnabled {
            partialTranscriptHandler = { [weak self] partialTranscript in
                Task { @MainActor in
                    self?.publishPartialTranscript(
                        partialTranscript,
                        requestID: requestID
                    )
                }
            }
        } else {
            partialTranscriptHandler = nil
        }

        let session = sessionFactory.makeTranscriptionSession(
            for: configuration,
            onPartialTranscript: partialTranscriptHandler
        )
        let operation = Operation(
            requestID: requestID,
            audioURL: audioURL,
            recorder: recorder,
            session: session,
            audioCaptureLease: audioCaptureLease,
            onEvent: onEvent
        )
        activeOperation = operation

        recorder.onAudioMeter = { [weak self] meter in
            guard let self,
                let activeOperation = self.activeOperation,
                activeOperation === operation,
                activeOperation.phase == .listening
            else {
                return
            }
            activeOperation.onEvent(.audioLevel(meter))
        }

        let preparationTask = Task { @MainActor [weak operation] in
            do {
                let audioChunkHandler = try await session.prepare(
                    configuration: configuration
                )
                guard let operation,
                    operation.preparationGate.resolve(.prepared(audioChunkHandler))
                else {
                    return
                }
                operation.preparationDeadline?.cancel()
                operation.preparationDeadline = nil
            } catch {
                guard let operation else { return }
                let didResolve: Bool
                if operation.wasCancelled || Task.isCancelled {
                    didResolve = operation.preparationGate.resolve(.cancelled)
                } else {
                    didResolve = operation.preparationGate.resolve(.failed)
                }
                if didResolve {
                    operation.preparationDeadline?.cancel()
                    operation.preparationDeadline = nil
                }
            }
        }
        operation.preparationTask = preparationTask
        operation.preparationDeadline = deadlineScheduler.schedule(
            after: preparationTimeout
        ) { [weak self, weak operation] in
            guard let self, let operation,
                self.activeOperation === operation,
                operation.phase == .preparing,
                operation.preparationGate.resolve(.timedOut)
            else {
                return
            }
            operation.preparationTask?.cancel()
            operation.session.cancel()
        }

        let preparationResolution = await operation.preparationGate.wait()
        let audioChunkHandler: ((Data) -> Void)?
        switch preparationResolution {
        case .prepared(let handler):
            audioChunkHandler = handler
        case .failed:
            return await finish(operation, outcome: .failed(.transcriptionUnavailable))
        case .timedOut:
            return await finish(operation, outcome: .failed(.transcriptionTimedOut))
        case .cancelled:
            return await finish(operation, outcome: .cancelled)
        }

        guard !operation.wasCancelled, !Task.isCancelled else {
            return await finish(operation, outcome: .cancelled)
        }

        recorder.onAudioChunk = audioChunkHandler
        operation.phase = .starting
        let recordingStartTask = Task { @MainActor [weak operation] in
            guard let operation,
                !operation.wasCancelled,
                !Task.isCancelled,
                operation.recordingStartGate.resolution == nil
            else {
                return
            }

            do {
                try await recorder.startRecording(toOutputFile: audioURL)
                guard operation.recordingStartGate.resolve(.started) else {
                    return
                }
                operation.recordingStartDeadline?.cancel()
                operation.recordingStartDeadline = nil
            } catch {
                let didResolve: Bool
                if operation.wasCancelled || Task.isCancelled {
                    didResolve = operation.recordingStartGate.resolve(.cancelled)
                } else {
                    didResolve = operation.recordingStartGate.resolve(.failed)
                }
                if didResolve {
                    operation.recordingStartDeadline?.cancel()
                    operation.recordingStartDeadline = nil
                }
            }
        }
        operation.recordingStartTask = recordingStartTask
        operation.recordingStartDeadline = deadlineScheduler.schedule(
            after: recordingStartTimeout
        ) { [weak self, weak operation] in
            guard let self, let operation,
                self.activeOperation === operation,
                operation.phase == .starting,
                operation.recordingStartGate.resolve(.timedOut)
            else {
                return
            }
            operation.recordingStartTask?.cancel()
            operation.session.cancel()
        }

        let recordingStartResolution = await operation.recordingStartGate.wait()
        switch recordingStartResolution {
        case .started:
            break
        case .failed:
            return await finish(
                operation,
                outcome: .failed(.captureUnavailable)
            )
        case .timedOut:
            return await finish(
                operation,
                outcome: .failed(.captureUnavailable),
                waitForRecorderStop: false
            )
        case .cancelled:
            return await finish(
                operation,
                outcome: .cancelled,
                waitForRecorderStop: false
            )
        }

        guard !operation.wasCancelled, !Task.isCancelled else {
            return await finish(operation, outcome: .cancelled)
        }

        operation.phase = .listening
        onEvent(.phase(.listening))
        operation.captureDeadline = deadlineScheduler.schedule(
            after: maximumCaptureDuration
        ) { [weak self, weak operation] in
            guard let self, let operation,
                self.activeOperation === operation,
                operation.phase == .listening
            else {
                return
            }
            _ = operation.gate.resolve(.durationLimit)
        }

        let stopReason = await operation.gate.wait()
        operation.captureDeadline?.cancel()
        operation.captureDeadline = nil
        await stopRecorder(for: operation)

        guard stopReason != .cancelled,
            !operation.wasCancelled,
            !Task.isCancelled
        else {
            return await finish(operation, outcome: .cancelled)
        }

        operation.phase = .transcribing
        onEvent(.phase(.transcribing))

        let transcriptionTask = Task { @MainActor [weak operation] in
            do {
                let transcript = try await session.transcribe(audioURL: audioURL)
                guard let operation,
                    operation.transcriptionGate.resolve(.transcript(transcript))
                else {
                    return
                }
                operation.transcriptionDeadline?.cancel()
                operation.transcriptionDeadline = nil
            } catch {
                guard let operation else { return }
                let didResolve: Bool
                if operation.wasCancelled || Task.isCancelled {
                    didResolve = operation.transcriptionGate.resolve(.cancelled)
                } else {
                    didResolve = operation.transcriptionGate.resolve(.failed)
                }
                if didResolve {
                    operation.transcriptionDeadline?.cancel()
                    operation.transcriptionDeadline = nil
                }
            }
        }
        operation.transcriptionTask = transcriptionTask
        operation.transcriptionDeadline = deadlineScheduler.schedule(
            after: transcriptionTimeout
        ) { [weak self, weak operation] in
            guard let self, let operation,
                self.activeOperation === operation,
                operation.phase == .transcribing
            else {
                return
            }
            guard operation.transcriptionGate.resolve(.timedOut) else {
                return
            }
            operation.didTranscriptionTimeOut = true
            operation.transcriptionTask?.cancel()
            operation.session.cancel()
        }

        let transcriptionResolution = await operation.transcriptionGate.wait()
        let transcript: String
        switch transcriptionResolution {
        case .transcript(let text):
            transcript = text
        case .failed:
            return await finish(operation, outcome: .failed(.transcriptionUnavailable))
        case .timedOut:
            return await finish(operation, outcome: .failed(.transcriptionTimedOut))
        case .cancelled:
            return await finish(operation, outcome: .cancelled)
        }

        guard !operation.wasCancelled, !Task.isCancelled else {
            return await finish(operation, outcome: .cancelled)
        }
        guard !operation.didTranscriptionTimeOut else {
            return await finish(operation, outcome: .failed(.transcriptionTimedOut))
        }

        let instruction = Self.sanitizeTranscript(transcript)
        let outcome: HaloVoiceInstructionCaptureOutcome = instruction.isEmpty
            ? .empty
            : .instruction(instruction)
        return await finish(operation, outcome: outcome)
    }

    private func publishPartialTranscript(
        _ partialTranscript: String,
        requestID: UUID
    ) {
        guard let operation = matchingOperation(requestID),
            operation.phase == .listening
        else {
            return
        }

        let sanitized = Self.sanitizeTranscript(partialTranscript)
        guard !sanitized.isEmpty,
            sanitized != operation.lastPartialTranscript
        else {
            return
        }

        operation.lastPartialTranscript = sanitized
        operation.onEvent(.partialTranscript(sanitized))
    }

    private func finish(
        _ operation: Operation,
        outcome: HaloVoiceInstructionCaptureOutcome,
        waitForRecorderStop: Bool = true
    ) async -> HaloVoiceInstructionCaptureResult {
        await cleanUp(operation, waitForRecorderStop: waitForRecorderStop)
        return result(operation.requestID, outcome)
    }

    private func cleanUp(
        _ operation: Operation,
        waitForRecorderStop: Bool
    ) async {
        operation.preparationDeadline?.cancel()
        operation.preparationDeadline = nil
        operation.recordingStartDeadline?.cancel()
        operation.recordingStartDeadline = nil
        operation.captureDeadline?.cancel()
        operation.captureDeadline = nil
        operation.transcriptionDeadline?.cancel()
        operation.transcriptionDeadline = nil
        operation.preparationTask?.cancel()
        operation.preparationTask = nil
        operation.recordingStartTask?.cancel()
        operation.recordingStartTask = nil
        operation.transcriptionTask?.cancel()
        operation.transcriptionTask = nil
        operation.session.cancel()
        operation.recorder.onAudioChunk = nil
        operation.recorder.onAudioMeter = nil
        if waitForRecorderStop {
            await stopRecorder(for: operation)
        } else {
            stopRecorderWithoutWaiting(for: operation)
        }
        temporaryFiles.removeAudio(at: operation.audioURL)

        if waitForRecorderStop {
            await releaseAudioCaptureLease(for: operation)
        }

        if activeOperation === operation {
            activeOperation = nil
        }
    }

    private func stopRecorder(for operation: Operation) async {
        guard !operation.didStopRecorder else { return }
        operation.didStopRecorder = true
        await operation.recorder.stopRecording()
    }

    /// Recorder startup ultimately crosses a Core Audio callback that may not
    /// cooperate with Swift task cancellation. Once the one-shot start gate has
    /// timed out or been cancelled, return the review promptly while leaving a
    /// single stop request queued behind any in-flight hardware start.
    private func stopRecorderWithoutWaiting(for operation: Operation) {
        guard !operation.didStopRecorder else { return }
        operation.didStopRecorder = true
        let recorder = operation.recorder
        let coordinator = audioCaptureLeaseCoordinator
        let lease = operation.audioCaptureLease
        operation.didReleaseAudioCaptureLease = true
        Task { @MainActor in
            await recorder.stopRecording()
            _ = await coordinator.release(lease)
        }
    }

    private func releaseAudioCaptureLease(for operation: Operation) async {
        guard !operation.didReleaseAudioCaptureLease else { return }
        operation.didReleaseAudioCaptureLease = true
        _ = await audioCaptureLeaseCoordinator.release(operation.audioCaptureLease)
    }

    private func matchingOperation(_ requestID: UUID) -> Operation? {
        guard let activeOperation,
            activeOperation.requestID == requestID
        else {
            return nil
        }
        return activeOperation
    }

    private func result(
        _ requestID: UUID,
        _ outcome: HaloVoiceInstructionCaptureOutcome
    ) -> HaloVoiceInstructionCaptureResult {
        HaloVoiceInstructionCaptureResult(
            requestID: requestID,
            outcome: outcome
        )
    }

    private static func sanitizeTranscript(_ transcript: String) -> String {
        let withoutControlCharacters = String(transcript.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                || scalar.value == 10
                || scalar.value == 9
        })
        return TranscriptionOutputFilter.filter(withoutControlCharacters)
    }
}
