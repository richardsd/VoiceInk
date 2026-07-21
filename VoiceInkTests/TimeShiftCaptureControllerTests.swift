import AppKit
import CoreAudio
import Foundation
import Testing
@testable import VoiceInk

@MainActor
struct TimeShiftCaptureControllerTests {
    @Test func disabledCapabilityCannotAcquireOrStartAudio() async {
        let harness = makeHarness(enabled: false)

        await harness.controller.arm()

        #expect(harness.controller.state == .unavailable(.disabled))
        #expect(harness.source.events == ["clear"])
        #expect(await harness.coordinator.activeOwner == nil)
        #expect(harness.metrics.values.last?.outcome == .disabled)
    }

    @Test func successfulArmOwnsTimeShiftLeaseOnlyAfterMemorySourceStarts() async {
        let harness = makeHarness()

        await harness.controller.arm()

        guard case .armed = harness.controller.state else {
            Issue.record("Expected an armed Time-Shift controller")
            return
        }
        #expect(harness.source.events.first == "start:41")
        #expect(await harness.coordinator.activeOwner == .timeShift)
        #expect(harness.metrics.values.last == TimeShiftAggregateMetric(
            action: .arm,
            outcome: .succeeded,
            duration: nil
        ))
        await harness.controller.disarm()
    }

    @Test func normalRecordingPreemptsOnlyAfterTimeShiftStopsAndClears() async throws {
        let harness = makeHarness()
        await harness.controller.arm()

        let normalLease = try #require(
            await harness.coordinator.acquire(for: .normalRecording).lease
        )

        #expect(harness.source.events.contains("stopClear"))
        #expect(harness.controller.state == .unarmed)
        #expect(await harness.coordinator.activeOwner == .normalRecording)
        #expect(await harness.coordinator.release(normalLease))
    }

    @Test func haloVoiceCannotPreemptAnArmedTimeShiftSession() async {
        let harness = makeHarness()
        await harness.controller.arm()

        #expect(
            await harness.coordinator.acquire(for: .haloVoice)
                == .denied(.occupied(by: .timeShift))
        )
        #expect(await harness.coordinator.activeOwner == .timeShift)
        await harness.controller.disarm()
    }

    @Test func captureReleasesMicRetainsOneTicketThenFinishZeroesIt() async throws {
        let source = TimeShiftAudioSourceSpy(snapshotData: pcmData([1, 2, 3]))
        let harness = makeHarness(source: source)
        await harness.controller.arm()

        let ticket = try #require(await harness.controller.capture())

        #expect(harness.controller.state == .processing(
            requestID: ticket.requestID,
            sampleCount: 3
        ))
        #expect(ticket.metrics.sampleCount == 3)
        #expect(ticket.metrics.duration == 3.0 / 16_000.0)
        #expect(await harness.coordinator.activeOwner == nil)
        #expect(!ticket.snapshot.isZeroized)

        await harness.controller.finishProcessing(requestID: ticket.requestID)

        #expect(harness.controller.state == .unarmed)
        #expect(ticket.snapshot.isZeroized)
    }

    @Test func emptyCaptureAutoDisarmsClearsAndReleases() async {
        let harness = makeHarness(source: TimeShiftAudioSourceSpy(snapshotData: Data()))
        await harness.controller.arm()

        let ticket = await harness.controller.capture()

        #expect(ticket == nil)
        #expect(harness.controller.state == .unarmed)
        #expect(await harness.coordinator.activeOwner == nil)
        #expect(harness.source.events.suffix(3) == ["snapshot", "stopClear", "clear"])
        #expect(harness.metrics.values.last?.outcome == .emptyAudio)
    }

    @Test func lifecycleDuringProcessingZeroesTheOutstandingSnapshot() async throws {
        let source = TimeShiftAudioSourceSpy(snapshotData: pcmData([7]))
        let harness = makeHarness(source: source)
        await harness.controller.arm()
        let ticket = try #require(await harness.controller.capture())

        await harness.controller.handleLifecycle(.lock)

        #expect(harness.controller.state == .unavailable(.screenLocked))
        #expect(ticket.snapshot.isZeroized)
        #expect(await harness.coordinator.activeOwner == nil)
    }

    @Test func staleStartCompletionCannotRearmAfterDisable() async {
        let source = TimeShiftAudioSourceSpy(snapshotData: Data(), suspendStart: true)
        let capabilities = TimeShiftCapabilityBox(enabled: true)
        let harness = makeHarness(source: source, capabilities: capabilities)

        let arming = Task { @MainActor in
            await harness.controller.arm()
        }
        await source.waitUntilStartIsSuspended()
        capabilities.enabled = false
        let disabling = Task { @MainActor in
            await harness.controller.handleLifecycle(.disabled)
        }
        source.resumeStart()
        await arming.value
        await disabling.value

        #expect(harness.controller.state == .unavailable(.disabled))
        #expect(await harness.coordinator.activeOwner == nil)
        #expect(source.events.filter { $0 == "stopClear" }.count >= 1)
    }

    @Test func terminationNotificationSynchronouslyStopsAndZeroes() async {
        let harness = makeHarness(observeSystemLifecycle: true)
        await harness.controller.arm()

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        #expect(harness.controller.state == .unavailable(.terminating))
        #expect(harness.source.events.contains("shutdown"))
    }

    @Test func metricsCannotCarryAudioTextDestinationOrRouteMetadata() {
        let mirror = Mirror(reflecting: TimeShiftAggregateMetric(
            action: .capture,
            outcome: .succeeded,
            duration: 1.5
        ))

        #expect(Set(mirror.children.compactMap(\.label)) == ["action", "outcome", "duration"])
    }

    private struct Harness {
        let controller: TimeShiftCaptureController
        let source: TimeShiftAudioSourceSpy
        let coordinator: AudioCaptureLeaseCoordinator
        let capabilities: TimeShiftCapabilityBox
        let metrics: TimeShiftMetricRecorderSpy
    }

    private func makeHarness(
        enabled: Bool = true,
        source: TimeShiftAudioSourceSpy = TimeShiftAudioSourceSpy(),
        capabilities: TimeShiftCapabilityBox? = nil,
        observeSystemLifecycle: Bool = false
    ) -> Harness {
        let capabilities = capabilities ?? TimeShiftCapabilityBox(enabled: enabled)
        let coordinator = AudioCaptureLeaseCoordinator()
        let metrics = TimeShiftMetricRecorderSpy()
        let controller = TimeShiftCaptureController(
            audioSource: source,
            leaseCoordinator: coordinator,
            metricRecorder: metrics,
            capabilityEnabledProvider: { capabilities.enabled },
            permissionProvider: { true },
            deviceIDProvider: { 41 },
            modelSupportProvider: { true },
            observeSystemLifecycle: observeSystemLifecycle
        )
        return Harness(
            controller: controller,
            source: source,
            coordinator: coordinator,
            capabilities: capabilities,
            metrics: metrics
        )
    }

    private static func pcmData(_ samples: [Int16]) -> Data {
        var data = Data()
        for sample in samples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func pcmData(_ samples: [Int16]) -> Data {
        Self.pcmData(samples)
    }
}

@MainActor
private final class TimeShiftCapabilityBox {
    var enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
    }
}

@MainActor
private final class TimeShiftMetricRecorderSpy: TimeShiftMetricRecording {
    private(set) var values: [TimeShiftAggregateMetric] = []

    func record(_ metric: TimeShiftAggregateMetric) {
        values.append(metric)
    }
}

private final class TimeShiftAudioSourceSpy: TimeShiftAudioSourcing, @unchecked Sendable {
    private let lock = NSLock()
    private var eventStorage: [String] = []
    private var snapshotData: Data
    private let suspendStart: Bool
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startDidSuspendContinuation: CheckedContinuation<Void, Never>?

    init(snapshotData: Data = Data([1, 0]), suspendStart: Bool = false) {
        self.snapshotData = snapshotData
        self.suspendStart = suspendStart
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return eventStorage
    }

    var bufferedSampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return snapshotData.count / 2
    }

    func start(deviceID: AudioDeviceID) async throws {
        append("start:\(deviceID)")
        guard suspendStart else { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            startContinuation = continuation
            let didSuspend = startDidSuspendContinuation
            startDidSuspendContinuation = nil
            lock.unlock()
            didSuspend?.resume()
        }
    }

    func stopAndSnapshot() async -> PCM16Snapshot {
        append("snapshot")
        lock.lock()
        let data = snapshotData
        snapshotData.resetBytes(in: 0..<snapshotData.count)
        snapshotData.removeAll(keepingCapacity: false)
        lock.unlock()
        return PCM16Snapshot(pcmData: data)
    }

    func stopAndClear() async {
        append("stopClear")
        clearStorage()
    }

    func clearBufferedAudio() async {
        append("clear")
        clearStorage()
    }

    func shutdownImmediately() {
        append("shutdown")
        clearStorage()
    }

    func waitUntilStartIsSuspended() async {
        lock.lock()
        if startContinuation != nil {
            lock.unlock()
            return
        }
        lock.unlock()
        await withCheckedContinuation { continuation in
            lock.lock()
            if startContinuation != nil {
                lock.unlock()
                continuation.resume()
            } else {
                startDidSuspendContinuation = continuation
                lock.unlock()
            }
        }
    }

    func resumeStart() {
        lock.lock()
        let continuation = startContinuation
        startContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    private func append(_ value: String) {
        lock.lock()
        eventStorage.append(value)
        lock.unlock()
    }

    private func clearStorage() {
        lock.lock()
        if !snapshotData.isEmpty {
            snapshotData.resetBytes(in: 0..<snapshotData.count)
            snapshotData.removeAll(keepingCapacity: false)
        }
        lock.unlock()
    }
}
