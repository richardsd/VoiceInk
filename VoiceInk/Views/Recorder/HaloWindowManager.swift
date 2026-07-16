import AppKit
import Combine
import SwiftUI

enum HaloPanelMetrics {
    static let compact = CGSize(width: 240, height: 48)
    static let liveTranscript = CGSize(width: 360, height: 124)
    static let enhancing = CGSize(width: 320, height: 72)
    static let review = CGSize(width: 500, height: 380)
    static let confirmation = CGSize(width: 132, height: 44)

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
        }
    }
}

@MainActor
final class HaloWindowManager {
    private var windowController: NSWindowController?
    private var panel: HaloRecorderPanel?
    private var screenObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var anchorResolutionTask: Task<Void, Never>?
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
            focusedElementIdentity: capturedAnchor.focusedElementIdentity
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
            if self.isShowRequested {
                self.positionAndShowPanel(animated: true)
            }
            self.anchorResolutionTask = nil
        }
    }

    func hide(preservingSession: Bool = false) {
        isShowRequested = false
        panel?.endReviewInteraction()
        panel?.orderOut(nil)

        if !preservingSession {
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
        anchorResolutionTask?.cancel()
        anchorResolutionTask = nil
        hasPartialTranscript = false
        isShowingPasteConfirmation = false
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
        enhancementWarning: String?
    ) {
        isShowingPasteConfirmation = false
        presentation.presentReview(
            rawText: rawText,
            finalText: finalText,
            modeName: modeName,
            providerLabel: providerLabel,
            connectionLabel: connectionLabel,
            modelLabel: modelLabel,
            enhancementWarning: enhancementWarning
        )
        presentation.updateReviewStatus(
            feedback: engine.pasteReviewFeedback,
            secondsRemaining: engine.pasteReviewSecondsRemaining,
            isDelivering: engine.recordingState == .busy
        )
        panel?.beginReviewInteraction()
        resizeVisiblePanel(animated: true)
    }

    func clearReview() {
        panel?.endReviewInteraction()
        presentation.clearReview()
    }

    func presentPasteConfirmation() {
        isShowingPasteConfirmation = true
        isShowRequested = true
        panel?.endReviewInteraction()
        presentation.presentPasteConfirmation()
        initializeWindowIfNeeded()
        positionAndShowPanel(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func initializeWindowIfNeeded() {
        guard panel == nil else { return }

        let initialSize = panelSize
        let initialFrame = placement(for: initialSize)?.frame
            ?? CGRect(origin: .zero, size: initialSize)
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
            onSelectReviewLens: { [weak engine] lens in
                engine?.selectHaloReviewLens(lens)
            },
            onMoveReviewRevision: { [weak engine] offset in
                engine?.moveHaloReviewRevision(by: offset)
            },
            onRefine: { [weak engine] action in
                _ = engine?.beginHaloRefinement(action)
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
                if reviewState != nil {
                    self.panel?.beginReviewInteraction()
                }
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

        NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
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

        if panel.isVisible {
            let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            panel.update(frame: placement.frame, animated: shouldAnimate)
        } else {
            panel.show(frame: placement.frame)
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

    private var panelSize: CGSize {
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
