import AppKit
import Combine
import SwiftUI

enum HaloWindowNotificationPublisher {
    static func userDefaultsChanges(
        center: NotificationCenter = .default,
        defaults: UserDefaults = .standard
    ) -> AnyPublisher<Void, Never> {
        center.publisher(
            for: UserDefaults.didChangeNotification,
            object: defaults
        )
        .receive(on: DispatchQueue.main)
        .map { _ in () }
        .eraseToAnyPublisher()
    }
}

enum HaloPanelMetrics {
    /// The content surface is deliberately smaller than the transparent window
    /// that hosts it. The margin exists only for the close rounded shadow, so
    /// it remains visually absent against both light and dark destinations.
    struct VisualEffectInsets: Equatable, Sendable {
        let top: CGFloat
        let leading: CGFloat
        let bottom: CGFloat
        let trailing: CGFloat
    }

    static let compact = CGSize(width: 240, height: 48)
    static let liveTranscript = CGSize(width: 360, height: 124)
    static let enhancing = CGSize(width: 320, height: 72)
    static let review = CGSize(width: 500, height: 380)
    static let focusRecovery = CGSize(width: 460, height: 82)
    static let confirmation = CGSize(width: 132, height: 44)
    static let visualEffectInsets = VisualEffectInsets(
        top: 8,
        leading: 10,
        bottom: 14,
        trailing: 10
    )

    static func size(
        for phase: HaloPresentationPhase,
        hasVisiblePartialTranscript: Bool
    ) -> CGSize {
        switch phase {
        case .listening:
            return hasVisiblePartialTranscript ? liveTranscript : compact
        case .transcribing:
            return compact
        case .enhancing:
            return enhancing
        case .reviewing:
            return review
        case .confirmed:
            return confirmation
        case .noSpeechDetected:
            return compact
        }
    }

    static func windowSize(for surfaceSize: CGSize) -> CGSize {
        CGSize(
            width: surfaceSize.width + visualEffectInsets.leading + visualEffectInsets.trailing,
            height: surfaceSize.height + visualEffectInsets.top + visualEffectInsets.bottom
        )
    }

    /// Converts the placement of the visible Halo surface into the transparent
    /// NSPanel frame that also contains its glow and shadow.
    static func windowFrame(forSurfaceFrame surfaceFrame: CGRect) -> CGRect {
        CGRect(
            x: surfaceFrame.minX - visualEffectInsets.leading,
            y: surfaceFrame.minY - visualEffectInsets.bottom,
            width: surfaceFrame.width + visualEffectInsets.leading + visualEffectInsets.trailing,
            height: surfaceFrame.height + visualEffectInsets.top + visualEffectInsets.bottom
        )
    }
}

@MainActor
final class HaloWindowManager {
    private var windowController: NSWindowController?
    private var panel: HaloRecorderPanel?
    private var screenObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var anchorResolutionTask: Task<Void, Never>?
    private var caretTracker: HaloContinuousCaretTracker?
    private var anchorSession = HaloAnchorSessionState()
    private var destinationSnapshot = HaloFocusedDestinationSnapshot(
        processID: nil,
        applicationName: nil,
        bundleIdentifier: nil,
        focusedElementIdentity: nil
    )
    private var stablePlacementSide: HaloPanelPlacementSide?
    private var isShowRequested = false
    private var hasPartialTranscript = false
    private var isShowingPasteConfirmation = false

    private let engine: VoiceInkEngine
    private let recorder: Recorder
    private let anchorResolver: HaloCaretAnchorResolver
    let presentation = HaloPresentationModel()

    var capturedAnchor: HaloCaretAnchor? { anchorSession.anchor }
    var capturedDestinationSnapshot: HaloFocusedDestinationSnapshot {
        guard let capturedAnchor else { return destinationSnapshot }
        return HaloFocusedDestinationSnapshot(
            processID: capturedAnchor.destinationPID,
            applicationName: capturedAnchor.applicationName,
            bundleIdentifier: capturedAnchor.bundleIdentifier,
            focusedElementIdentity: capturedAnchor.focusedElementIdentity,
            focusedElementStableIdentity: capturedAnchor.focusedElementStableIdentity
        )
    }

    init(
        engine: VoiceInkEngine,
        recorder: Recorder,
        anchorResolver: HaloCaretAnchorResolver = HaloCaretAnchorResolver()
    ) {
        self.engine = engine
        self.recorder = recorder
        self.anchorResolver = anchorResolver
        observePresentationInputs()
        observeDisplayConfiguration()
    }

    /// Starts one immutable destination snapshot for the upcoming recording.
    /// RecorderUIManager calls this before it orders either Halo or Mini onscreen,
    /// so a later trigger-word switch can still reuse the original caret.
    func beginRecordingSession() {
        stopCaretTracking()
        anchorResolutionTask?.cancel()
        anchorResolutionTask = nil
        hasPartialTranscript = false
        isShowingPasteConfirmation = false
        anchorSession.begin()
        stablePlacementSide = nil
        presentation.reset()
        presentation.setPhase(.resolve(recordingState: engine.recordingState))
        captureAnchorIfNeeded()
    }

    func show() {
        isShowRequested = true
        reconcileCaretTracking()

        if capturedAnchor != nil {
            initializeWindowIfNeeded()
            positionAndShowPanel(animated: false)
            return
        }

        captureAnchorIfNeeded()
    }

    private func captureAnchorIfNeeded() {
        guard capturedAnchor == nil, anchorResolutionTask == nil else { return }

        // Snapshot the destination before VoiceInk orders any of its own windows.
        let destination = anchorResolver.destinationSnapshot()
        destinationSnapshot = destination
        let screens = HaloScreenGeometry.currentScreens()
        let pointerLocation = NSEvent.mouseLocation
        let pointerRect = CGRect(origin: pointerLocation, size: CGSize(width: 1, height: 1))
        let pointerScreenID = HaloPanelPositioner.screen(for: pointerRect, in: screens)?.id
        let currentSessionID = anchorSession.id
        presentation.setCapturedApplication(destination.applicationName)
        updateModeMetadata()

        anchorResolutionTask?.cancel()
        anchorResolutionTask = Task { [weak self] in
            guard let self else { return }
            let anchor = await anchorResolver.resolve(
                destinationPID: destination.processID,
                applicationName: destination.applicationName,
                screens: screens,
                preferredFallbackScreenID: pointerScreenID,
                fallbackPointerLocation: pointerLocation
            )

            guard !Task.isCancelled,
                self.anchorSession.id == currentSessionID
            else {
                return
            }

            self.anchorSession.accept(
                anchor,
                for: currentSessionID,
                screens: HaloScreenGeometry.currentScreens()
            )
            self.updateResolvedDestinationMetadata()
            self.prepareStablePlacementSideIfNeeded()
            self.reconcileCaretTracking()
            if self.isShowRequested {
                self.initializeWindowIfNeeded()
                self.positionAndShowPanel(animated: false)
            }

            guard anchor.quality.shouldRetry else {
                self.anchorResolutionTask = nil
                return
            }

            do {
                try await Task.sleep(for: .seconds(HaloCaretAnchorResolver.retryDelay))
            } catch {
                return
            }
            guard !Task.isCancelled, self.anchorSession.id == currentSessionID else { return }

            let retry = await self.anchorResolver.resolve(
                destinationPID: anchor.destinationPID,
                applicationName: anchor.applicationName,
                screens: HaloScreenGeometry.currentScreens(),
                preferredFallbackScreenID: anchor.screenID ?? pointerScreenID,
                fallbackPointerLocation: pointerLocation,
                allowSystemFocusedDestination: false,
                timeout: HaloCaretAnchorResolver.retryTimeout
            )
            guard !Task.isCancelled,
                self.anchorSession.id == currentSessionID,
                retry.isHigherQuality(than: self.capturedAnchor)
            else {
                self.anchorResolutionTask = nil
                return
            }

            self.anchorSession.accept(
                retry,
                for: currentSessionID,
                screens: HaloScreenGeometry.currentScreens()
            )
            self.updateResolvedDestinationMetadata()
            self.prepareStablePlacementSideIfNeeded()
            self.reconcileCaretTracking()
            if self.isShowRequested {
                self.positionAndShowPanel(animated: true)
            }
            self.anchorResolutionTask = nil
        }
    }

    func hide(preservingSession: Bool = false) {
        isShowRequested = false
        panel?.setManualEditing(false)
        panel?.endReviewInteraction()
        panel?.orderOut(nil)

        if preservingSession {
            caretTracker?.pause(for: .styleChange)
        } else {
            endRecordingSession()
        }
    }

    func destroyWindow() {
        hide(preservingSession: false)
        windowController?.close()
        windowController = nil
        panel = nil
    }

    func endRecordingSession() {
        stopCaretTracking()
        anchorResolutionTask?.cancel()
        anchorResolutionTask = nil
        hasPartialTranscript = false
        isShowingPasteConfirmation = false
        panel?.setManualEditing(false)
        panel?.endReviewInteraction()
        anchorSession.end()
        stablePlacementSide = nil
        destinationSnapshot = HaloFocusedDestinationSnapshot(
            processID: nil,
            applicationName: nil,
            bundleIdentifier: nil,
            focusedElementIdentity: nil
        )
        presentation.reset()
    }

    func updateMetadata(_ metadata: HaloPresentationMetadata) {
        presentation.updateMetadata(metadata)
    }

    func presentReview(
        rawText: String,
        finalText: String,
        modeName: String?,
        providerLabel: String?,
        connectionLabel: String?,
        modelLabel: String?,
        enhancementWarning: String?,
        deliveryReviewReason: String?
    ) {
        isShowingPasteConfirmation = false
        presentation.updateFocusRecovery(isRefocusing: false)
        // Start in the safe, click-through awaiting-regions state before the
        // review view is materialized and its panel grows to final size.
        panel?.beginReviewInteraction()
        presentation.presentReview(
            rawText: rawText,
            finalText: finalText,
            modeName: modeName,
            providerLabel: providerLabel,
            connectionLabel: connectionLabel,
            modelLabel: modelLabel,
            enhancementWarning: enhancementWarning,
            deliveryReviewReason: deliveryReviewReason
        )
        presentation.updateReviewStatus(
            feedback: engine.pasteReviewFeedback,
            secondsRemaining: engine.pasteReviewSecondsRemaining,
            isDelivering: engine.recordingState == .busy
        )
        resizeVisiblePanel(animated: true)
    }

    func clearReview() {
        panel?.setManualEditing(false)
        panel?.endReviewInteraction()
        presentation.updateFocusRecovery(isRefocusing: false)
        presentation.clearReview()
    }

    func beginFocusRecovery() {
        guard presentation.phase == .reviewing else { return }
        panel?.setManualEditing(false)
        // Continue and Cancel must remain reachable even when the global
        // keyboard event tap is unavailable. The panel stays nonactivating;
        // only its visible surface absorbs clicks and its transparent margin
        // continues to pass them through.
        panel?.beginReviewInteraction()
        presentation.updateFocusRecovery(isRefocusing: true)
        resizeVisiblePanel(animated: true)
    }

    func endFocusRecovery() {
        guard presentation.phase == .reviewing else { return }
        presentation.updateFocusRecovery(isRefocusing: false)
        panel?.beginReviewInteraction()
        resizeVisiblePanel(animated: true)
    }

    func presentPasteConfirmation() {
        isShowingPasteConfirmation = true
        isShowRequested = true
        panel?.endReviewInteraction()
        presentation.presentPasteConfirmation()
        initializeWindowIfNeeded()
        positionAndShowPanel(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func presentNoSpeechDetected() {
        isShowingPasteConfirmation = false
        isShowRequested = true
        panel?.endReviewInteraction()
        presentation.presentNoSpeechDetected()
        initializeWindowIfNeeded()
        positionAndShowPanel(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func initializeWindowIfNeeded() {
        guard panel == nil else { return }

        let initialSize = panelSize
        let initialFrame = placement(for: initialSize)
            .map { HaloPanelMetrics.windowFrame(forSurfaceFrame: $0.frame) }
            ?? CGRect(origin: .zero, size: HaloPanelMetrics.windowSize(for: initialSize))
        let newPanel = HaloRecorderPanel(contentRect: initialFrame)
        let content = HaloRecorderView(
            stateProvider: engine,
            recorder: recorder,
            presentation: presentation,
            onApply: { [weak engine] in
                Task { @MainActor in
                    await engine?.approvePendingPasteReview()
                }
            },
            onCancel: { [weak engine] in
                Task { @MainActor in
                    if engine?.cancelHaloVoiceRefinementIfActive() == true {
                        return
                    }
                    if engine?.cancelHaloRefinementIfActive() == true {
                        return
                    }
                    await engine?.cancelPendingPasteReview()
                }
            },
            onCopy: { [weak engine] in
                engine?.copyPendingPasteReview()
            },
            onRetry: { [weak engine] in
                Task { @MainActor in
                    await engine?.retryPendingPasteReview()
                }
            },
            onRefocus: { [weak engine] in
                _ = engine?.beginPasteReviewFocusRecovery()
            },
            onUseOriginal: { [weak engine] in
                _ = engine?.useOriginalHaloReview()
            },
            onBeginManualEdit: { [weak engine] in
                _ = engine?.beginHaloManualEdit()
            },
            onUpdateManualEdit: { [weak engine] text in
                _ = engine?.updateHaloManualEdit(text)
            },
            onSaveManualEdit: { [weak engine] in
                _ = engine?.saveHaloManualEdit()
            },
            onCancelManualEdit: { [weak engine] in
                _ = engine?.cancelHaloManualEditIfActive()
            },
            onSelectReviewLens: { [weak engine] lens in
                engine?.selectHaloReviewLens(lens)
            },
            onMoveReviewRevision: { [weak engine] offset in
                engine?.moveHaloReviewRevision(by: offset)
            },
            onRefine: { [weak engine] action in
                _ = engine?.beginHaloRefinement(action)
            },
            onAnotherTake: { [weak engine] in
                _ = engine?.beginHaloAnotherTake()
            },
            onToggleVoiceRefinement: { [weak engine] in
                _ = engine?.toggleHaloVoiceRefinementCapture()
            },
            onBeginTypedInstruction: { [weak engine] in
                _ = engine?.beginHaloTypedInstruction()
            },
            onEditInstruction: { [weak engine] in
                _ = engine?.editHaloInstructionDraft()
            },
            onUpdateInstruction: { [weak engine] requestID, text in
                _ = engine?.updateHaloInstructionDraft(
                    requestID: requestID,
                    text: text
                )
            },
            onSubmitInstruction: { [weak engine] in
                _ = engine?.submitHaloInstructionDraft()
            },
            onCancelInstruction: { [weak engine] in
                _ = engine?.cancelHaloVoiceRefinementIfActive()
            },
            onConfirmVoiceCommand: { [weak engine] in
                Task { @MainActor in
                    _ = await engine?.confirmHaloVoiceCommandIfActive()
                }
            },
            onCancelVoiceCommand: { [weak engine] in
                _ = engine?.cancelHaloVoiceCommandConfirmationIfActive()
            },
            onReviewInteractiveRegionsChange: { [weak newPanel] regions in
                newPanel?.updateReviewInteractiveRegions(regions)
            }
        )
        let hostingController = NSHostingController(rootView: content)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        newPanel.contentViewController = hostingController

        panel = newPanel
        windowController = NSWindowController(window: newPanel)
    }

    private func observePresentationInputs() {
        engine.$recordingState
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                guard !self.isShowingPasteConfirmation else { return }
                let phase: HaloPresentationPhase = self.engine.pendingPasteReview == nil
                    ? .resolve(recordingState: state)
                    : .reviewing
                self.presentation.setPhase(phase)
                self.presentation.updateReviewStatus(
                    feedback: self.engine.pasteReviewFeedback,
                    secondsRemaining: self.engine.pasteReviewSecondsRemaining,
                    isDelivering: state == .busy && self.engine.pendingPasteReview != nil
                )
                if state == .busy && self.engine.pendingPasteReview != nil {
                    self.caretTracker?.pause(for: .delivery)
                } else {
                    self.caretTracker?.resume(after: .delivery)
                }
                if phase != .reviewing {
                    self.panel?.endReviewInteraction()
                }
                self.updateModeMetadata()
                self.resizeVisiblePanel(animated: true)
            }
            .store(in: &cancellables)

        engine.$haloSessionDeliveryOverride
            .removeDuplicates()
            .sink { [weak self] deliveryOverride in
                self?.presentation.updateDeliveryOverride(deliveryOverride)
            }
            .store(in: &cancellables)

        engine.$haloReviewState
            .sink { [weak self] reviewState in
                guard let self else { return }
                self.presentation.updateReviewState(reviewState)
                let isEditingInstruction: Bool
                if case .editingInstruction = reviewState?.voiceRefinementPhase {
                    isEditingInstruction = true
                } else {
                    isEditingInstruction = false
                }
                self.panel?.setManualEditing(
                    reviewState?.isEditingManually == true || isEditingInstruction
                )
                if reviewState?.isEditingManually == true || isEditingInstruction {
                    self.caretTracker?.pause(for: .textEditing)
                } else {
                    self.caretTracker?.resume(after: .textEditing)
                }
                if reviewState != nil {
                    self.panel?.beginReviewInteraction()
                }
            }
            .store(in: &cancellables)

        engine.$haloCapabilitySnapshot
            .removeDuplicates()
            .sink { [weak self] snapshot in
                self?.presentation.updateCapabilities(snapshot)
                self?.reconcileCaretTracking(snapshot: snapshot)
            }
            .store(in: &cancellables)

        engine.$haloVoiceCommandConfirmation
            .removeDuplicates()
            .sink { [weak self] confirmation in
                self?.presentation.updateVoiceCommandConfirmation(confirmation)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            engine.$isHaloVoiceRefinementReady,
            engine.$haloVoiceInstructionAudioMeter,
            engine.$haloVoiceInstructionPartialTranscript
        )
        .sink { [weak self] isReady, audioMeter, partialTranscript in
            self?.presentation.updateVoiceRefinementPresentation(
                isReady: isReady,
                audioMeter: audioMeter,
                partialTranscript: partialTranscript
            )
        }
        .store(in: &cancellables)

        Publishers.CombineLatest(
            engine.$pasteReviewFeedback,
            engine.$pasteReviewSecondsRemaining
        )
        .sink { [weak self] feedback, secondsRemaining in
            guard let self else { return }
            self.presentation.updateReviewStatus(
                feedback: feedback,
                secondsRemaining: secondsRemaining,
                isDelivering: self.engine.recordingState == .busy
                    && self.engine.pendingPasteReview != nil
            )
        }
        .store(in: &cancellables)

        engine.$partialTranscript
            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .removeDuplicates()
            .sink { [weak self] hasPartialTranscript in
                guard let self else { return }

                // `@Published` delivers from willSet. Use the emitted value instead
                // of rereading `engine.partialTranscript`, which can still contain
                // the previous (usually empty) value on the first partial result.
                self.hasPartialTranscript = hasPartialTranscript
                self.resizeVisiblePanel(animated: true)
            }
            .store(in: &cancellables)

        HaloWindowNotificationPublisher.userDefaultsChanges()
            .sink { [weak self] _ in
                self?.resizeVisiblePanel(animated: true)
            }
            .store(in: &cancellables)
    }

    private func observeDisplayConfiguration() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDisplayConfigurationChange()
            }
        }
    }

    private func handleDisplayConfigurationChange() {
        let screens = HaloScreenGeometry.currentScreens()
        anchorSession.reconcileDisplays(screens)
        stablePlacementSide = nil
        prepareStablePlacementSideIfNeeded()
        if isShowRequested {
            positionAndShowPanel(animated: true)
        }
    }

    private func positionAndShowPanel(animated: Bool) {
        guard isShowRequested, let panel, let placement = placement(for: panelSize) else {
            return
        }
        let windowFrame = HaloPanelMetrics.windowFrame(forSurfaceFrame: placement.frame)

        if panel.isVisible {
            let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            panel.update(frame: windowFrame, animated: shouldAnimate)
        } else {
            panel.show(frame: windowFrame)
        }
    }

    private func resizeVisiblePanel(animated: Bool) {
        guard isShowRequested, panel != nil else { return }
        positionAndShowPanel(animated: animated)
    }

    private func placement(for size: CGSize) -> HaloPanelPlacement? {
        let screens = HaloScreenGeometry.currentScreens()
        return HaloPanelPositioner.placement(
            panelSize: size,
            anchorRect: capturedAnchor?.appKitRect,
            preferredScreenID: capturedAnchor?.screenID,
            preferredSide: stablePlacementSide,
            screens: screens
        )
    }

    private func prepareStablePlacementSideIfNeeded() {
        guard stablePlacementSide == nil else { return }
        let screens = HaloScreenGeometry.currentScreens()
        stablePlacementSide = HaloPanelPositioner.stableSide(
            anchorRect: capturedAnchor?.appKitRect,
            preferredScreenID: capturedAnchor?.screenID,
            maximumPanelHeight: HaloPanelMetrics.review.height,
            screens: screens
        )
    }

    private func updateResolvedDestinationMetadata() {
        guard let capturedAnchor else { return }
        destinationSnapshot = capturedDestinationSnapshot
        presentation.setCapturedApplication(capturedAnchor.applicationName)
    }

    private func reconcileCaretTracking(
        snapshot: HaloCapabilitySnapshot? = nil
    ) {
        let snapshot = snapshot ?? engine.haloCapabilitySnapshot
        guard snapshot.positionBehavior == .followOriginalCaret else {
            // Keep the last accepted anchor exactly where it is. Only the
            // tracker and its ephemeral AX observers are discarded.
            stopCaretTracking()
            return
        }

        if let tracker = caretTracker {
            tracker.resume(after: .styleChange)
            return
        }

        guard let initialAnchor = capturedAnchor else { return }
        let expectedDestination = capturedDestinationSnapshot
        guard expectedDestination.processID != nil else { return }
        let sessionID = anchorSession.id

        let tracker = HaloContinuousCaretTracker(
            expectedDestination: expectedDestination,
            initialAnchor: initialAnchor,
            resolver: DefaultHaloCaretTrackingResolver(
                anchorResolver: anchorResolver
            ),
            notifier: SystemHaloCaretTrackingNotifier(),
            onAnchorChange: { [weak self] anchor in
                guard let self, self.anchorSession.id == sessionID else { return }
                guard self.anchorSession.accept(
                    anchor,
                    for: sessionID,
                    screens: HaloScreenGeometry.currentScreens()
                ) else { return }
                self.positionAndShowPanel(animated: true)
            }
        )
        caretTracker = tracker
        tracker.start()
    }

    private func stopCaretTracking() {
        caretTracker?.stop()
        caretTracker = nil
    }

    private var panelSize: CGSize {
        if presentation.phase == .reviewing,
            presentation.isReviewRefocusing
        {
            return HaloPanelMetrics.focusRecovery
        }
        let hasVisiblePartialTranscript = hasPartialTranscript
            && UserDefaults.standard.bool(forKey: RecorderDisplaySettingsKeys.showLiveTranscript)
        return HaloPanelMetrics.size(
            for: presentation.phase,
            hasVisiblePartialTranscript: hasVisiblePartialTranscript
        )
    }

    private func updateModeMetadata() {
        guard let mode = ModeManager.shared.currentEffectiveConfiguration else { return }

        let contextLabels: [String] = [
            mode.useSelectedTextContext ? String(localized: "Selection") : nil,
            mode.useClipboardContext ? String(localized: "Clipboard") : nil,
            mode.useScreenCapture ? String(localized: "Screen") : nil,
        ].compactMap { $0 }

        let authMode = mode.selectedOpenAIAuthMode.flatMap(OpenAIAuthMode.init(rawValue:))
        let provider = mode.selectedAIProvider.flatMap(AIProvider.init(rawValue:))
        let selectedModel = provider == .openAI && authMode == .oauth
            ? mode.selectedOpenAIOAuthModel
            : mode.selectedAIModel

        presentation.updateMetadata(
            HaloPresentationMetadata(
                applicationName: presentation.metadata.applicationName,
                modeName: mode.name,
                contextLabels: contextLabels,
                providerLabel: provider?.rawValue,
                connectionLabel: provider == .openAI ? authMode?.rawValue : nil,
                modelLabel: selectedModel
            )
        )
    }

    deinit {
        anchorResolutionTask?.cancel()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }
}
