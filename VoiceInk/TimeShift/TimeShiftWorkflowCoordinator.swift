import AVFoundation
import Combine
import CoreAudio
import Foundation

/// A resolved Time-Shift route. The concrete model is kept on the main actor
/// and is never substituted after strict resolution succeeds.
@MainActor
struct TimeShiftResolvedTranscriptionRoute {
    let model: any TranscriptionModel
    let route: InMemoryTranscriptionModelRoute

    init(model: any TranscriptionModel) {
        self.model = model
        route = InMemoryTranscriptionModelRoute(model: model)
    }
}

@MainActor
protocol TimeShiftExactRouteProviding: AnyObject {
    func resolveExactRoute(
        for purpose: TimeShiftRouteResolutionPurpose
    ) throws -> TimeShiftResolvedTranscriptionRoute
}

enum TimeShiftRouteResolutionPurpose: Equatable, Sendable {
    /// Uses only the global selected transcription model. It must not inspect a
    /// destination, Mode, clipboard, screen, selected text, or History.
    case arming

    /// Runs only after the one-shot snapshot exists and may resolve the Mode
    /// that will be frozen into the forced-review product pipeline.
    case capture
}

/// Resolves only the explicitly selected model. Unlike the normal recording
/// runtime resolver, this boundary has no first-model fallback.
@MainActor
final class StrictTimeShiftRouteProvider: TimeShiftExactRouteProviding {
    typealias SelectedModelNameProvider = @MainActor () -> String?
    typealias AvailableModelsProvider = @MainActor () -> [any TranscriptionModel]

    private let selectedModelNameProvider: SelectedModelNameProvider
    private let captureSelectedModelNameProvider: SelectedModelNameProvider
    private let availableModelsProvider: AvailableModelsProvider

    init(
        selectedModelNameProvider: @escaping SelectedModelNameProvider,
        captureSelectedModelNameProvider: SelectedModelNameProvider? = nil,
        availableModelsProvider: @escaping AvailableModelsProvider
    ) {
        self.selectedModelNameProvider = selectedModelNameProvider
        self.captureSelectedModelNameProvider = captureSelectedModelNameProvider
            ?? selectedModelNameProvider
        self.availableModelsProvider = availableModelsProvider
    }

    func resolveExactRoute(
        for purpose: TimeShiftRouteResolutionPurpose
    ) throws -> TimeShiftResolvedTranscriptionRoute {
        let selectedModelName: String?
        switch purpose {
        case .arming:
            selectedModelName = selectedModelNameProvider()
        case .capture:
            selectedModelName = captureSelectedModelNameProvider()
        }
        let resolved = try StrictTranscriptionModelRouteResolver.resolve(
            selectedModelName: selectedModelName,
            availableModels: availableModelsProvider()
        )
        return TimeShiftResolvedTranscriptionRoute(model: resolved.model)
    }
}

enum TimeShiftWorkflowDeliveryRequirement: Equatable, Sendable {
    /// Time-Shift is recall, not ambient dictation. Every capture must become a
    /// Halo review even when the resolved Mode normally pastes immediately.
    case forcedReview
}

/// The only value allowed to cross from memory capture into the product
/// pipeline. Destination, Mode, context, History, and network work are
/// intentionally absent and must be resolved by the injected processor after
/// this request is delivered.
@MainActor
struct TimeShiftWorkflowRequest {
    let requestID: UUID
    let source: TranscriptionAudioSource
    let model: any TranscriptionModel
    let route: InMemoryTranscriptionModelRoute
    let metrics: TimeShiftCaptureMetrics
    let deliveryRequirement: TimeShiftWorkflowDeliveryRequirement

    fileprivate init(
        ticket: TimeShiftCaptureTicket,
        resolvedRoute: TimeShiftResolvedTranscriptionRoute
    ) {
        requestID = ticket.requestID
        source = .pcm16(ticket.snapshot)
        model = resolvedRoute.model
        route = resolvedRoute.route
        metrics = ticket.metrics
        deliveryRequirement = .forcedReview
    }
}

@MainActor
protocol TimeShiftWorkflowProcessing: AnyObject {
    func process(_ request: TimeShiftWorkflowRequest) async throws
}

/// Lightweight adapter used by VoiceInkEngine to keep its post-capture work in
/// the engine without making the coordinator depend on Mode, destination, or
/// History types.
@MainActor
final class ClosureTimeShiftWorkflowProcessor: TimeShiftWorkflowProcessing {
    typealias Process = @MainActor (TimeShiftWorkflowRequest) async throws -> Void

    private let processClosure: Process

    init(process: @escaping Process) {
        processClosure = process
    }

    func process(_ request: TimeShiftWorkflowRequest) async throws {
        try await processClosure(request)
    }
}

enum TimeShiftWorkflowFailure: Equatable, Sendable {
    case unsupportedModel
    case cancelled
    case transcription(InMemoryTranscriptionError)
}

/// Privacy-safe workflow state. It deliberately omits request/session IDs,
/// model/provider names, destination data, text, and audio bytes.
enum TimeShiftWorkflowStatus: Equatable, Sendable {
    case disabled
    case unavailable(TimeShiftUnavailableReason)
    case ready
    case arming
    case armed(bufferedDuration: TimeInterval)
    case capturing
    case processing
    case failed(TimeShiftWorkflowFailure)
}

enum TimeShiftWorkflowCaptureOutcome: Equatable, Sendable {
    case completed
    case notArmed
    case failed(TimeShiftWorkflowFailure)
}

/// Orchestrates the one-shot boundary between Time-Shift audio capture and the
/// VoiceInk product pipeline. Merely arming never invokes the processor, so it
/// cannot inspect a destination, collect context, create History, or perform a
/// transcription request.
@MainActor
final class TimeShiftWorkflowCoordinator: ObservableObject {
    @Published private(set) var status: TimeShiftWorkflowStatus

    let captureController: TimeShiftCaptureController

    private let capabilityEnabledProvider: TimeShiftCaptureController.CapabilityEnabledProvider
    private let routeProvider: any TimeShiftExactRouteProviding
    private let processor: any TimeShiftWorkflowProcessing

    private var stateObservation: AnyCancellable?
    private var processingTask: Task<Void, Error>?
    private var activeProcessingRequestID: UUID?
    private var latestFailure: TimeShiftWorkflowFailure?

    init(
        routeProvider: any TimeShiftExactRouteProviding,
        processor: any TimeShiftWorkflowProcessing,
        audioSource: any TimeShiftAudioSourcing = TimeShiftCoreAudioSource(),
        leaseCoordinator: AudioCaptureLeaseCoordinator,
        metricRecorder: (any TimeShiftMetricRecording)? = nil,
        capabilityEnabledProvider: @escaping TimeShiftCaptureController.CapabilityEnabledProvider = {
            UserDefaults.standard.bool(forKey: HaloCapabilitySettingsKeys.timeShiftEnabled)
        },
        permissionProvider: @escaping TimeShiftCaptureController.PermissionProvider = {
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        },
        deviceIDProvider: @escaping TimeShiftCaptureController.DeviceIDProvider = {
            AudioDeviceManager.shared.getCurrentDevice()
        },
        capabilityNotificationObject: AnyObject? = nil,
        observeSystemLifecycle: Bool = true
    ) {
        self.capabilityEnabledProvider = capabilityEnabledProvider
        self.routeProvider = routeProvider
        self.processor = processor

        captureController = TimeShiftCaptureController(
            audioSource: audioSource,
            leaseCoordinator: leaseCoordinator,
            metricRecorder: metricRecorder,
            capabilityEnabledProvider: capabilityEnabledProvider,
            permissionProvider: permissionProvider,
            deviceIDProvider: deviceIDProvider,
            modelSupportProvider: {
                (try? routeProvider.resolveExactRoute(for: .arming)) != nil
            },
            capabilityNotificationObject: capabilityNotificationObject,
            observeSystemLifecycle: observeSystemLifecycle
        )
        status = Self.projectStatus(
            capabilityEnabled: capabilityEnabledProvider(),
            captureState: captureController.state,
            latestFailure: nil
        )

        stateObservation = captureController.$state
            .dropFirst()
            .sink { [weak self] state in
                self?.captureStateDidChange(state)
            }
    }

    var presentation: TimeShiftStatusPresentation {
        captureController.presentation
    }

    func toggleArming() async {
        if case .failed = status {
            latestFailure = nil
        }
        await captureController.toggleArming()
        refreshStatus()
    }

    func arm() async {
        latestFailure = nil
        await captureController.arm()
        refreshStatus()
    }

    func disarm() async {
        await cancelActiveProcessing(markCancelled: false)
        await captureController.disarm()
        latestFailure = nil
        refreshStatus()
    }

    /// Captures once, re-resolves the exact supported route, then invokes the
    /// injected post-capture processor. The capture controller releases the
    /// microphone before the processor can inspect any product context.
    @discardableResult
    func capture() async -> TimeShiftWorkflowCaptureOutcome {
        guard processingTask == nil else {
            return .failed(.cancelled)
        }
        guard let ticket = await captureController.capture() else {
            refreshStatus()
            return .notArmed
        }

        let resolvedRoute: TimeShiftResolvedTranscriptionRoute
        do {
            resolvedRoute = try routeProvider.resolveExactRoute(for: .capture)
        } catch {
            let failure = TimeShiftWorkflowFailure.unsupportedModel
            await completeProcessing(
                requestID: ticket.requestID,
                succeeded: false,
                failure: failure
            )
            return .failed(failure)
        }

        let request = TimeShiftWorkflowRequest(
            ticket: ticket,
            resolvedRoute: resolvedRoute
        )
        activeProcessingRequestID = ticket.requestID
        let task = Task { @MainActor [processor] in
            try Task.checkCancellation()
            try await processor.process(request)
            try Task.checkCancellation()
        }
        processingTask = task

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard activeProcessingRequestID == ticket.requestID else {
                return .failed(.cancelled)
            }
            await completeProcessing(
                requestID: ticket.requestID,
                succeeded: true,
                failure: nil
            )
            return .completed
        } catch {
            guard activeProcessingRequestID == ticket.requestID else {
                return .failed(.cancelled)
            }
            let failure = Self.sanitize(error)
            await completeProcessing(
                requestID: ticket.requestID,
                succeeded: false,
                failure: failure
            )
            return .failed(failure)
        }
    }

    func cancelProcessing() async {
        await cancelActiveProcessing(markCancelled: true)
    }

    func reconcileCapability() async {
        if !capabilityEnabledProvider() {
            await cancelActiveProcessing(markCancelled: false)
        }
        latestFailure = nil
        await captureController.reconcileCapability()
        refreshStatus()
    }

    /// Call when the selected or usable transcription-model set changes.
    /// Unsupported changes clear an armed ring buffer immediately; supported
    /// changes restore the ready state only from the matching unavailable state.
    func reconcileModelAvailability() async {
        latestFailure = nil
        await captureController.reconcileModelSupport()
        refreshStatus()
    }

    func handleLifecycle(_ event: TimeShiftLifecycleEvent) async {
        await cancelActiveProcessing(markCancelled: false)
        latestFailure = nil
        await captureController.handleLifecycle(event)
        refreshStatus()
    }

    func restoreAfterWake() async {
        latestFailure = nil
        await captureController.restoreAfterWake()
        refreshStatus()
    }

    func restoreAfterUnlock() async {
        latestFailure = nil
        await captureController.restoreAfterUnlock()
        refreshStatus()
    }

    private func completeProcessing(
        requestID: UUID,
        succeeded: Bool,
        failure: TimeShiftWorkflowFailure?
    ) async {
        if activeProcessingRequestID == requestID || activeProcessingRequestID == nil {
            processingTask = nil
            activeProcessingRequestID = nil
        }
        latestFailure = failure
        if succeeded {
            await captureController.finishProcessing(requestID: requestID)
        } else {
            await captureController.failProcessing(requestID: requestID)
        }
        refreshStatus()
    }

    private func cancelActiveProcessing(markCancelled: Bool) async {
        guard let requestID = activeProcessingRequestID else { return }
        processingTask?.cancel()
        processingTask = nil
        activeProcessingRequestID = nil
        latestFailure = markCancelled ? .cancelled : nil
        await captureController.failProcessing(requestID: requestID)
        refreshStatus()
    }

    private func captureStateDidChange(_ state: TimeShiftCaptureState) {
        if let requestID = activeProcessingRequestID,
            case .processing(let stateRequestID, _) = state,
            requestID == stateRequestID
        {
            refreshStatus(captureState: state)
            return
        }

        if activeProcessingRequestID != nil {
            processingTask?.cancel()
            processingTask = nil
            activeProcessingRequestID = nil
        }
        // `@Published` emits from `willSet`, so reading captureController.state
        // here would project the previous value. Use the emitted state to keep
        // externally driven transitions (for example microphone preemption)
        // live and accurate.
        refreshStatus(captureState: state)
    }

    private func refreshStatus(captureState: TimeShiftCaptureState? = nil) {
        status = Self.projectStatus(
            capabilityEnabled: capabilityEnabledProvider(),
            captureState: captureState ?? captureController.state,
            latestFailure: latestFailure
        )
    }

    private static func projectStatus(
        capabilityEnabled: Bool,
        captureState: TimeShiftCaptureState,
        latestFailure: TimeShiftWorkflowFailure?
    ) -> TimeShiftWorkflowStatus {
        if let latestFailure, captureState == .unarmed {
            return .failed(latestFailure)
        }
        guard capabilityEnabled else { return .disabled }

        switch captureState {
        case .unavailable(let reason):
            return reason == .disabled ? .disabled : .unavailable(reason)
        case .unarmed:
            return .ready
        case .arming:
            return .arming
        case .armed(_, let bufferedSampleCount):
            return .armed(
                bufferedDuration: TimeInterval(bufferedSampleCount)
                    / TimeInterval(PCM16Snapshot.sampleRate)
            )
        case .capturing:
            return .capturing
        case .processing:
            return .processing
        }
    }

    private static func sanitize(_ error: Error) -> TimeShiftWorkflowFailure {
        let sanitized = InMemoryTranscriptionError.sanitized(error)
        if sanitized == .cancelled {
            return .cancelled
        }
        return .transcription(sanitized)
    }
}
