import Foundation

enum AudioCaptureLeaseOwner: String, Equatable, Sendable {
    case normalRecording
    case timeShift
    case haloVoice
}

struct AudioCaptureLease: Equatable, Sendable {
    let id: UUID
    let owner: AudioCaptureLeaseOwner

    init(id: UUID = UUID(), owner: AudioCaptureLeaseOwner) {
        self.id = id
        self.owner = owner
    }
}

enum AudioCaptureLeaseDenial: Equatable, Sendable {
    case occupied(by: AudioCaptureLeaseOwner)
    case timeShiftPreemptionUnavailable
    case preemptionInProgress
}

enum AudioCaptureLeaseAcquisition: Equatable, Sendable {
    case acquired(AudioCaptureLease)
    case denied(AudioCaptureLeaseDenial)

    var lease: AudioCaptureLease? {
        guard case .acquired(let lease) = self else { return nil }
        return lease
    }
}

/// Serializes access to the microphone across the three recorder workflows.
///
/// Normal recording is the only owner allowed to preempt another owner. When
/// Time-Shift owns the microphone, its registered handler must finish stopping
/// capture and zeroing audio before the normal-recording lease is returned.
actor AudioCaptureLeaseCoordinator {
    typealias TimeShiftPreemptionHandler = @Sendable (AudioCaptureLease) async -> Void

    private var activeLease: AudioCaptureLease?
    private var timeShiftPreemptionHandler: TimeShiftPreemptionHandler?
    private var isPreempting = false

    var activeOwner: AudioCaptureLeaseOwner? {
        activeLease?.owner
    }

    func setTimeShiftPreemptionHandler(
        _ handler: TimeShiftPreemptionHandler?
    ) {
        timeShiftPreemptionHandler = handler
    }

    func acquire(for owner: AudioCaptureLeaseOwner) async -> AudioCaptureLeaseAcquisition {
        guard !isPreempting else {
            return .denied(.preemptionInProgress)
        }

        guard let occupiedLease = activeLease else {
            let lease = AudioCaptureLease(owner: owner)
            activeLease = lease
            return .acquired(lease)
        }

        guard owner == .normalRecording,
            occupiedLease.owner == .timeShift
        else {
            return .denied(.occupied(by: occupiedLease.owner))
        }

        guard let timeShiftPreemptionHandler else {
            return .denied(.timeShiftPreemptionUnavailable)
        }

        isPreempting = true
        await timeShiftPreemptionHandler(occupiedLease)

        // The handler normally releases its own lease after stopping and
        // clearing. If it did not, invalidate that exact stale lease here only
        // after the cleanup handler has completed.
        if activeLease?.id == occupiedLease.id {
            activeLease = nil
        }

        let lease = AudioCaptureLease(owner: owner)
        activeLease = lease
        isPreempting = false
        return .acquired(lease)
    }

    @discardableResult
    func release(_ lease: AudioCaptureLease) -> Bool {
        guard activeLease == lease else { return false }
        activeLease = nil
        return true
    }
}

enum TimeShiftUnavailableReason: String, Equatable, Sendable {
    case disabled
    case systemSleeping
    case screenLocked
    case permissionDenied
    case audioDeviceChanged
    case microphoneInUse
    case audioCaptureFailed
    case unsupportedModel
    case terminating
}

enum TimeShiftLifecycleEvent: Equatable, Sendable {
    case disabled
    case sleep
    case lock
    case permissionLoss
    case deviceChange
    case termination

    var unavailableReason: TimeShiftUnavailableReason {
        switch self {
        case .disabled:
            return .disabled
        case .sleep:
            return .systemSleeping
        case .lock:
            return .screenLocked
        case .permissionLoss:
            return .permissionDenied
        case .deviceChange:
            return .audioDeviceChanged
        case .termination:
            return .terminating
        }
    }
}

enum TimeShiftCaptureState: Equatable, Sendable {
    case unavailable(TimeShiftUnavailableReason)
    case unarmed
    case arming(sessionID: UUID)
    case armed(sessionID: UUID, bufferedSampleCount: Int)
    case capturing(sessionID: UUID, requestID: UUID)
    case processing(requestID: UUID, sampleCount: Int)

    var hasActiveAudioCapture: Bool {
        switch self {
        case .arming, .armed, .capturing:
            return true
        case .unavailable, .unarmed, .processing:
            return false
        }
    }

    var hasSensitiveAudio: Bool {
        switch self {
        case .arming, .armed, .capturing, .processing:
            return true
        case .unavailable, .unarmed:
            return false
        }
    }
}

/// Privacy-safe aggregate information from a completed one-shot capture.
/// It deliberately contains no bytes, timestamps, destination, Mode, or text.
struct TimeShiftCaptureMetrics: Equatable, Sendable {
    let sampleCount: Int

    init(sampleCount: Int) {
        self.sampleCount = max(0, min(sampleCount, PCM16RingBuffer.capacitySamples))
    }

    var duration: TimeInterval {
        TimeInterval(sampleCount) / TimeInterval(PCM16Snapshot.sampleRate)
    }
}

enum TimeShiftCaptureEvent: Equatable, Sendable {
    case availabilityRestored
    case modelSupportChanged(isSupported: Bool)
    case beginArming(sessionID: UUID)
    case armingSucceeded(sessionID: UUID)
    case armingFailed(sessionID: UUID, reason: TimeShiftUnavailableReason)
    case bufferedSamples(sessionID: UUID, totalSampleCount: Int)
    case beginCapture(requestID: UUID)
    case captureSnapshotReady(requestID: UUID, sampleCount: Int)
    case captureFailed(requestID: UUID)
    case processingFinished(requestID: UUID)
    case processingFailed(requestID: UUID)
    case disarm
    case normalRecordingPreemption
    case lifecycle(TimeShiftLifecycleEvent)
}

enum TimeShiftCaptureEffect: Equatable, Sendable {
    case stopAudioCapture
    case clearAudio
    case releaseLease
}

struct TimeShiftCaptureTransition: Equatable, Sendable {
    let state: TimeShiftCaptureState
    let effects: [TimeShiftCaptureEffect]
    let metrics: TimeShiftCaptureMetrics?
}

/// Pure reducer for the Time-Shift audio lifecycle.
struct TimeShiftCaptureStateMachine: Sendable {
    private(set) var state: TimeShiftCaptureState
    private(set) var latestMetrics: TimeShiftCaptureMetrics?

    init(initialState: TimeShiftCaptureState = .unarmed) {
        state = initialState
    }

    @discardableResult
    mutating func handle(_ event: TimeShiftCaptureEvent) -> TimeShiftCaptureTransition {
        var effects: [TimeShiftCaptureEffect] = []
        var emittedMetrics: TimeShiftCaptureMetrics?

        switch event {
        case .availabilityRestored:
            if case .unavailable = state {
                state = .unarmed
                effects = [.clearAudio]
            }

        case .modelSupportChanged(let isSupported):
            if isSupported {
                if state == .unavailable(.unsupportedModel) {
                    state = .unarmed
                    effects = [.clearAudio]
                }
            } else {
                switch state {
                case .unarmed:
                    state = .unavailable(.unsupportedModel)
                    effects = [.clearAudio]
                case .arming, .armed:
                    state = .unavailable(.unsupportedModel)
                    latestMetrics = nil
                    effects = Self.fullCleanupEffects
                case .unavailable(.unsupportedModel), .capturing, .processing:
                    break
                case .unavailable:
                    // A stronger lifecycle/permission reason remains visible.
                    break
                }
            }

        case .beginArming(let sessionID):
            guard state == .unarmed else { break }
            latestMetrics = nil
            state = .arming(sessionID: sessionID)

        case .armingSucceeded(let sessionID):
            guard state == .arming(sessionID: sessionID) else { break }
            state = .armed(sessionID: sessionID, bufferedSampleCount: 0)

        case .armingFailed(let sessionID, let reason):
            guard state == .arming(sessionID: sessionID) else { break }
            state = .unavailable(reason)
            latestMetrics = nil
            effects = Self.fullCleanupEffects

        case .bufferedSamples(let sessionID, let totalSampleCount):
            guard case .armed(let activeSessionID, _) = state,
                activeSessionID == sessionID
            else {
                break
            }
            let boundedCount = max(0, min(totalSampleCount, PCM16RingBuffer.capacitySamples))
            state = .armed(sessionID: sessionID, bufferedSampleCount: boundedCount)

        case .beginCapture(let requestID):
            guard case .armed(let sessionID, _) = state else { break }
            state = .capturing(sessionID: sessionID, requestID: requestID)
            effects = [.stopAudioCapture]

        case .captureSnapshotReady(let requestID, let sampleCount):
            guard case .capturing(_, let activeRequestID) = state,
                activeRequestID == requestID
            else {
                break
            }
            let metrics = TimeShiftCaptureMetrics(sampleCount: sampleCount)
            latestMetrics = metrics
            emittedMetrics = metrics
            state = .processing(requestID: requestID, sampleCount: metrics.sampleCount)
            effects = [.clearAudio, .releaseLease]

        case .captureFailed(let requestID):
            guard case .capturing(_, let activeRequestID) = state,
                activeRequestID == requestID
            else {
                break
            }
            latestMetrics = nil
            state = .unarmed
            effects = Self.fullCleanupEffects

        case .processingFinished(let requestID), .processingFailed(let requestID):
            guard case .processing(let activeRequestID, _) = state,
                activeRequestID == requestID
            else {
                break
            }
            state = .unarmed
            effects = [.clearAudio]

        case .disarm:
            let hadActiveCapture = state.hasActiveAudioCapture
            state = .unarmed
            latestMetrics = nil
            effects = hadActiveCapture ? Self.fullCleanupEffects : [.clearAudio]

        case .normalRecordingPreemption:
            guard state.hasActiveAudioCapture else { break }
            state = .unarmed
            latestMetrics = nil
            effects = Self.fullCleanupEffects

        case .lifecycle(let lifecycleEvent):
            let hadActiveCapture = state.hasActiveAudioCapture
            state = .unavailable(lifecycleEvent.unavailableReason)
            latestMetrics = nil
            effects = hadActiveCapture ? Self.fullCleanupEffects : [.clearAudio]
        }

        return TimeShiftCaptureTransition(
            state: state,
            effects: effects,
            metrics: emittedMetrics
        )
    }

    private static let fullCleanupEffects: [TimeShiftCaptureEffect] = [
        .stopAudioCapture,
        .clearAudio,
        .releaseLease,
    ]
}

/// Executes reducer effects in their declared order using injected hardware,
/// buffer, and lease operations. No effect has filesystem access.
struct TimeShiftCaptureEffectExecutor: Sendable {
    let stopAudioCapture: @Sendable () async -> Void
    let clearAudio: @Sendable () -> Void
    let releaseLease: @Sendable () async -> Void

    func execute(_ effects: [TimeShiftCaptureEffect]) async {
        for effect in effects {
            switch effect {
            case .stopAudioCapture:
                await stopAudioCapture()
            case .clearAudio:
                clearAudio()
            case .releaseLease:
                await releaseLease()
            }
        }
    }
}
