import AppKit

struct HaloInteractionRegion: Equatable {
    enum Shape: Equatable {
        case rectangle
        case roundedRectangle(cornerRadius: CGFloat)
    }

    let frame: CGRect
    let shape: Shape

    static func rectangle(_ frame: CGRect) -> Self {
        Self(frame: frame, shape: .rectangle)
    }

    static func roundedRectangle(_ frame: CGRect, cornerRadius: CGFloat) -> Self {
        Self(frame: frame, shape: .roundedRectangle(cornerRadius: cornerRadius))
    }

    func contains(_ point: CGPoint, tolerance: CGFloat = 1) -> Bool {
        let expandedFrame = frame.insetBy(dx: -tolerance, dy: -tolerance)

        switch shape {
        case .rectangle:
            return expandedFrame.contains(point)
        case let .roundedRectangle(cornerRadius):
            let expandedRadius = max(0, cornerRadius + tolerance)
            return CGPath(
                roundedRect: expandedFrame,
                cornerWidth: expandedRadius,
                cornerHeight: expandedRadius,
                transform: nil
            )
            .contains(point)
        }
    }
}

enum HaloInteractionHitTester {
    static func contains(_ point: CGPoint, in regions: [HaloInteractionRegion]) -> Bool {
        regions.contains { $0.contains(point) }
    }

    static func clipped(
        _ regions: [HaloInteractionRegion],
        to bounds: CGRect
    ) -> [HaloInteractionRegion] {
        regions.compactMap { region in
            guard !region.frame.isNull,
                !region.frame.isInfinite,
                region.frame.width > 0,
                region.frame.height > 0
            else {
                return nil
            }

            let clipped = bounds.isEmpty ? region.frame : region.frame.intersection(bounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
            return HaloInteractionRegion(frame: clipped, shape: region.shape)
        }
    }
}

enum HaloReviewInteractionRegionResolver {
    static func pendingRegions(
        from regions: [HaloInteractionRegion]
    ) -> [HaloInteractionRegion] {
        // Preserve regions that are outside the panel's compact/intermediate
        // bounds while it expands into review. They are clipped only after the
        // final AppKit layout has been applied.
        HaloInteractionHitTester.clipped(regions, to: .zero)
    }

    static func activeRegions(
        from pendingRegions: [HaloInteractionRegion],
        within bounds: CGRect
    ) -> [HaloInteractionRegion] {
        HaloInteractionHitTester.clipped(pendingRegions, to: bounds)
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

enum HaloReviewFrameChangeKind: Equatable {
    case none
    case positionOnly
    case size
}

enum HaloReviewFrameChangeClassifier {
    static func classify(
        from currentFrame: CGRect,
        to targetFrame: CGRect
    ) -> HaloReviewFrameChangeKind {
        guard currentFrame != targetFrame else { return .none }
        return currentFrame.size == targetFrame.size ? .positionOnly : .size
    }
}

struct HaloReviewLayoutTransitionTracker {
    typealias Generation = UInt

    private(set) var activeGeneration: Generation?
    private var nextGeneration: Generation = 0

    var isActive: Bool { activeGeneration != nil }

    mutating func begin() -> Generation {
        nextGeneration &+= 1
        activeGeneration = nextGeneration
        return nextGeneration
    }

    mutating func finish(_ generation: Generation) -> Bool {
        guard activeGeneration == generation else { return false }
        activeGeneration = nil
        return true
    }

    mutating func cancel() {
        activeGeneration = nil
    }
}

enum HaloPanelMouseTransparencyPolicy {
    static func ignoresMouseEvents(
        interactionState: HaloReviewInteractionState,
        pointer: CGPoint,
        interactiveRegions: [HaloInteractionRegion]
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
/// shortcut event tap. The sole explicit exception is user-invoked manual text
/// editing, which temporarily permits key status and is followed by destination
/// revalidation before delivery.
final class HaloRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { allowsManualEditing }
    override var canBecomeMain: Bool { false }

    private var allowsManualEditing = false
    private var interactionState: HaloReviewInteractionState = .inactive
    private var interactiveRegions: [HaloInteractionRegion] = []
    private var pendingInteractiveRegions: [HaloInteractionRegion] = []
    private var reviewLayoutTransitionTracker = HaloReviewLayoutTransitionTracker()
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
        let transitionGeneration = prepareForFrameChangeIfNeeded(frame)
        setFrame(frame, display: true)
        finishReviewLayoutTransitionIfNeeded(generation: transitionGeneration)
        orderFrontRegardless()
        refreshMouseTransparency()
    }

    func update(frame: CGRect, animated: Bool) {
        let transitionGeneration = prepareForFrameChangeIfNeeded(frame)

        guard animated, isVisible else {
            setFrame(frame, display: true)
            finishReviewLayoutTransitionIfNeeded(generation: transitionGeneration)
            refreshMouseTransparency()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.21
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            self?.finishReviewLayoutTransitionIfNeeded(generation: transitionGeneration)
            self?.refreshMouseTransparency()
        }
    }

    /// Enables mouse handling across the visible SwiftUI review surface. The
    /// panel remains transparent only in the visual-effect margin around that
    /// surface, preserving destination focus when users click blank review UI.
    func beginReviewInteraction() {
        guard interactionState == .inactive else {
            refreshMouseTransparency()
            return
        }

        interactiveRegions = []
        pendingInteractiveRegions = []
        reviewLayoutTransitionTracker.cancel()

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

    func updateReviewInteractiveRegions(_ regions: [HaloInteractionRegion]) {
        guard interactionState != .inactive else { return }

        let pendingRegions = HaloReviewInteractionRegionResolver.pendingRegions(
            from: regions
        )
        pendingInteractiveRegions = pendingRegions

        guard !reviewLayoutTransitionTracker.isActive else { return }

        let bounds = contentView?.bounds ?? .zero
        applyInteractiveRegions(
            HaloReviewInteractionRegionResolver.activeRegions(
                from: pendingRegions,
                within: bounds
            )
        )
        refreshMouseTransparency()
    }

    func endReviewInteraction() {
        interactionState = .inactive
        interactiveRegions = []
        pendingInteractiveRegions = []
        reviewLayoutTransitionTracker.cancel()
        stopMouseMonitors()
        ignoresMouseEvents = true
    }

    func setManualEditing(_ isEditing: Bool) {
        guard allowsManualEditing != isEditing else { return }
        allowsManualEditing = isEditing
        becomesKeyOnlyIfNeeded = isEditing

        if isEditing {
            ignoresMouseEvents = false
            orderFrontRegardless()
            makeKey()
        } else {
            makeFirstResponder(nil)
            resignKey()
            refreshMouseTransparency()
        }
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

    private func prepareForFrameChangeIfNeeded(
        _ frame: CGRect
    ) -> HaloReviewLayoutTransitionTracker.Generation? {
        guard interactionState == .awaitingRegions || interactionState == .selective,
            HaloReviewFrameChangeClassifier.classify(from: self.frame, to: frame) == .size
        else {
            // Interactive regions use panel-local coordinates. Moving a panel
            // without resizing it cannot invalidate those regions, and waiting
            // for SwiftUI to republish unchanged geometry would leave the panel
            // permanently click-through.
            return nil
        }

        interactiveRegions = []
        // Keep the latest un-clipped SwiftUI regions. They may already describe
        // the destination layout even if they were published before AppKit began
        // the resize, and will be clipped against the final bounds on completion.
        interactionState = .awaitingRegions
        ignoresMouseEvents = true
        return reviewLayoutTransitionTracker.begin()
    }

    private func finishReviewLayoutTransitionIfNeeded(
        generation: HaloReviewLayoutTransitionTracker.Generation?
    ) {
        guard let generation,
            reviewLayoutTransitionTracker.finish(generation)
        else {
            return
        }

        contentView?.layoutSubtreeIfNeeded()
        applyInteractiveRegions(
            HaloReviewInteractionRegionResolver.activeRegions(
                from: pendingInteractiveRegions,
                within: contentView?.bounds ?? .zero
            )
        )
    }

    private func applyInteractiveRegions(_ regions: [HaloInteractionRegion]) {
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
