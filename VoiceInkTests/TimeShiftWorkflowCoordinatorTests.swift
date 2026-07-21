import CoreAudio
import Foundation
import Testing
@testable import VoiceInk

@MainActor
struct TimeShiftWorkflowCoordinatorTests {
    @Test func armingDoesNotEnterThePostCaptureProductPipeline() async {
        let harness = makeHarness()

        await harness.coordinator.arm()

        guard case .armed = harness.coordinator.status else {
            Issue.record("Expected Time-Shift to arm")
            return
        }
        #expect(harness.routeProvider.resolutionCount >= 1)
        #expect(harness.processor.requestCount == 0)
        #expect(harness.processor.destinationLookupCount == 0)
        #expect(harness.processor.contextLookupCount == 0)
        #expect(harness.processor.historyMutationCount == 0)
        #expect(harness.processor.networkRequestCount == 0)
        await harness.coordinator.disarm()
    }

    @Test func captureResolvesAgainThenRunsForcedReviewPipeline() async throws {
        let snapshot = PCM16Snapshot(pcmData: pcmData([1, 2, 3, 4]))
        let harness = makeHarness(snapshot: snapshot)
        await harness.coordinator.arm()
        let armResolutionCount = harness.routeProvider.resolutionCount

        let outcome = await harness.coordinator.capture()

        #expect(outcome == .completed)
        #expect(harness.routeProvider.resolutionCount > armResolutionCount)
        #expect(harness.routeProvider.resolvedPurposes.last == .capture)
        #expect(harness.processor.requestCount == 1)
        #expect(harness.processor.destinationLookupCount == 1)
        #expect(harness.processor.contextLookupCount == 1)
        #expect(harness.processor.historyMutationCount == 1)
        #expect(harness.processor.networkRequestCount == 1)
        let request = try #require(harness.processor.lastRequest)
        #expect(request.deliveryRequirement == .forcedReview)
        #expect(request.route.provider == .groq)
        #expect(request.route.modelName == "whisper-large-v3-turbo")
        #expect(request.metrics.sampleCount == 4)
        #expect(request.metrics.duration == 4.0 / Double(PCM16Snapshot.sampleRate))
        #expect(harness.coordinator.status == .ready)
        #expect(snapshot.isZeroized)
    }

    @Test func unsupportedModelPreventsArmAndNeverStartsAudio() async {
        let unsupported = Self.cloudModel(name: "native", provider: .nativeApple)
        let routeProvider = TimeShiftRouteProviderSpy(
            selectedModelName: "native",
            availableModels: [unsupported]
        )
        let harness = makeHarness(routeProvider: routeProvider)

        await harness.coordinator.arm()

        #expect(harness.coordinator.status == .unavailable(.unsupportedModel))
        #expect(harness.source.events.isEmpty)
        #expect(harness.processor.requestCount == 0)
        #expect(await harness.leaseCoordinator.activeOwner == nil)
    }

    @Test func modelBecomingUnsupportedAfterArmNeverRunsProcessor() async {
        let harness = makeHarness()
        await harness.coordinator.arm()
        harness.routeProvider.selectedModelName = "missing-after-arm"

        let outcome = await harness.coordinator.capture()

        #expect(outcome == .failed(.unsupportedModel))
        #expect(harness.processor.requestCount == 0)
        #expect(harness.coordinator.status == .failed(.unsupportedModel))
        #expect(harness.source.snapshot.isZeroized)
        #expect(await harness.leaseCoordinator.activeOwner == nil)
    }

    @Test func unsupportedModelChangeWhileArmedImmediatelyDisarmsAndClears() async {
        let harness = makeHarness()
        await harness.coordinator.arm()
        harness.routeProvider.selectedModelName = "missing-after-arm"

        await harness.coordinator.reconcileModelAvailability()

        #expect(harness.coordinator.status == .unavailable(.unsupportedModel))
        #expect(harness.source.events.suffix(2) == ["stopClear", "clear"])
        #expect(harness.source.snapshot.isZeroized)
        #expect(await harness.leaseCoordinator.activeOwner == nil)
        #expect(harness.processor.requestCount == 0)
    }

    @Test func supportedModelChangeRestoresReadyWithoutArming() async {
        let model = Self.cloudModel(
            name: "whisper-large-v3-turbo",
            provider: .groq
        )
        let routeProvider = TimeShiftRouteProviderSpy(
            selectedModelName: "missing",
            availableModels: [model]
        )
        let harness = makeHarness(routeProvider: routeProvider)
        #expect(harness.coordinator.status == .unavailable(.unsupportedModel))
        routeProvider.selectedModelName = model.name

        await harness.coordinator.reconcileModelAvailability()

        #expect(harness.coordinator.status == .ready)
        #expect(harness.source.events == ["clear"])
        #expect(harness.processor.requestCount == 0)
        #expect(await harness.leaseCoordinator.activeOwner == nil)
    }

    @Test func processorFailureIsSanitizedAndZeroesOutstandingSnapshot() async {
        let snapshot = PCM16Snapshot(pcmData: pcmData([8, 9]))
        let harness = makeHarness(snapshot: snapshot)
        harness.processor.error = RawWorkflowError.secretBackendResponse
        await harness.coordinator.arm()

        let outcome = await harness.coordinator.capture()

        #expect(outcome == .failed(.transcription(.failed)))
        #expect(harness.coordinator.status == .failed(.transcription(.failed)))
        #expect(snapshot.isZeroized)
    }

    @Test func cancellationClearsBorrowedSnapshotAndIgnoresLateCompletion() async {
        let snapshot = PCM16Snapshot(pcmData: pcmData([5, 6]))
        let processor = TimeShiftWorkflowProcessorSpy(suspendProcessing: true)
        let harness = makeHarness(snapshot: snapshot, processor: processor)
        await harness.coordinator.arm()

        let captureTask = Task { @MainActor in
            await harness.coordinator.capture()
        }
        await processor.waitUntilSuspended()
        await harness.coordinator.cancelProcessing()
        processor.resume()

        let outcome = await captureTask.value
        #expect(outcome == .failed(.cancelled))
        #expect(harness.coordinator.status == .failed(.cancelled))
        #expect(snapshot.isZeroized)
        #expect(await harness.leaseCoordinator.activeOwner == nil)
    }

    @Test func recorderStyleChangeDuringSnapshotCancelsBeforeProductPipeline() async {
        let snapshot = PCM16Snapshot(pcmData: pcmData([13, 14, 15]))
        let source = TimeShiftWorkflowAudioSourceSpy(
            snapshot: snapshot,
            suspendSnapshot: true
        )
        let harness = makeHarness(source: source)
        await harness.coordinator.arm()

        let captureTask = Task { @MainActor in
            await harness.coordinator.capture()
        }
        await source.waitUntilSnapshotSuspended()
        #expect(harness.coordinator.status == .capturing)

        await harness.coordinator.cancelForRecorderStyleChange()

        #expect(harness.coordinator.status == .ready)
        #expect(snapshot.isZeroized)
        #expect(source.events.contains("stopClear"))
        #expect(source.events.contains("clear"))
        #expect(await harness.leaseCoordinator.activeOwner == nil)
        #expect(harness.processor.requestCount == 0)

        source.resumeSnapshot()
        let outcome = await captureTask.value
        #expect(outcome == .notArmed)
        #expect(harness.coordinator.status == .ready)
        #expect(harness.processor.requestCount == 0)
    }

    @Test func recorderStyleChangeDuringProcessingRejectsLateCompletion() async {
        let snapshot = PCM16Snapshot(pcmData: pcmData([16, 17]))
        let processor = TimeShiftWorkflowProcessorSpy(suspendProcessing: true)
        let harness = makeHarness(snapshot: snapshot, processor: processor)
        await harness.coordinator.arm()

        let captureTask = Task { @MainActor in
            await harness.coordinator.capture()
        }
        await processor.waitUntilSuspended()
        #expect(harness.coordinator.status == .processing)

        await harness.coordinator.cancelForRecorderStyleChange()

        #expect(harness.coordinator.status == .ready)
        #expect(snapshot.isZeroized)
        #expect(await harness.leaseCoordinator.activeOwner == nil)

        processor.resume()
        let outcome = await captureTask.value
        #expect(outcome == .failed(.cancelled))
        #expect(harness.coordinator.status == .ready)
        #expect(harness.processor.requestCount == 1)
    }

    @Test func normalRecordingPreemptionDisarmsThroughCoordinatorState() async throws {
        let harness = makeHarness()
        await harness.coordinator.arm()

        let normalLease = try #require(
            await harness.leaseCoordinator.acquire(for: .normalRecording).lease
        )

        #expect(harness.coordinator.status == .ready)
        #expect(harness.source.events.contains("stopClear"))
        #expect(await harness.leaseCoordinator.activeOwner == .normalRecording)
        #expect(await harness.leaseCoordinator.release(normalLease))
    }

    @Test func lifecycleDuringProcessingCancelsPipelineAndZeroesAudio() async {
        let snapshot = PCM16Snapshot(pcmData: pcmData([11, 12]))
        let processor = TimeShiftWorkflowProcessorSpy(suspendProcessing: true)
        let harness = makeHarness(snapshot: snapshot, processor: processor)
        await harness.coordinator.arm()

        let captureTask = Task { @MainActor in
            await harness.coordinator.capture()
        }
        await processor.waitUntilSuspended()
        await harness.coordinator.handleLifecycle(.lock)
        processor.resume()
        _ = await captureTask.value

        #expect(harness.coordinator.status == .unavailable(.screenLocked))
        #expect(snapshot.isZeroized)
        #expect(await harness.leaseCoordinator.activeOwner == nil)
    }

    private struct Harness {
        let coordinator: TimeShiftWorkflowCoordinator
        let routeProvider: TimeShiftRouteProviderSpy
        let processor: TimeShiftWorkflowProcessorSpy
        let source: TimeShiftWorkflowAudioSourceSpy
        let leaseCoordinator: AudioCaptureLeaseCoordinator
    }

    private func makeHarness(
        snapshot: PCM16Snapshot? = nil,
        routeProvider: TimeShiftRouteProviderSpy? = nil,
        processor: TimeShiftWorkflowProcessorSpy? = nil,
        source: TimeShiftWorkflowAudioSourceSpy? = nil
    ) -> Harness {
        let model = Self.cloudModel(
            name: "whisper-large-v3-turbo",
            provider: .groq
        )
        let routeProvider = routeProvider ?? TimeShiftRouteProviderSpy(
            selectedModelName: model.name,
            availableModels: [model]
        )
        let processor = processor ?? TimeShiftWorkflowProcessorSpy()
        let source = source ?? TimeShiftWorkflowAudioSourceSpy(
            snapshot: snapshot ?? PCM16Snapshot(pcmData: Self.pcmData([1, 2]))
        )
        let leaseCoordinator = AudioCaptureLeaseCoordinator()
        let coordinator = TimeShiftWorkflowCoordinator(
            routeProvider: routeProvider,
            processor: processor,
            audioSource: source,
            leaseCoordinator: leaseCoordinator,
            capabilityEnabledProvider: { true },
            permissionProvider: { true },
            deviceIDProvider: { 51 },
            observeSystemLifecycle: false
        )
        return Harness(
            coordinator: coordinator,
            routeProvider: routeProvider,
            processor: processor,
            source: source,
            leaseCoordinator: leaseCoordinator
        )
    }

    private static func cloudModel(name: String, provider: ModelProvider) -> CloudModel {
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

    private func pcmData(_ samples: [Int16]) -> Data {
        Self.pcmData(samples)
    }

    private static func pcmData(_ samples: [Int16]) -> Data {
        var result = Data()
        for sample in samples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) {
                result.append(contentsOf: $0)
            }
        }
        return result
    }
}

@MainActor
private final class TimeShiftRouteProviderSpy: TimeShiftExactRouteProviding {
    var selectedModelName: String?
    var availableModels: [any TranscriptionModel]
    private(set) var resolutionCount = 0
    private(set) var resolvedPurposes: [TimeShiftRouteResolutionPurpose] = []

    init(
        selectedModelName: String?,
        availableModels: [any TranscriptionModel]
    ) {
        self.selectedModelName = selectedModelName
        self.availableModels = availableModels
    }

    func resolveExactRoute(
        for purpose: TimeShiftRouteResolutionPurpose
    ) throws -> TimeShiftResolvedTranscriptionRoute {
        resolutionCount += 1
        resolvedPurposes.append(purpose)
        let resolved = try StrictTranscriptionModelRouteResolver.resolve(
            selectedModelName: selectedModelName,
            availableModels: availableModels
        )
        return TimeShiftResolvedTranscriptionRoute(model: resolved.model)
    }
}

@MainActor
private final class TimeShiftWorkflowProcessorSpy: TimeShiftWorkflowProcessing {
    private(set) var requestCount = 0
    private(set) var destinationLookupCount = 0
    private(set) var contextLookupCount = 0
    private(set) var historyMutationCount = 0
    private(set) var networkRequestCount = 0
    private(set) var lastRequest: TimeShiftWorkflowRequest?

    var error: Error?
    private let suspendProcessing: Bool
    private var processingContinuation: CheckedContinuation<Void, Never>?
    private var didSuspendContinuation: CheckedContinuation<Void, Never>?

    init(suspendProcessing: Bool = false) {
        self.suspendProcessing = suspendProcessing
    }

    func process(_ request: TimeShiftWorkflowRequest) async throws {
        requestCount += 1
        lastRequest = request

        // These stand in for the product work VoiceInkEngine injects. Their
        // counters prove none of it is reachable before Capture.
        destinationLookupCount += 1
        contextLookupCount += 1
        historyMutationCount += 1
        networkRequestCount += 1

        if suspendProcessing {
            await withCheckedContinuation { continuation in
                processingContinuation = continuation
                didSuspendContinuation?.resume()
                didSuspendContinuation = nil
            }
            try Task.checkCancellation()
        }
        if let error { throw error }
    }

    func waitUntilSuspended() async {
        guard processingContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            didSuspendContinuation = continuation
        }
    }

    func resume() {
        processingContinuation?.resume()
        processingContinuation = nil
    }
}

private final class TimeShiftWorkflowAudioSourceSpy: TimeShiftAudioSourcing, @unchecked Sendable {
    let snapshot: PCM16Snapshot

    private let lock = NSLock()
    private var eventStorage: [String] = []
    private let suspendSnapshot: Bool
    private var snapshotContinuation: CheckedContinuation<Void, Never>?
    private var didSuspendContinuation: CheckedContinuation<Void, Never>?

    init(
        snapshot: PCM16Snapshot,
        suspendSnapshot: Bool = false
    ) {
        self.snapshot = snapshot
        self.suspendSnapshot = suspendSnapshot
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return eventStorage
    }

    var bufferedSampleCount: Int {
        snapshot.sampleCount
    }

    func start(deviceID: AudioDeviceID) async throws {
        append("start:\(deviceID)")
    }

    func stopAndSnapshot() async -> PCM16Snapshot {
        append("snapshot")
        if suspendSnapshot {
            await withCheckedContinuation { continuation in
                snapshotContinuation = continuation
                didSuspendContinuation?.resume()
                didSuspendContinuation = nil
            }
        }
        return snapshot
    }

    func waitUntilSnapshotSuspended() async {
        guard snapshotContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            didSuspendContinuation = continuation
        }
    }

    func resumeSnapshot() {
        snapshotContinuation?.resume()
        snapshotContinuation = nil
    }

    func stopAndClear() async {
        append("stopClear")
        snapshot.zeroize()
    }

    func clearBufferedAudio() async {
        append("clear")
    }

    func shutdownImmediately() {
        append("shutdown")
    }

    private func append(_ value: String) {
        lock.lock()
        eventStorage.append(value)
        lock.unlock()
    }
}

private enum RawWorkflowError: Error {
    case secretBackendResponse
}
