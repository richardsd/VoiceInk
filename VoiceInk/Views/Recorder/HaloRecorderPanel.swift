import AppKit

enum HaloInteractionHitTester {
    static func contains(_ point: CGPoint, in regions: [CGRect]) -> Bool {
        regions.contains { $0.insetBy(dx: -1, dy: -1).contains(point) }
    }
}

enum HaloInteractionCoordinateConverter {
    static func swiftUIPoint(fromAppKitPoint point: CGPoint, contentHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: contentHeight - point.y)
    }
}

enum HaloPanelMouseTransparencyPolicy {
    static func ignoresMouseEvents(
        reviewInteractionEnabled: Bool,
        selectiveMonitoringAvailable: Bool,
        pointer: CGPoint,
        interactiveRegions: [CGRect]
    ) -> Bool {
        guard reviewInteractionEnabled else { return true }
        guard selectiveMonitoringAvailable, !interactiveRegions.isEmpty else { return false }
        return !HaloInteractionHitTester.contains(pointer, in: interactiveRegions)
    }
}

/// A focus-preserving recorder surface. Keyboard input continues to go to the
/// destination application; VoiceInk controls this panel through its global
/// shortcut event tap instead of making the panel key.
final class HaloRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var reviewInteractionEnabled = false
    private var selectiveMonitoringAvailable = false
    private var interactiveRegions: [CGRect] = []
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
        setFrame(frame, display: true)
        orderFrontRegardless()
        refreshMouseTransparency()
    }

    func update(frame: CGRect, animated: Bool) {
        guard animated, isVisible else {
            setFrame(frame, display: true)
            refreshMouseTransparency()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.21
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            self?.refreshMouseTransparency()
        }
    }

    /// Enables mouse handling only over regions reported by the SwiftUI review
    /// surface. Everywhere else the nonactivating panel remains transparent so
    /// the destination application keeps focus and receives the click.
    func beginReviewInteraction() {
        guard !reviewInteractionEnabled else {
            refreshMouseTransparency()
            return
        }

        reviewInteractionEnabled = true
        interactiveRegions = []

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
            selectiveMonitoringAvailable = false
            ignoresMouseEvents = false
        } else {
            selectiveMonitoringAvailable = true
            refreshMouseTransparency()
        }
    }

    func updateReviewInteractiveRegions(_ regions: [CGRect]) {
        interactiveRegions = regions.filter {
            !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height > 0
        }
        refreshMouseTransparency()
    }

    func endReviewInteraction() {
        reviewInteractionEnabled = false
        selectiveMonitoringAvailable = false
        interactiveRegions = []
        stopMouseMonitors()
        ignoresMouseEvents = true
    }

    private func refreshMouseTransparency() {
        // SwiftUI reports regions in a top-left local coordinate space while
        // AppKit window points use a bottom-left origin.
        let appKitPoint = convertPoint(fromScreen: NSEvent.mouseLocation)
        let swiftUIPoint = HaloInteractionCoordinateConverter.swiftUIPoint(
            fromAppKitPoint: appKitPoint,
            contentHeight: contentView?.bounds.height ?? 0
        )
        ignoresMouseEvents = HaloPanelMouseTransparencyPolicy.ignoresMouseEvents(
            reviewInteractionEnabled: reviewInteractionEnabled,
            selectiveMonitoringAvailable: selectiveMonitoringAvailable,
            pointer: swiftUIPoint,
            interactiveRegions: interactiveRegions
        )
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
