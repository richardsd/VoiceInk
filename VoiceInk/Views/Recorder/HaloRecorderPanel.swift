import AppKit

enum HaloInteractionHitTester {
    static func contains(_ point: CGPoint, in regions: [CGRect]) -> Bool {
        regions.contains { $0.insetBy(dx: -1, dy: -1).contains(point) }
    }

    static func clipped(_ regions: [CGRect], to bounds: CGRect) -> [CGRect] {
        regions.compactMap { region in
            guard !region.isNull,
                !region.isInfinite,
                region.width > 0,
                region.height > 0
            else {
                return nil
            }

            let clipped = bounds.isEmpty ? region : region.intersection(bounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
            return clipped
        }
    }
}

enum HaloInteractionCoordinateConverter {
    static func swiftUIPoint(fromAppKitPoint point: CGPoint, contentHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: contentHeight - point.y)
    }
}

enum HaloReviewInteractionState: Equatable {
    case inactive
    case awaitingRegions
    case selective
    case wholePanelFallback
}

enum HaloPanelMouseTransparencyPolicy {
    static func ignoresMouseEvents(
        interactionState: HaloReviewInteractionState,
        pointer: CGPoint,
        interactiveRegions: [CGRect]
    ) -> Bool {
        switch interactionState {
        case .inactive, .awaitingRegions:
            return true
        case .selective:
            return !HaloInteractionHitTester.contains(pointer, in: interactiveRegions)
        case .wholePanelFallback:
            return false
        }
    }
}

/// A focus-preserving recorder surface. Keyboard input continues to go to the
/// destination application; VoiceInk controls this panel through its global
/// shortcut event tap instead of making the panel key.
final class HaloRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var interactionState: HaloReviewInteractionState = .inactive
    private var interactiveRegions: [CGRect] = []
    private var pendingInteractiveRegions: [CGRect] = []
    private var isReviewLayoutTransitioning = false
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configurePanel()
    }

    private func configurePanel() {
        isFloatingPanel = true
        styleMask.remove(.titled)
        becomesKeyOnlyIfNeeded = false
        canHide = false
        level = .statusBar + 2
        hidesOnDeactivate = false
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        ignoresMouseEvents = true
        isMovable = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        animationBehavior = .utilityWindow
        appearance = NSAppearance(named: .darkAqua)
        isReleasedWhenClosed = false
    }

    func show(frame: CGRect) {
        prepareForFrameChangeIfNeeded(frame)
        setFrame(frame, display: true)
        finishReviewLayoutTransitionIfNeeded()
        orderFrontRegardless()
        refreshMouseTransparency()
    }

    func update(frame: CGRect, animated: Bool) {
        prepareForFrameChangeIfNeeded(frame)

        guard animated, isVisible else {
            setFrame(frame, display: true)
            finishReviewLayoutTransitionIfNeeded()
            refreshMouseTransparency()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.21
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            self?.finishReviewLayoutTransitionIfNeeded()
            self?.refreshMouseTransparency()
        }
    }

    /// Enables mouse handling only over regions reported by the SwiftUI review
    /// surface. Everywhere else the nonactivating panel remains transparent so
    /// the destination application keeps focus and receives the click.
    func beginReviewInteraction() {
        guard interactionState == .inactive else {
            refreshMouseTransparency()
            return
        }

        interactiveRegions = []
        pendingInteractiveRegions = []
        isReviewLayoutTransitioning = false

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            self?.refreshMouseTransparency()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMouseTransparency()
            }
        }

        // If either monitor is unavailable, keep the complete review surface
        // interactive rather than presenting unreachable mouse controls.
        if localMouseMonitor == nil || globalMouseMonitor == nil {
            stopMouseMonitors()
            interactionState = .wholePanelFallback
        } else {
            // A review remains click-through until SwiftUI has published real
            // regions for the final-sized layout. This prevents a stale compact
            // layout from capturing an unrelated click during the resize.
            interactionState = .awaitingRegions
        }
        refreshMouseTransparency()
    }

    func updateReviewInteractiveRegions(_ regions: [CGRect]) {
        guard interactionState != .inactive else { return }

        let bounds = contentView?.bounds ?? .zero
        let clippedRegions = HaloInteractionHitTester.clipped(regions, to: bounds)
        pendingInteractiveRegions = clippedRegions

        guard !isReviewLayoutTransitioning else { return }

        applyInteractiveRegions(clippedRegions)
        refreshMouseTransparency()
    }

    func endReviewInteraction() {
        interactionState = .inactive
        interactiveRegions = []
        pendingInteractiveRegions = []
        isReviewLayoutTransitioning = false
        stopMouseMonitors()
        ignoresMouseEvents = true
    }

    private func refreshMouseTransparency() {
        if interactionState == .wholePanelFallback {
            ignoresMouseEvents = false
            return
        }

        guard interactionState == .selective,
            let contentView
        else {
            ignoresMouseEvents = true
            return
        }

        // SwiftUI reports regions in a top-left local coordinate space while
        // AppKit window points use a bottom-left origin.
        let appKitPoint = convertPoint(fromScreen: NSEvent.mouseLocation)
        guard contentView.bounds.contains(appKitPoint) else {
            ignoresMouseEvents = true
            return
        }
        let swiftUIPoint = HaloInteractionCoordinateConverter.swiftUIPoint(
            fromAppKitPoint: appKitPoint,
            contentHeight: contentView.bounds.height
        )
        ignoresMouseEvents = HaloPanelMouseTransparencyPolicy.ignoresMouseEvents(
            interactionState: interactionState,
            pointer: swiftUIPoint,
            interactiveRegions: interactiveRegions
        )
    }

    private func prepareForFrameChangeIfNeeded(_ frame: CGRect) {
        guard frame != self.frame,
            (interactionState == .awaitingRegions || interactionState == .selective)
        else {
            return
        }

        interactiveRegions = []
        pendingInteractiveRegions = []
        interactionState = .awaitingRegions
        isReviewLayoutTransitioning = true
        ignoresMouseEvents = true
    }

    private func finishReviewLayoutTransitionIfNeeded() {
        guard isReviewLayoutTransitioning else { return }

        isReviewLayoutTransitioning = false
        applyInteractiveRegions(pendingInteractiveRegions)
        contentView?.layoutSubtreeIfNeeded()
    }

    private func applyInteractiveRegions(_ regions: [CGRect]) {
        guard interactionState != .inactive,
            interactionState != .wholePanelFallback
        else {
            return
        }

        interactiveRegions = regions
        interactionState = regions.isEmpty ? .awaitingRegions : .selective
    }

    private func stopMouseMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    deinit {
        stopMouseMonitors()
    }
}
