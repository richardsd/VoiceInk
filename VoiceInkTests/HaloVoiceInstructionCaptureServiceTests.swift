import Foundation
import Testing
@testable import VoiceInk

@MainActor
private final class FakeHaloVoiceAudioRecorder: HaloVoiceInstructionAudioRecording {
    var onAudioChunk: ((Data) -> Void)?
    var onAudioMeter: ((AudioMeter) -> Void)?
    var startError: Error?
    var ignoresStartCancellation = false
    private(set) var startedURLs: [URL] = []
    private(set) var stopCount = 0
    private var ignoredStartContinuation: CheckedContinuation<Void, Never>?
    var audioCaptureLeaseCoordinator: AudioCaptureLeaseCoordinator?
    private(set) var activeLeaseOwnerAtStop: AudioCaptureLeaseOwner?

    func startRecording(toOutputFile url: URL) async throws {
        startedURLs.append(url)
        if ignoresStartCancellation {
            await withCheckedContinuation { continuation in
                ignoredStartContinuation = continuation
            }
        }
        if let startError {
            throw startError
        }
    }

    func stopRecording() async {
        if let audioCaptureLeaseCoordinator {
            activeLeaseOwnerAtStop = await audioCaptureLeaseCoordinator.activeOwner
        }
        stopCount += 1
    }

    func completeIgnoredStart() {
        ignoredStartContinuation?.resume()
        ignoredStartContinuation = nil
    }
}

@MainActor
private final class FakeHaloVoiceAudioRecorderFactory: HaloVoiceInstructionAudioRecorderCreating {
    let recorder: FakeHaloVoiceAudioRecorder
    private(set) var makeCount = 0

    init(recorder: FakeHaloVoiceAudioRecorder) {
        self.recorder = recorder
    }

    func makeAudioRecorder() -> any HaloVoiceInstructionAudioRecording {
        makeCount += 1
        return recorder
    }
}

@MainActor
private final class FakeHaloVoiceTranscriptionSession: TranscriptionSession {
    enum PreparationBehavior {
        case success
        case failure(Error)
        case waitForCancellation
        case ignoreCancellation
    }

    enum Behavior {
        case success(String)
        case failure(Error)
        case waitForCancellation
        case ignoreCancellation
    }

    var preparationBehavior: PreparationBehavior = .success
    var behavior: Behavior = .success("Make it clearer")
    private(set) var preparedConfigurations: [TranscriptionRuntimeConfiguration] = []
    private(set) var transcribedURLs: [URL] = []
    private(set) var receivedAudioChunks: [Data] = []
    private(set) var cancelCount = 0
    private(set) var didBeginPreparation = false
    private(set) var didBeginTranscription = false
    private var ignoredPreparationContinuation: CheckedContinuation<((Data) -> Void)?, Never>?
    private var ignoredCancellationContinuation: CheckedContinuation<String, Never>?

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        didBeginPreparation = true
        preparedConfigurations.append(configuration)
        switch preparationBehavior {
        case .success:
            return audioChunkHandler()
        case .failure(let error):
            throw error
        case .waitForCancellation:
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return audioChunkHandler()
        case .ignoreCancellation:
            return await withCheckedContinuation { continuation in
                ignoredPreparationContinuation = continuation
            }
        }
    }

    func transcribe(audioURL: URL) async throws -> String {
        didBeginTranscription = true
        transcribedURLs.append(audioURL)
        switch behavior {
        case .success(let text):
            return text
        case .failure(let error):
            throw error
        case .waitForCancellation:
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return "Late instruction"
        case .ignoreCancellation:
            return await withCheckedContinuation { continuation in
                ignoredCancellationContinuation = continuation
            }
        }
    }

    func cancel() {
        cancelCount += 1
    }

    func completeIgnoredCancellation(with text: String) {
        ignoredCancellationContinuation?.resume(returning: text)
        ignoredCancellationContinuation = nil
    }

    func completeIgnoredPreparation() {
        ignoredPreparationContinuation?.resume(returning: audioChunkHandler())
        ignoredPreparationContinuation = nil
    }

    private func audioChunkHandler() -> (Data) -> Void {
        { [weak self] data in
            self?.receivedAudioChunks.append(data)
        }
    }
}

@MainActor
private final class FakeHaloVoiceSessionFactory: HaloVoiceInstructionTranscriptionSessionCreating {
    let session: FakeHaloVoiceTranscriptionSession
    private(set) var configurations: [TranscriptionRuntimeConfiguration] = []
    private(set) var partialTranscriptHandler: ((String) -> Void)?

    init(session: FakeHaloVoiceTranscriptionSession) {
        self.session = session
    }

    func makeTranscriptionSession(
        for configuration: TranscriptionRuntimeConfiguration,
        onPartialTranscript: ((String) -> Void)?
    ) -> any TranscriptionSession {
        configurations.append(configuration)
        partialTranscriptHandler = onPartialTranscript
        return session
    }
}

@MainActor
private final class FakeHaloVoiceTemporaryFiles: HaloVoiceInstructionTemporaryFileManaging {
    enum Failure: Error {
        case unavailable
    }

    let audioURL = URL(fileURLWithPath: "/tmp/VoiceInk-HaloVoice-Test.wav")
    var shouldFailCreation = false
    private(set) var createCount = 0
    private(set) var removedURLs: [URL] = []

    func createAudioURL() throws -> URL {
        createCount += 1
        if shouldFailCreation {
            throw Failure.unavailable
        }
        return audioURL
    }

    func removeAudio(at url: URL) {
        removedURLs.append(url)
    }
}

@MainActor
private final class ManualHaloVoiceDeadline: HaloVoiceInstructionDeadline {
    let interval: TimeInterval
    private let action: @MainActor () -> Void
    private(set) var isCancelled = false
    private(set) var didFire = false

    init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.action = action
    }

    func cancel() {
        isCancelled = true
    }

    func fire() {
        guard !isCancelled, !didFire else { return }
        didFire = true
        action()
    }
}

@MainActor
private final class ManualHaloVoiceDeadlineScheduler: HaloVoiceInstructionDeadlineScheduling {
    private(set) var deadlines: [ManualHaloVoiceDeadline] = []

    func schedule(
        after interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any HaloVoiceInstructionDeadline {
        let deadline = ManualHaloVoiceDeadline(interval: interval, action: action)
        deadlines.append(deadline)
        return deadline
    }

    func activeDeadline(after interval: TimeInterval) -> ManualHaloVoiceDeadline? {
        deadlines.first { deadline in
            deadline.interval == interval
                && !deadline.isCancelled
                && !deadline.didFire
        }
    }
}

private enum FakeHaloVoiceError: Error {
    case failed
}

/// Keeps the capture-service unit tests independent from actor scheduling in
/// the launched app test host. Dedicated tests below still exercise the real
/// application-wide actor, including contention, ordering, and preemption.
private final class ImmediateHaloVoiceLeaseCoordinator: AudioCaptureLeaseCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private var activeLease: AudioCaptureLease?

    func acquire(for owner: AudioCaptureLeaseOwner) async -> AudioCaptureLeaseAcquisition {
        acquireSynchronously(for: owner)
    }

    func release(_ lease: AudioCaptureLease) async -> Bool {
        releaseSynchronously(lease)
    }

    private func acquireSynchronously(for owner: AudioCaptureLeaseOwner) -> AudioCaptureLeaseAcquisition {
        lock.lock()
        defer { lock.unlock() }
        guard activeLease == nil else {
            return .denied(.occupied(by: activeLease!.owner))
        }
        let lease = AudioCaptureLease(owner: owner)
        activeLease = lease
        return .acquired(lease)
    }

    private func releaseSynchronously(_ lease: AudioCaptureLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeLease == lease else { return false }
        activeLease = nil
        return true
    }
}

private actor SuspendedHaloVoiceLeaseCoordinator: AudioCaptureLeaseCoordinating {
    private var acquisitionContinuation: CheckedContinuation<AudioCaptureLeaseAcquisition, Never>?
    private var acquisitionStartedContinuation: CheckedContinuation<Void, Never>?
    private(set) var releasedLeases: [AudioCaptureLease] = []

    func acquire(for owner: AudioCaptureLeaseOwner) async -> AudioCaptureLeaseAcquisition {
        acquisitionStartedContinuation?.resume()
        acquisitionStartedContinuation = nil
        return await withCheckedContinuation { continuation in
            acquisitionContinuation = continuation
        }
    }

    func release(_ lease: AudioCaptureLease) -> Bool {
        releasedLeases.append(lease)
        return true
    }

    func waitUntilAcquireStarts() async {
        if acquisitionContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            acquisitionStartedContinuation = continuation
        }
    }

    func resumeAcquisition(with lease: AudioCaptureLease) {
        acquisitionContinuation?.resume(returning: .acquired(lease))
        acquisitionContinuation = nil
    }
}

@MainActor
struct HaloVoiceInstructionCaptureServiceTests {
    @Test func realtimeCaptureUsesFrozenConfigurationPublishesEphemeralSignalsAndCleansUp() async throws {
        let harness = makeHarness(realtime: true)
        harness.session.behavior = .success("  Make\u{0} this   clearer  ")
        var events: [HaloVoiceInstructionCaptureEvent] = []
        let requestID = UUID()

        let capture = Task { @MainActor in
            await harness.service.capture(
                requestID: requestID,
                configuration: harness.configuration,
                onEvent: { events.append($0) }
            )
        }
        await waitUntil { events.contains(.phase(.listening)) }

        harness.recorder.onAudioMeter?(AudioMeter(averagePower: 0.4, peakPower: 0.7))
        harness.recorder.onAudioChunk?(Data([1, 2, 3]))
        harness.sessionFactory.partialTranscriptHandler?("[noise] Make this clearer")
        await Task.yield()
        #expect(harness.service.requestStop(requestID: requestID))

        let result = await capture.value

        #expect(result == HaloVoiceInstructionCaptureResult(
            requestID: requestID,
            outcome: .instruction("Make this clearer")
        ))
        #expect(harness.sessionFactory.configurations.count == 1)
        let usedConfiguration = try #require(harness.sessionFactory.configurations.first)
        #expect(usedConfiguration.model.id == harness.configuration.model.id)
        #expect(usedConfiguration.language == "pt")
        #expect(usedConfiguration.isRealtimeEnabled)
        #expect(harness.session.receivedAudioChunks == [Data([1, 2, 3])])
        #expect(events.contains(.phase(.listening)))
        #expect(events.contains(.audioLevel(AudioMeter(averagePower: 0.4, peakPower: 0.7))))
        #expect(events.contains(.partialTranscript("Make this clearer")))
        #expect(events.contains(.phase(.transcribing)))
        assertCleanedUp(harness)
    }

    @Test func batchCaptureNeverPublishesFabricatedPartialText() async {
        let harness = makeHarness(realtime: false)
        var events: [HaloVoiceInstructionCaptureEvent] = []
        let requestID = UUID()

        let capture = Task { @MainActor in
            await harness.service.capture(
                requestID: requestID,
                configuration: harness.configuration,
                onEvent: { events.append($0) }
            )
        }
        await waitUntil { events.contains(.phase(.listening)) }

        #expect(harness.sessionFactory.partialTranscriptHandler == nil)
        #expect(harness.service.requestStop(requestID: requestID))
        let result = await capture.value

        #expect(result.outcome == .instruction("Make it clearer"))
        #expect(!events.contains { event in
            if case .partialTranscript = event { return true }
            return false
        })
        assertCleanedUp(harness)
    }

    @Test func emptyAndSilentTranscriptsCreateNoInstructionAndStillCleanUp() async {
        let harness = makeHarness()
        harness.session.behavior = .success(" \n\t ")
        let requestID = UUID()

        let capture = Task { @MainActor in
            await harness.service.capture(
                requestID: requestID,
                configuration: harness.configuration,
                onEvent: { _ in }
            )
        }
        await waitUntil { harness.deadlines.activeDeadline(after: 20) != nil }
        #expect(harness.service.requestStop(requestID: requestID))

        #expect((await capture.value).outcome == .empty)
        assertCleanedUp(harness)
    }

    @Test func durationLimitStopsAtTwentySecondsAndTranscribesCapturedAudio() async throws {
        let harness = makeHarness()
        let requestID = UUID()

        let capture = Task { @MainActor in
            await harness.service.capture(
                requestID: requestID,
                configuration: harness.configuration,
                onEvent: { _ in }
            )
        }
        await waitUntil { harness.deadlines.activeDeadline(after: 20) != nil }
        let durationDeadline = try #require(
            harness.deadlines.activeDeadline(after: 20)
        )

        durationDeadline.fire()
        let result = await capture.value

        #expect(result.outcome == .instruction("Make it clearer"))
        #expect(harness.session.transcribedURLs == [harness.files.audioURL])
        assertCleanedUp(harness)
    }

    @Test func cancellationStopsCaptureCancelsSessionAndDeletesAudio() async {
        let harness = makeHarness()
        let requestID = UUID()

        let capture = Task { @MainActor in
            await harness.service.capture(
                requestID: requestID,
                configuration: harness.configuration,
                onEvent: { _ in }
            )
        }
        await waitUntil { harness.recorder.startedURLs.count == 1 }

        #expect(harness.service.cancel(requestID: requestID))
        #expect((await capture.value).outcome == .cancelled)
        #expect(harness.session.transcribedURLs.isEmpty)
        assertCleanedUp(harness)
    }

    @Test func captureAndTranscriptionFailuresReturnOnlySanitizedCategories() async {
        let preparationHarness = makeHarness()
        preparationHarness.session.preparationBehavior = .failure(FakeHaloVoiceError.failed)
        let preparationResult = await preparationHarness.service.capture(
            requestID: UUID(),
            configuration: preparationHarness.configuration,
            onEvent: { _ in }
        )
        #expect(preparationResult.outcome == .failed(.transcriptionUnavailable))
        assertCleanedUp(preparationHarness)

        let captureHarness = makeHarness()
        captureHarness.recorder.startError = FakeHaloVoiceError.failed
        let captureResult = await captureHarness.service.capture(
            requestID: UUID(),
            configuration: captureHarness.configuration,
            onEvent: { _ in }
        )
        #expect(captureResult.outcome == .failed(.captureUnavailable))
        assertCleanedUp(captureHarness)

        let transcriptionHarness = makeHarness()
        transcriptionHarness.session.behavior = .failure(FakeHaloVoiceError.failed)
        let requestID = UUID()
        let transcription = Task { @MainActor in
            await transcriptionHarness.service.capture(
                requestID: requestID,
                configuration: transcriptionHarness.configuration,
                onEvent: { _ in }
            )
        }
        await waitUntil {
            transcriptionHarness.deadlines.activeDeadline(after: 20) != nil
        }
        #expect(transcriptionHarness.service.requestStop(requestID: requestID))
        #expect((await transcription.value).outcome == .failed(.transcriptionUnavailable))
        assertCleanedUp(transcriptionHarness)
    }

    @Test func recordingStartTimeoutReturnsCleansUpAndRejectsLateCompletion() async throws {
        let harness = makeHarness()
        harness.recorder.ignoresStartCancellation = true
        let requestID = UUID()
        var events: [HaloVoiceInstructionCaptureEvent] = []

        let capture = Task { @MainActor in
            await harness.service.capture(
                requestID: requestID,
                configuration: harness.configuration,
                onEvent: { events.append($0) }
            )
        }
        await waitUntil {
            harness.recorder.startedURLs.count == 1
                && harness.deadlines.activeDeadline(after: 10) != nil
        }
        let startDeadline = try #require(
            harness.deadlines.activeDeadline(after: 10)
        )

        startDeadline.fire()
        let result = await capture.value
        await waitUntil { harness.recorder.stopCount == 1 }

        #expect(result.outcome == .failed(.captureUnavailable))
        #expect(events.isEmpty)
        assertCleanedUp(harness)

        harness.recorder.completeIgnoredStart()
        await Task.yield()
        #expect(harness.service.activeRequestID == nil)
        #expect(harness.recorder.stopCount == 1)
        #expect(events.isEmpty)
    }

    @Test func cancellationDuringHungRecordingStartReturnsAndCleansUp() async {
        let harness = makeHarness()
        harness.recorder.ignoresStartCancellation = true
        let requestID = UUID()
        var events: [HaloVoiceInstructionCaptureEvent] = []

        let capture = Task { @MainActor in
            await harness.service.capture(
                requestID: requestID,
                configuration: harness.configuration,
                onEvent: { events.append($0) }
            )
        }
        await waitUntil { harness.recorder.startedURLs.count == 1 }

        #expect(harness.service.cancel(requestID: requestID))
        #expect((await capture.value).outcome == .cancelled)
        await waitUntil { harness.recorder.stopCount == 1 }
        #expect(events.isEmpty)
        assertCleanedUp(harness)

        harness.recorder.completeIgnoredStart()
        await Task.yield()
        #expect(harness.service.activeRequestID == nil)
        #expect(harness.recorder.stopCount == 1)
        #expect(events.isEmpty)
    }

    @Test func transcriptionTimeoutCancelsTheSessionAndDeletesAudio() async throws {
        let harness = makeHarness()
        harness.session.behavior = .waitForCancellation
        let requestID = UUID()

        let capture = Task { @MainActor in
            await harness.service.capture(
                requestID: requestID,
                configuration: harness.configuration,
                onEvent: { _ in }
            )
        }
        await waitUntil { harness.deadlines.activeDeadline(after: 20) != nil }
        #expect(harness.service.requestStop(requestID: requestID))
        await waitUntil {
            harness.session.didBeginTranscription
                && harness.deadlines.activeDeadline(after: 45) != nil
        }
        let transcriptionDeadline = try #require(
            harness.deadlines.activeDeadline(after: 45)
        )

        transcriptionDeadline.fire()
        let result = await capture.value

        #expect(result.outcome == .failed(.transcriptionTimedOut))
        #expect(harness.session.cancelCount >= 1)
        assertCleanedUp(harness)
    }

    @Test func timeoutReturnsAndRejectsLateResultWhenProviderIgnoresCancellation() async throws {
        let harness = makeHarness()
        harness.session.behavior = .ignoreCancellation
        let requestID = UUID()
        var events: [HaloVoiceInstructionCaptureEvent] = []

        let capture = Task { @MainActor in
            await harness.service.capture(
                requestID: requestID,
                configuration: harness.configuration,
                onEvent: { events.append($0) }
            )
        }
        await waitUntil { events.contains(.phase(.listening)) }
        #expect(harness.service.requestStop(requestID: requestID))
        await waitUntil {
            harness.session.didBeginTranscription
                && harness.deadlines.activeDeadline(after: 45) != nil
        }
        let transcriptionDeadline = try #require(
            harness.deadlines.activeDeadline(after: 45)
        )

        transcriptionDeadline.fire()
        let result = await capture.value

        #expect(result.outcome == .failed(.transcriptionTimedOut))
        assertCleanedUp(harness)
        let eventCountAfterTimeout = events.count

        // This simulates a backend that completes despite both session and Task
        // cancellation. Its late value must not revive the finished operation.
        harness.session.completeIgnoredCancellation(with: "Use this stale command")
        await Task.yield()
        #expect(harness.service.activeRequestID == nil)
        #expect(events.count == eventCountAfterTimeout)
    }

    @Test func overlappingCaptureIsRejectedWithoutDisruptingTheActiveOperation() async {
        let harness = makeHarness()
        let firstID = UUID()
        let firstCapture = Task { @MainActor in
            await harness.service.capture(
                requestID: firstID,
                configuration: harness.configuration,
                onEvent: { _ in }
            )
        }
        await waitUntil { harness.recorder.startedURLs.count == 1 }

        let secondID = UUID()
        let secondResult = await harness.service.capture(
            requestID: secondID,
            configuration: harness.configuration,
            onEvent: { _ in }
        )

        #expect(secondResult == HaloVoiceInstructionCaptureResult(
            requestID: secondID,
            outcome: .failed(.alreadyActive)
        ))
        #expect(harness.service.activeRequestID == firstID)
        #expect(harness.files.createCount == 1)

        #expect(harness.service.cancel(requestID: firstID))
        #expect((await firstCapture.value).outcome == .cancelled)
        assertCleanedUp(harness)
    }

    @Test func preparationTimeoutCancelsCooperativeProviderAndCleansUp() async throws {
        let harness = makeHarness()
        harness.session.preparationBehavior = .waitForCancellation
        let requestID = UUID()

        let capture = Task { @MainActor in
            await harness.service.capture(
                requestID: requestID,
                configuration: harness.configuration,
                onEvent: { _ in }
            )
        }
        await waitUntil {
            harness.session.didBeginPreparation
                && harness.deadlines.activeDeadline(after: 10) != nil
        }
        let preparationDeadline = try #require(
            harness.deadlines.activeDeadline(after: 10)
        )

        preparationDeadline.fire()
        let result = await capture.value

        #expect(result.outcome == .failed(.transcriptionTimedOut))
        #expect(harness.session.cancelCount >= 1)
        #expect(harness.recorder.startedURLs.isEmpty)
        assertCleanedUp(harness)
    }

    @Test func preparationTimeoutReturnsAndRejectsLateNonCooperativeCompletion() async throws {
        let harness = makeHarness()
        harness.session.preparationBehavior = .ignoreCancellation
        let requestID = UUID()
        var events: [HaloVoiceInstructionCaptureEvent] = []

        let capture = Task { @MainActor in
            await harness.service.capture(
                requestID: requestID,
                configuration: harness.configuration,
                onEvent: { events.append($0) }
            )
        }
        await waitUntil {
            harness.session.didBeginPreparation
                && harness.deadlines.activeDeadline(after: 10) != nil
        }
        let preparationDeadline = try #require(
            harness.deadlines.activeDeadline(after: 10)
        )

        preparationDeadline.fire()
        let result = await capture.value

        #expect(result.outcome == .failed(.transcriptionTimedOut))
        #expect(harness.recorder.startedURLs.isEmpty)
        #expect(events.isEmpty)
        assertCleanedUp(harness)

        harness.session.completeIgnoredPreparation()
        await Task.yield()

        #expect(harness.service.activeRequestID == nil)
        #expect(harness.recorder.startedURLs.isEmpty)
        #expect(events.isEmpty)
        #expect(harness.files.removedURLs == [harness.files.audioURL])
    }

    @Test func cancellationDuringHungPreparationReturnsAndRejectsLateCompletion() async {
        let harness = makeHarness()
        harness.session.preparationBehavior = .ignoreCancellation
        let requestID = UUID()
        var events: [HaloVoiceInstructionCaptureEvent] = []

        let capture = Task { @MainActor in
            await harness.service.capture(
                requestID: requestID,
                configuration: harness.configuration,
                onEvent: { events.append($0) }
            )
        }
        await waitUntil { harness.session.didBeginPreparation }

        #expect(harness.service.cancel(requestID: requestID))
        #expect((await capture.value).outcome == .cancelled)
        #expect(harness.recorder.startedURLs.isEmpty)
        #expect(events.isEmpty)
        assertCleanedUp(harness)

        harness.session.completeIgnoredPreparation()
        await Task.yield()

        #expect(harness.service.activeRequestID == nil)
        #expect(harness.recorder.startedURLs.isEmpty)
        #expect(events.isEmpty)
        #expect(harness.files.removedURLs == [harness.files.audioURL])
    }

    @Test func temporaryStorageFailureDoesNotAcquireRecorderOrSession() async {
        let harness = makeHarness()
        harness.files.shouldFailCreation = true

        let result = await harness.service.capture(
            requestID: UUID(),
            configuration: harness.configuration,
            onEvent: { _ in }
        )

        #expect(result.outcome == .failed(.temporaryStorageUnavailable))
        #expect(harness.recorderFactory.makeCount == 0)
        #expect(harness.sessionFactory.configurations.isEmpty)
        #expect(harness.files.removedURLs.isEmpty)
    }

    @Test func haloVoiceCannotPreemptTimeShiftAndCreatesNoCaptureArtifacts() async throws {
        let coordinator = AudioCaptureLeaseCoordinator()
        let timeShiftLease = try #require(
            await coordinator.acquire(for: .timeShift).lease
        )
        let harness = makeHarness(audioCaptureLeaseCoordinator: coordinator)

        let result = await harness.service.capture(
            requestID: UUID(),
            configuration: harness.configuration,
            onEvent: { _ in }
        )

        #expect(result.outcome == .failed(.captureUnavailable))
        #expect(harness.files.createCount == 0)
        #expect(harness.recorderFactory.makeCount == 0)
        #expect(harness.sessionFactory.configurations.isEmpty)
        #expect(await coordinator.activeOwner == .timeShift)
        #expect(await coordinator.release(timeShiftLease))
    }

    @Test func cancellationWhileLeaseAcquisitionIsSuspendedReleasesLateLeaseWithoutArtifacts() async {
        let coordinator = SuspendedHaloVoiceLeaseCoordinator()
        let harness = makeHarness(audioCaptureLeaseCoordinator: coordinator)
        let requestID = UUID()
        let lateLease = AudioCaptureLease(owner: .haloVoice)

        let capture = Task { @MainActor in
            await harness.service.capture(
                requestID: requestID,
                configuration: harness.configuration,
                onEvent: { _ in }
            )
        }
        await coordinator.waitUntilAcquireStarts()

        #expect(harness.service.cancel(requestID: requestID))
        await coordinator.resumeAcquisition(with: lateLease)
        let result = await capture.value

        #expect(result.outcome == .cancelled)
        #expect(await coordinator.releasedLeases == [lateLease])
        #expect(harness.files.createCount == 0)
        #expect(harness.recorderFactory.makeCount == 0)
        #expect(harness.sessionFactory.configurations.isEmpty)
    }

    @Test func haloVoiceLeaseRemainsHeldThroughRecorderStopThenReleases() async {
        let coordinator = AudioCaptureLeaseCoordinator()
        let harness = makeHarness(audioCaptureLeaseCoordinator: coordinator)
        harness.recorder.audioCaptureLeaseCoordinator = coordinator
        let requestID = UUID()

        let capture = Task { @MainActor in
            await harness.service.capture(
                requestID: requestID,
                configuration: harness.configuration,
                onEvent: { _ in }
            )
        }
        await waitUntil { harness.recorder.startedURLs.count == 1 }

        #expect(await coordinator.activeOwner == .haloVoice)
        #expect(harness.service.requestStop(requestID: requestID))
        _ = await capture.value

        #expect(harness.recorder.activeLeaseOwnerAtStop == .haloVoice)
        #expect(await coordinator.activeOwner == nil)
        assertCleanedUp(harness)
    }

    @Test func defaultTemporaryFilesAreUniqueWAVsAndRemovalDeletesAudio() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInk-HaloVoiceFileTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = DefaultHaloVoiceInstructionTemporaryFileManager(
            baseDirectory: directory
        )

        let firstURL = try manager.createAudioURL()
        let secondURL = try manager.createAudioURL()
        #expect(firstURL != secondURL)
        #expect(firstURL.pathExtension == "wav")
        #expect(secondURL.pathExtension == "wav")

        try Data([1, 2, 3]).write(to: firstURL)
        manager.removeAudio(at: firstURL)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
    }

    @Test func defaultTemporaryFileManagerPurgesOnlyStaleHaloWAVs() throws {
        let fileManager = FileManager.default
        let parentDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("VoiceInk-HaloVoicePurgeTests-\(UUID().uuidString)")
        let haloDirectory = parentDirectory
            .appendingPathComponent("HaloVoiceRefinement", isDirectory: true)
        defer { try? fileManager.removeItem(at: parentDirectory) }

        try fileManager.createDirectory(
            at: haloDirectory,
            withIntermediateDirectories: true
        )
        let staleWAV = haloDirectory.appendingPathComponent("stale.wav")
        let staleUppercaseWAV = haloDirectory.appendingPathComponent("stale.WAV")
        let unrelatedFile = haloDirectory.appendingPathComponent("keep.txt")
        let nestedDirectory = haloDirectory.appendingPathComponent("keep.wav", isDirectory: true)
        let siblingWAV = parentDirectory.appendingPathComponent("outside.wav")
        try Data([1]).write(to: staleWAV)
        try Data([2]).write(to: staleUppercaseWAV)
        try Data([3]).write(to: unrelatedFile)
        try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: false)
        try Data([4]).write(to: siblingWAV)

        _ = DefaultHaloVoiceInstructionTemporaryFileManager(
            fileManager: fileManager,
            baseDirectory: haloDirectory
        )

        #expect(!fileManager.fileExists(atPath: staleWAV.path))
        #expect(!fileManager.fileExists(atPath: staleUppercaseWAV.path))
        #expect(fileManager.fileExists(atPath: unrelatedFile.path))
        var isDirectory: ObjCBool = false
        #expect(fileManager.fileExists(atPath: nestedDirectory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(fileManager.fileExists(atPath: siblingWAV.path))
    }

    private struct Harness {
        let service: HaloVoiceInstructionCaptureService
        let configuration: TranscriptionRuntimeConfiguration
        let recorder: FakeHaloVoiceAudioRecorder
        let recorderFactory: FakeHaloVoiceAudioRecorderFactory
        let session: FakeHaloVoiceTranscriptionSession
        let sessionFactory: FakeHaloVoiceSessionFactory
        let files: FakeHaloVoiceTemporaryFiles
        let deadlines: ManualHaloVoiceDeadlineScheduler
    }

    private func makeHarness(
        realtime: Bool = false,
        audioCaptureLeaseCoordinator: (any AudioCaptureLeaseCoordinating)? = nil
    ) -> Harness {
        let audioCaptureLeaseCoordinator = audioCaptureLeaseCoordinator
            ?? ImmediateHaloVoiceLeaseCoordinator()
        let recorder = FakeHaloVoiceAudioRecorder()
        let recorderFactory = FakeHaloVoiceAudioRecorderFactory(recorder: recorder)
        let session = FakeHaloVoiceTranscriptionSession()
        let sessionFactory = FakeHaloVoiceSessionFactory(session: session)
        let files = FakeHaloVoiceTemporaryFiles()
        let deadlines = ManualHaloVoiceDeadlineScheduler()
        let configuration = TranscriptionRuntimeConfiguration(
            mode: nil,
            model: CloudModel(
                name: "frozen-model",
                displayName: "Frozen Model",
                description: "Test model",
                provider: .deepgram,
                speed: 1,
                accuracy: 1,
                isMultilingual: true,
                supportsStreaming: realtime,
                supportedLanguages: ["pt": "Portuguese"]
            ),
            language: "pt",
            isRealtimeEnabled: realtime
        )
        let service = HaloVoiceInstructionCaptureService(
            audioRecorderFactory: recorderFactory,
            sessionFactory: sessionFactory,
            temporaryFiles: files,
            deadlineScheduler: deadlines,
            audioCaptureLeaseCoordinator: audioCaptureLeaseCoordinator
        )
        return Harness(
            service: service,
            configuration: configuration,
            recorder: recorder,
            recorderFactory: recorderFactory,
            session: session,
            sessionFactory: sessionFactory,
            files: files,
            deadlines: deadlines
        )
    }

    private func assertCleanedUp(_ harness: Harness) {
        #expect(harness.recorder.stopCount == 1)
        #expect(harness.recorder.onAudioChunk == nil)
        #expect(harness.recorder.onAudioMeter == nil)
        #expect(harness.session.cancelCount >= 1)
        #expect(harness.files.removedURLs == [harness.files.audioURL])
        #expect(harness.service.activeRequestID == nil)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        // Let the newly-created capture task and its short preparation tasks
        // win several cooperative main-actor turns before the app test host's
        // delayed local-model prewarm can begin.
        for _ in 0..<1_000 {
            if condition() {
                return
            }
            await Task.yield()
        }

        // Retain a bounded wall-clock fallback for unusually loaded hosts.
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Timed out waiting for async Halo voice capture state")
    }
}
