import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation

protocol TimeShiftAudioSourcing: AnyObject, Sendable {
    var bufferedSampleCount: Int { get }

    func start(deviceID: AudioDeviceID) async throws
    func stopAndSnapshot() async -> PCM16Snapshot
    func stopAndClear() async
    func clearBufferedAudio() async
    func shutdownImmediately()
}

extension TimeShiftCoreAudioSource: TimeShiftAudioSourcing {}

enum TimeShiftMetricAction: String, Equatable, Sendable {
    case arm
    case disarm
    case capture
    case lifecycleClear
}

enum TimeShiftMetricOutcome: String, Equatable, Sendable {
    case succeeded
    case disabled
    case permissionDenied
    case microphoneInUse
    case unsupportedModel
    case audioCaptureFailed
    case emptyAudio
    case cancelled
    case lifecycleInvalidated
}

/// Deliberately excludes text, audio, destination, Mode, model, provider,
/// credentials, timestamps, and runtime identifiers.
struct TimeShiftAggregateMetric: Equatable, Sendable {
    let action: TimeShiftMetricAction
    let outcome: TimeShiftMetricOutcome
    let duration: TimeInterval?
}

@MainActor
protocol TimeShiftMetricRecording: AnyObject {
    func record(_ metric: TimeShiftAggregateMetric)
}

@MainActor
final class NoOpTimeShiftMetricRecorder: TimeShiftMetricRecording {
    func record(_ metric: TimeShiftAggregateMetric) {}
}

struct TimeShiftCaptureTicket: Sendable {
    let requestID: UUID
    let snapshot: PCM16Snapshot
    let metrics: TimeShiftCaptureMetrics
}

/// Owns Time-Shift's privacy lifecycle, one-shot state, and microphone lease.
///
/// It intentionally stops at the in-memory snapshot boundary. H5-10 supplies
/// the supported transcription adapter; H5-11 owns the forced-review product
/// pipeline. Until then, callers must finish or fail the processing ticket so
/// its snapshot is explicitly zeroed.
@MainActor
final class TimeShiftCaptureController: ObservableObject {
    typealias CapabilityEnabledProvider = @MainActor () -> Bool
    typealias PermissionProvider = @MainActor () -> Bool
    typealias DeviceIDProvider = @MainActor () -> AudioDeviceID
    typealias ModelSupportProvider = @MainActor () -> Bool

    @Published private(set) var state: TimeShiftCaptureState
    @Published private(set) var latestMetric: TimeShiftAggregateMetric?

    private var stateMachine: TimeShiftCaptureStateMachine
    private let audioSource: any TimeShiftAudioSourcing
    private let leaseCoordinator: AudioCaptureLeaseCoordinator
    private let metricRecorder: any TimeShiftMetricRecording
    private let capabilityEnabledProvider: CapabilityEnabledProvider
    private let permissionProvider: PermissionProvider
    private let deviceIDProvider: DeviceIDProvider
    private let modelSupportProvider: ModelSupportProvider
    private let capabilityNotificationObject: AnyObject?

    private var activeLease: AudioCaptureLease?
    private var activeSnapshot: PCM16Snapshot?
    private var notificationObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var armedWatchdogTask: Task<Void, Never>?
    private var armedDeviceID: AudioDeviceID?
    private var isSleeping = false
    private var isScreenLocked = false
    private var isTerminating = false

    init(
        audioSource: any TimeShiftAudioSourcing = TimeShiftCoreAudioSource(),
        leaseCoordinator: AudioCaptureLeaseCoordinator,
        metricRecorder: (any TimeShiftMetricRecording)? = nil,
        capabilityEnabledProvider: @escaping CapabilityEnabledProvider = {
            UserDefaults.standard.bool(forKey: HaloCapabilitySettingsKeys.timeShiftEnabled)
        },
        permissionProvider: @escaping PermissionProvider = {
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        },
        deviceIDProvider: @escaping DeviceIDProvider = {
            AudioDeviceManager.shared.getCurrentDevice()
        },
        modelSupportProvider: @escaping ModelSupportProvider = { true },
        capabilityNotificationObject: AnyObject? = nil,
        observeSystemLifecycle: Bool = true
    ) {
        self.audioSource = audioSource
        self.leaseCoordinator = leaseCoordinator
        self.metricRecorder = metricRecorder ?? NoOpTimeShiftMetricRecorder()
        self.capabilityEnabledProvider = capabilityEnabledProvider
        self.permissionProvider = permissionProvider
        self.deviceIDProvider = deviceIDProvider
        self.modelSupportProvider = modelSupportProvider
        self.capabilityNotificationObject = capabilityNotificationObject

        let initialState: TimeShiftCaptureState
        if !capabilityEnabledProvider() {
            initialState = .unavailable(.disabled)
        } else if !modelSupportProvider() {
            initialState = .unavailable(.unsupportedModel)
        } else {
            initialState = .unarmed
        }
        stateMachine = TimeShiftCaptureStateMachine(initialState: initialState)
        state = initialState

        if observeSystemLifecycle {
            installLifecycleObservers()
        }

    }

    deinit {
        for (center, observer) in notificationObservers {
            center.removeObserver(observer)
        }
        armedWatchdogTask?.cancel()
        activeSnapshot?.zeroize()
        audioSource.shutdownImmediately()
        if let activeLease {
            let leaseCoordinator = leaseCoordinator
            Task {
                _ = await leaseCoordinator.release(activeLease)
            }
        }
    }

    var presentation: TimeShiftStatusPresentation {
        TimeShiftStatusPresentation.project(
            capabilityEnabled: capabilityEnabledProvider(),
            captureState: state
        )
    }

    func toggleArming() async {
        switch state {
        case .arming, .armed:
            await disarm()
        case .unavailable, .unarmed:
            await arm()
        case .capturing, .processing:
            break
        }
    }

    func arm() async {
        guard await prepareAvailabilityForArm() else { return }
        guard state == .unarmed else { return }

        let sessionID = UUID()
        publish(stateMachine.handle(.beginArming(sessionID: sessionID)))

        let deviceID = deviceIDProvider()
        guard deviceID != 0 else {
            let transition = stateMachine.handle(
                .armingFailed(sessionID: sessionID, reason: .audioCaptureFailed)
            )
            publish(transition)
            await execute(transition.effects)
            record(action: .arm, outcome: .audioCaptureFailed)
            return
        }

        // Install the preemption contract before Time-Shift can own the lease.
        // Reinstalling is harmless and closes the init/first-arm race entirely.
        await leaseCoordinator.setTimeShiftPreemptionHandler { [weak self] lease in
            await self?.handleNormalRecordingPreemption(lease: lease)
        }

        let acquisition = await leaseCoordinator.acquire(for: .timeShift)
        guard case .acquired(let lease) = acquisition else {
            let transition = stateMachine.handle(
                .armingFailed(sessionID: sessionID, reason: .microphoneInUse)
            )
            publish(transition)
            await execute(transition.effects)
            record(action: .arm, outcome: .microphoneInUse)
            return
        }

        guard state == .arming(sessionID: sessionID),
            capabilityEnabledProvider(), permissionProvider(), modelSupportProvider(),
            !isSleeping, !isScreenLocked, !isTerminating,
            deviceIDProvider() == deviceID
        else {
            _ = await leaseCoordinator.release(lease)
            return
        }
        activeLease = lease
        armedDeviceID = deviceID

        do {
            try await audioSource.start(deviceID: deviceID)
        } catch {
            let transition = stateMachine.handle(
                .armingFailed(sessionID: sessionID, reason: .audioCaptureFailed)
            )
            publish(transition)
            await execute(transition.effects)
            record(action: .arm, outcome: .audioCaptureFailed)
            return
        }

        guard state == .arming(sessionID: sessionID), capabilityEnabledProvider() else {
            await audioSource.stopAndClear()
            await releaseActiveLease()
            return
        }

        publish(stateMachine.handle(.armingSucceeded(sessionID: sessionID)))
        record(action: .arm, outcome: .succeeded)
    }

    func disarm() async {
        let hadSensitiveAudio = state.hasSensitiveAudio
        activeSnapshot?.zeroize()
        activeSnapshot = nil
        armedDeviceID = nil
        let transition = stateMachine.handle(.disarm)
        publish(transition)
        await execute(transition.effects)
        if hadSensitiveAudio {
            record(action: .disarm, outcome: .succeeded)
        }
    }

    func capture() async -> TimeShiftCaptureTicket? {
        guard case .armed = state else { return nil }

        let requestID = UUID()
        let begin = stateMachine.handle(.beginCapture(requestID: requestID))
        publish(begin)
        guard case .capturing = state else { return nil }

        let snapshot = await audioSource.stopAndSnapshot()
        guard case .capturing(_, let activeRequestID) = state,
            activeRequestID == requestID
        else {
            snapshot.zeroize()
            return nil
        }

        guard !snapshot.isEmpty else {
            snapshot.zeroize()
            let failed = stateMachine.handle(.captureFailed(requestID: requestID))
            publish(failed)
            await execute(failed.effects)
            record(action: .capture, outcome: .emptyAudio, duration: 0)
            return nil
        }

        activeSnapshot?.zeroize()
        activeSnapshot = snapshot
        let ready = stateMachine.handle(
            .captureSnapshotReady(requestID: requestID, sampleCount: snapshot.sampleCount)
        )
        publish(ready)
        await execute(ready.effects)

        let metrics = TimeShiftCaptureMetrics(sampleCount: snapshot.sampleCount)
        record(action: .capture, outcome: .succeeded, duration: metrics.duration)
        return TimeShiftCaptureTicket(
            requestID: requestID,
            snapshot: snapshot,
            metrics: metrics
        )
    }

    func finishProcessing(requestID: UUID) async {
        await resolveProcessing(requestID: requestID, succeeded: true)
    }

    func failProcessing(requestID: UUID) async {
        await resolveProcessing(requestID: requestID, succeeded: false)
    }

    func handleLifecycle(_ event: TimeShiftLifecycleEvent) async {
        switch event {
        case .sleep:
            isSleeping = true
        case .lock:
            isScreenLocked = true
        case .termination:
            isTerminating = true
        case .disabled, .permissionLoss, .deviceChange:
            break
        }

        activeSnapshot?.zeroize()
        activeSnapshot = nil
        armedDeviceID = nil
        let transition = stateMachine.handle(.lifecycle(event))
        publish(transition)
        await execute(transition.effects)
        record(action: .lifecycleClear, outcome: .lifecycleInvalidated)
    }

    func restoreAfterWake() async {
        isSleeping = false
        await restoreAvailabilityIfSafe()
    }

    func restoreAfterUnlock() async {
        isScreenLocked = false
        await restoreAvailabilityIfSafe()
    }

    func reconcileCapability() async {
        if capabilityEnabledProvider() {
            await restoreAvailabilityIfSafe()
        } else {
            await handleLifecycle(.disabled)
            record(action: .disarm, outcome: .disabled)
        }
    }

    /// Reconciles the currently selected transcription model without applying
    /// the normal-recording fallback. Captured processing is deliberately left
    /// alone because its exact route is frozen by the workflow coordinator.
    func reconcileModelSupport() async {
        let transition = stateMachine.handle(
            .modelSupportChanged(isSupported: modelSupportProvider())
        )
        publish(transition)
        await execute(transition.effects)
    }

    private func prepareAvailabilityForArm() async -> Bool {
        guard capabilityEnabledProvider() else {
            await handleLifecycle(.disabled)
            record(action: .arm, outcome: .disabled)
            return false
        }
        guard !isSleeping, !isScreenLocked, !isTerminating else {
            return false
        }
        guard permissionProvider() else {
            await handleLifecycle(.permissionLoss)
            record(action: .arm, outcome: .permissionDenied)
            return false
        }
        guard modelSupportProvider() else {
            await reconcileModelSupport()
            record(action: .arm, outcome: .unsupportedModel)
            return false
        }

        if case .unavailable = state {
            publish(stateMachine.handle(.availabilityRestored))
            await audioSource.clearBufferedAudio()
        }
        return state == .unarmed
    }

    private func restoreAvailabilityIfSafe() async {
        guard capabilityEnabledProvider(), permissionProvider(), modelSupportProvider(),
            !isSleeping, !isScreenLocked, !isTerminating
        else {
            return
        }
        if case .unavailable = state {
            let transition = stateMachine.handle(.availabilityRestored)
            publish(transition)
            await execute(transition.effects)
        }
    }

    private func resolveProcessing(requestID: UUID, succeeded: Bool) async {
        guard case .processing(let activeRequestID, _) = state,
            activeRequestID == requestID
        else {
            return
        }
        activeSnapshot?.zeroize()
        activeSnapshot = nil
        let transition = stateMachine.handle(
            succeeded
                ? .processingFinished(requestID: requestID)
                : .processingFailed(requestID: requestID)
        )
        publish(transition)
        await execute(transition.effects)
    }

    private func handleNormalRecordingPreemption(lease: AudioCaptureLease) async {
        guard activeLease == lease else { return }
        activeSnapshot?.zeroize()
        activeSnapshot = nil
        let transition = stateMachine.handle(.normalRecordingPreemption)
        publish(transition)
        await execute(transition.effects)
        record(action: .disarm, outcome: .cancelled)
    }

    private func execute(_ effects: [TimeShiftCaptureEffect]) async {
        for effect in effects {
            switch effect {
            case .stopAudioCapture:
                await audioSource.stopAndClear()
            case .clearAudio:
                await audioSource.clearBufferedAudio()
            case .releaseLease:
                await releaseActiveLease()
            }
        }
    }

    private func releaseActiveLease() async {
        guard let activeLease else { return }
        self.activeLease = nil
        _ = await leaseCoordinator.release(activeLease)
    }

    private func publish(_ transition: TimeShiftCaptureTransition) {
        state = transition.state
        reconcileArmedWatchdog()
    }

    private func record(
        action: TimeShiftMetricAction,
        outcome: TimeShiftMetricOutcome,
        duration: TimeInterval? = nil
    ) {
        let metric = TimeShiftAggregateMetric(
            action: action,
            outcome: outcome,
            duration: duration
        )
        latestMetric = metric
        metricRecorder.record(metric)
    }

    private func installLifecycleObservers() {
        observe(
            .haloTimeShiftDisableRequested,
            object: capabilityNotificationObject
        ) { [weak self] _ in
            Task { await self?.handleLifecycle(.disabled) }
        }
        observe(
            .haloCapabilitiesDidChange,
            object: capabilityNotificationObject
        ) { [weak self] _ in
            Task { await self?.reconcileCapability() }
        }
        observe(Notification.Name("AudioDeviceChanged")) { [weak self] _ in
            Task { await self?.handleLifecycle(.deviceChange) }
        }
        observe(NSApplication.willTerminateNotification) { [weak self] _ in
            self?.handleTerminationImmediately()
        }
        observe(NSApplication.didBecomeActiveNotification) { [weak self] _ in
            guard let self else { return }
            Task {
                if self.permissionProvider() {
                    await self.restoreAvailabilityIfSafe()
                } else {
                    await self.handleLifecycle(.permissionLoss)
                }
            }
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.willSleepNotification, center: workspaceCenter) { [weak self] _ in
            Task { await self?.handleLifecycle(.sleep) }
        }
        observe(NSWorkspace.didWakeNotification, center: workspaceCenter) { [weak self] _ in
            Task { await self?.restoreAfterWake() }
        }
        observe(NSWorkspace.sessionDidResignActiveNotification, center: workspaceCenter) { [weak self] _ in
            Task { await self?.handleLifecycle(.lock) }
        }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, center: workspaceCenter) { [weak self] _ in
            Task { await self?.restoreAfterUnlock() }
        }

        let distributedCenter = DistributedNotificationCenter.default()
        observe(
            Notification.Name("com.apple.screenIsLocked"),
            center: distributedCenter
        ) { [weak self] _ in
            Task { await self?.handleLifecycle(.lock) }
        }
        observe(
            Notification.Name("com.apple.screenIsUnlocked"),
            center: distributedCenter
        ) { [weak self] _ in
            Task { await self?.restoreAfterUnlock() }
        }
    }

    private func observe(
        _ name: Notification.Name,
        center: NotificationCenter = .default,
        object: Any? = nil,
        handler: @escaping @MainActor (Notification) -> Void
    ) {
        let observer = center.addObserver(forName: name, object: object, queue: .main) { notification in
            MainActor.assumeIsolated {
                handler(notification)
            }
        }
        notificationObservers.append((center, observer))
    }

    private func reconcileArmedWatchdog() {
        guard case .armed(let sessionID, _) = state else {
            armedWatchdogTask?.cancel()
            armedWatchdogTask = nil
            if !state.hasActiveAudioCapture {
                armedDeviceID = nil
            }
            return
        }
        guard armedWatchdogTask == nil else { return }

        armedWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard let self,
                    case .armed(let activeSessionID, _) = self.state,
                    activeSessionID == sessionID
                else {
                    return
                }
                guard self.permissionProvider() else {
                    await self.handleLifecycle(.permissionLoss)
                    return
                }
                guard let armedDeviceID = self.armedDeviceID,
                    self.deviceIDProvider() == armedDeviceID
                else {
                    await self.handleLifecycle(.deviceChange)
                    return
                }
                self.publish(
                    self.stateMachine.handle(
                        .bufferedSamples(
                            sessionID: sessionID,
                            totalSampleCount: self.audioSource.bufferedSampleCount
                        )
                    )
                )
            }
        }
    }

    private func handleTerminationImmediately() {
        guard !isTerminating else { return }
        isTerminating = true
        armedWatchdogTask?.cancel()
        armedWatchdogTask = nil
        activeSnapshot?.zeroize()
        activeSnapshot = nil
        armedDeviceID = nil
        audioSource.shutdownImmediately()
        activeLease = nil
        publish(stateMachine.handle(.lifecycle(.termination)))
        record(action: .lifecycleClear, outcome: .lifecycleInvalidated)
    }
}
