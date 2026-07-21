import Foundation
import Testing
@testable import VoiceInk

struct TimeShiftAudioLifecycleTests {
    @Test func leaseAllowsOnlyOneOwnerAtATime() async throws {
        let coordinator = AudioCaptureLeaseCoordinator()
        let normal = try #require(await coordinator.acquire(for: .normalRecording).lease)

        #expect(
            await coordinator.acquire(for: .timeShift)
                == .denied(.occupied(by: .normalRecording))
        )
        #expect(
            await coordinator.acquire(for: .haloVoice)
                == .denied(.occupied(by: .normalRecording))
        )
        #expect(await coordinator.activeOwner == .normalRecording)
        #expect(await coordinator.release(normal))
        #expect(await coordinator.activeOwner == nil)
    }

    @Test func normalRecordingWaitsForTimeShiftCleanupThenWins() async throws {
        let coordinator = AudioCaptureLeaseCoordinator()
        let log = LockedStringLog()
        let timeShift = try #require(await coordinator.acquire(for: .timeShift).lease)

        await coordinator.setTimeShiftPreemptionHandler { lease in
            #expect(lease == timeShift)
            log.append("stop")
            await Task.yield()
            log.append("clear")
            _ = await coordinator.release(lease)
        }

        let normal = try #require(await coordinator.acquire(for: .normalRecording).lease)

        #expect(log.values == ["stop", "clear"])
        #expect(normal.owner == .normalRecording)
        #expect(await coordinator.activeOwner == .normalRecording)
    }

    @Test func normalRecordingCannotBypassMissingTimeShiftCleanup() async throws {
        let coordinator = AudioCaptureLeaseCoordinator()
        _ = try #require(await coordinator.acquire(for: .timeShift).lease)

        #expect(
            await coordinator.acquire(for: .normalRecording)
                == .denied(.timeShiftPreemptionUnavailable)
        )
        #expect(await coordinator.activeOwner == .timeShift)
    }

    @Test func haloVoiceCannotPreemptTimeShift() async throws {
        let coordinator = AudioCaptureLeaseCoordinator()
        _ = try #require(await coordinator.acquire(for: .timeShift).lease)

        #expect(
            await coordinator.acquire(for: .haloVoice)
                == .denied(.occupied(by: .timeShift))
        )
    }

    @Test func staleLeaseCannotReleaseThePreemptingOwner() async throws {
        let coordinator = AudioCaptureLeaseCoordinator()
        let timeShift = try #require(await coordinator.acquire(for: .timeShift).lease)
        await coordinator.setTimeShiftPreemptionHandler { lease in
            _ = await coordinator.release(lease)
        }
        let normal = try #require(await coordinator.acquire(for: .normalRecording).lease)

        #expect(!(await coordinator.release(timeShift)))
        #expect(await coordinator.activeOwner == .normalRecording)
        #expect(await coordinator.release(normal))
    }

    @Test func armingAndBufferUpdatesAreSessionScopedAndBounded() {
        let sessionID = UUID()
        var machine = TimeShiftCaptureStateMachine()

        #expect(machine.handle(.beginArming(sessionID: sessionID)).state == .arming(
            sessionID: sessionID
        ))
        #expect(machine.handle(.armingSucceeded(sessionID: sessionID)).state == .armed(
            sessionID: sessionID,
            bufferedSampleCount: 0
        ))
        _ = machine.handle(.bufferedSamples(
            sessionID: UUID(),
            totalSampleCount: 123
        ))
        #expect(machine.state == .armed(sessionID: sessionID, bufferedSampleCount: 0))

        _ = machine.handle(.bufferedSamples(
            sessionID: sessionID,
            totalSampleCount: PCM16RingBuffer.capacitySamples + 10_000
        ))
        #expect(machine.state == .armed(
            sessionID: sessionID,
            bufferedSampleCount: PCM16RingBuffer.capacitySamples
        ))
    }

    @Test func oneShotCaptureReleasesTheMicWhileProcessingThenAutoDisarms() {
        let sessionID = UUID()
        let requestID = UUID()
        var machine = TimeShiftCaptureStateMachine()
        arm(&machine, sessionID: sessionID)

        let begin = machine.handle(.beginCapture(requestID: requestID))
        #expect(begin.state == .capturing(sessionID: sessionID, requestID: requestID))
        #expect(begin.effects == [.stopAudioCapture])

        let finished = machine.handle(.captureSnapshotReady(
            requestID: requestID,
            sampleCount: 24_000
        ))
        #expect(finished.state == .processing(requestID: requestID, sampleCount: 24_000))
        #expect(finished.effects == [.clearAudio, .releaseLease])
        #expect(finished.metrics == TimeShiftCaptureMetrics(sampleCount: 24_000))
        #expect(finished.metrics?.duration == 1.5)
        #expect(machine.latestMetrics?.sampleCount == 24_000)

        let secondCapture = machine.handle(.beginCapture(requestID: UUID()))
        #expect(secondCapture.state == .processing(requestID: requestID, sampleCount: 24_000))
        #expect(secondCapture.effects.isEmpty)

        let resolved = machine.handle(.processingFinished(requestID: requestID))
        #expect(resolved.state == .unarmed)
        #expect(resolved.effects == [.clearAudio])
    }

    @Test func staleCaptureCompletionCannotDisarmTheActiveRequest() {
        let sessionID = UUID()
        let activeRequestID = UUID()
        var machine = TimeShiftCaptureStateMachine()
        arm(&machine, sessionID: sessionID)
        _ = machine.handle(.beginCapture(requestID: activeRequestID))

        let stale = machine.handle(.captureSnapshotReady(
            requestID: UUID(),
            sampleCount: 100
        ))

        #expect(stale.state == .capturing(
            sessionID: sessionID,
            requestID: activeRequestID
        ))
        #expect(stale.effects.isEmpty)
        #expect(stale.metrics == nil)
    }

    @Test func captureFailureStopsClearsReleasesAndReturnsToUnarmed() {
        let requestID = UUID()
        var machine = TimeShiftCaptureStateMachine()
        arm(&machine, sessionID: UUID())
        _ = machine.handle(.beginCapture(requestID: requestID))

        let failed = machine.handle(.captureFailed(requestID: requestID))

        #expect(failed.state == .unarmed)
        #expect(failed.effects == [.stopAudioCapture, .clearAudio, .releaseLease])
        #expect(machine.latestMetrics == nil)
    }

    @Test func everyPrivacyLifecycleEventMakesCaptureUnavailableAndClearsAudio() {
        let expectations: [(TimeShiftLifecycleEvent, TimeShiftUnavailableReason)] = [
            (.disabled, .disabled),
            (.sleep, .systemSleeping),
            (.lock, .screenLocked),
            (.permissionLoss, .permissionDenied),
            (.deviceChange, .audioDeviceChanged),
            (.termination, .terminating),
        ]

        for (event, reason) in expectations {
            var machine = TimeShiftCaptureStateMachine()
            arm(&machine, sessionID: UUID())

            let transition = machine.handle(.lifecycle(event))

            #expect(transition.state == .unavailable(reason))
            #expect(transition.effects == [.stopAudioCapture, .clearAudio, .releaseLease])

            let rejectedArm = machine.handle(.beginArming(sessionID: UUID()))
            #expect(rejectedArm.state == .unavailable(reason))
            #expect(rejectedArm.effects.isEmpty)

            let restored = machine.handle(.availabilityRestored)
            #expect(restored.state == .unarmed)
            #expect(restored.effects == [.clearAudio])
        }
    }

    @Test func lifecycleEventsStillClearWhenNoCaptureIsActive() {
        var machine = TimeShiftCaptureStateMachine()

        let transition = machine.handle(.lifecycle(.lock))

        #expect(transition.state == .unavailable(.screenLocked))
        #expect(transition.effects == [.clearAudio])
    }

    @Test func normalRecordingPreemptionPerformsFullCleanupWithoutMakingFeatureUnavailable() {
        var machine = TimeShiftCaptureStateMachine()
        arm(&machine, sessionID: UUID())

        let transition = machine.handle(.normalRecordingPreemption)

        #expect(transition.state == .unarmed)
        #expect(transition.effects == [.stopAudioCapture, .clearAudio, .releaseLease])
    }

    @Test func explicitDisarmClearsEvenWhenAlreadyUnarmed() {
        var machine = TimeShiftCaptureStateMachine()

        let transition = machine.handle(.disarm)

        #expect(transition.state == .unarmed)
        #expect(transition.effects == [.clearAudio])
    }

    @Test func armingFailureIsSessionScopedAndPerformsFullCleanup() {
        let sessionID = UUID()
        var machine = TimeShiftCaptureStateMachine()
        _ = machine.handle(.beginArming(sessionID: sessionID))

        let stale = machine.handle(
            .armingFailed(sessionID: UUID(), reason: .audioCaptureFailed)
        )
        #expect(stale.state == .arming(sessionID: sessionID))
        #expect(stale.effects.isEmpty)

        let failed = machine.handle(
            .armingFailed(sessionID: sessionID, reason: .audioCaptureFailed)
        )
        #expect(failed.state == .unavailable(.audioCaptureFailed))
        #expect(failed.effects == [.stopAudioCapture, .clearAudio, .releaseLease])
    }

    @Test func lifecycleDuringProcessingClearsSnapshotWithoutStoppingTheReleasedMic() {
        let sessionID = UUID()
        let requestID = UUID()
        var machine = TimeShiftCaptureStateMachine()
        arm(&machine, sessionID: sessionID)
        _ = machine.handle(.beginCapture(requestID: requestID))
        _ = machine.handle(.captureSnapshotReady(requestID: requestID, sampleCount: 1_000))

        let transition = machine.handle(.lifecycle(.lock))

        #expect(transition.state == .unavailable(.screenLocked))
        #expect(transition.effects == [.clearAudio])
    }

    @Test func metricsClampToTheFixedRingCapacity() {
        #expect(TimeShiftCaptureMetrics(sampleCount: -1).sampleCount == 0)
        #expect(
            TimeShiftCaptureMetrics(sampleCount: PCM16RingBuffer.capacitySamples + 1).sampleCount
                == PCM16RingBuffer.capacitySamples
        )
        #expect(TimeShiftCaptureMetrics(sampleCount: 160_000).duration == 10)
    }

    @Test func effectExecutorPreservesStopClearReleaseOrdering() async {
        let log = LockedStringLog()
        let executor = TimeShiftCaptureEffectExecutor(
            stopAudioCapture: {
                log.append("stop")
                await Task.yield()
            },
            clearAudio: {
                log.append("clear")
            },
            releaseLease: {
                log.append("release")
            }
        )

        await executor.execute([.stopAudioCapture, .clearAudio, .releaseLease])

        #expect(log.values == ["stop", "clear", "release"])
    }

    private func arm(
        _ machine: inout TimeShiftCaptureStateMachine,
        sessionID: UUID
    ) {
        _ = machine.handle(.beginArming(sessionID: sessionID))
        _ = machine.handle(.armingSucceeded(sessionID: sessionID))
    }
}

private final class LockedStringLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
