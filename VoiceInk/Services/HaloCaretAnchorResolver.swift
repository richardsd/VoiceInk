import AppKit
import ApplicationServices
import Foundation
import os

/// A stable, testable snapshot of an AppKit screen. Keeping geometry independent
/// of `NSScreen` lets the Halo placement rules run in tests without a window server.
struct HaloScreenGeometry: Equatable, Sendable {
    let id: String
    let frame: CGRect
    let visibleFrame: CGRect
    let isPrimary: Bool

    @MainActor
    static func currentScreens() -> [HaloScreenGeometry] {
        let screens = NSScreen.screens
        let primaryDisplayID = String(CGMainDisplayID())
        let primary = screens.first(where: { $0.haloDisplayID == primaryDisplayID })
            ?? screens.first(where: { $0.frame.origin == .zero })
            ?? screens.first

        return screens.map { screen in
            HaloScreenGeometry(
                id: screen.haloDisplayID,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                isPrimary: primary.map { screen === $0 } ?? false
            )
        }
    }
}

enum HaloCaretAnchorSource: Equatable, Sendable {
    case collapsedSelection
    case nearestGlyph
    case insertionLine
    case focusedTextElement
    case focusedWindow
    case screenFallback

    var quality: HaloCaretAnchorQuality {
        switch self {
        case .collapsedSelection:
            return .precise
        case .nearestGlyph, .insertionLine:
            return .nearby
        case .focusedTextElement:
            return .approximate
        case .focusedWindow, .screenFallback:
            return .fallback
        }
    }

    fileprivate var diagnosticLabel: String {
        switch self {
        case .collapsedSelection: return "collapsed-selection"
        case .nearestGlyph: return "nearest-glyph"
        case .insertionLine: return "insertion-line"
        case .focusedTextElement: return "focused-text-element"
        case .focusedWindow: return "focused-window"
        case .screenFallback: return "screen-fallback"
        }
    }

    fileprivate var refinementRank: Int {
        switch self {
        case .screenFallback: return 0
        case .focusedWindow: return 1
        case .focusedTextElement: return 2
        case .insertionLine: return 3
        case .nearestGlyph: return 4
        case .collapsedSelection: return 5
        }
    }
}

enum HaloCaretAnchorQuality: Int, Comparable, Sendable {
    case fallback = 0
    case approximate = 1
    case nearby = 2
    case precise = 3

    static func < (lhs: HaloCaretAnchorQuality, rhs: HaloCaretAnchorQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var shouldRetry: Bool { self <= .approximate }

    fileprivate var diagnosticLabel: String {
        switch self {
        case .fallback: return "fallback"
        case .approximate: return "approximate"
        case .nearby: return "nearby"
        case .precise: return "precise"
        }
    }
}

/// A short-lived identity for the destination that currently owns keyboard
/// focus. AX objects themselves are deliberately not retained or persisted.
struct HaloFocusedDestinationSnapshot: Equatable, Sendable {
    let processID: pid_t?
    let applicationName: String?
    let bundleIdentifier: String?
    let focusedElementIdentity: UInt?
}

enum HaloDestinationSelection {
    private static let transientSystemServiceBundlePrefixes = [
        "com.apple.writingtools",
    ]

    static func preferred(
        systemFocused: HaloFocusedDestinationSnapshot,
        frontmostFallback: HaloFocusedDestinationSnapshot,
        currentProcessID: pid_t
    ) -> HaloFocusedDestinationSnapshot {
        guard let systemPID = systemFocused.processID,
            systemPID != currentProcessID,
            !isTransientSystemService(systemFocused)
        else {
            return frontmostFallback
        }
        return systemFocused
    }

    /// macOS Writing Tools exposes a transient XPC view service as the focused
    /// accessibility application. It is not the destination the user dictated
    /// into, and anchoring Halo to it puts the panel beside the system overlay
    /// instead of the underlying editor.
    private static func isTransientSystemService(_ snapshot: HaloFocusedDestinationSnapshot) -> Bool {
        guard let bundleIdentifier = snapshot.bundleIdentifier?.lowercased() else { return false }
        return transientSystemServiceBundlePrefixes.contains {
            bundleIdentifier.hasPrefix($0)
        }
    }
}

/// The resolved anchor includes the original AX rectangle so it can be converted
/// again after a monitor arrangement change without querying the destination app.
struct HaloCaretAnchor: Equatable, Sendable {
    let destinationPID: pid_t?
    let applicationName: String?
    let bundleIdentifier: String?
    /// A process-local AX identity captured for this recording. It is meaningful
    /// only together with `destinationPID`, is never persisted, and avoids
    /// retaining an `AXUIElement` across the recording lifetime.
    let focusedElementIdentity: UInt?
    let source: HaloCaretAnchorSource
    let accessibilityRect: CGRect?
    let appKitRect: CGRect?
    let screenID: String?

    var quality: HaloCaretAnchorQuality { source.quality }

    func isHigherQuality(than other: HaloCaretAnchor?) -> Bool {
        guard let other else { return true }
        if quality != other.quality { return quality > other.quality }
        return source.refinementRank > other.source.refinementRank
    }

    init(
        destinationPID: pid_t?,
        applicationName: String?,
        bundleIdentifier: String? = nil,
        focusedElementIdentity: UInt? = nil,
        source: HaloCaretAnchorSource,
        accessibilityRect: CGRect?,
        appKitRect: CGRect?,
        screenID: String?
    ) {
        self.destinationPID = destinationPID
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.focusedElementIdentity = focusedElementIdentity
        self.source = source
        self.accessibilityRect = accessibilityRect
        self.appKitRect = appKitRect
        self.screenID = screenID
    }
}

/// Owns the immutable-per-recording anchor snapshot independently of window
/// visibility. This lets effective-shell changes hide Halo without losing the
/// destination, while rejecting late AX results from an older recording.
struct HaloAnchorSessionState: Sendable {
    private(set) var id = UUID()
    private(set) var anchor: HaloCaretAnchor?

    @discardableResult
    mutating func begin() -> UUID {
        id = UUID()
        anchor = nil
        return id
    }

    mutating func end() {
        id = UUID()
        anchor = nil
    }

    @discardableResult
    mutating func accept(
        _ candidate: HaloCaretAnchor,
        for candidateSessionID: UUID,
        screens: [HaloScreenGeometry]
    ) -> Bool {
        guard candidateSessionID == id else { return false }
        anchor = HaloCaretAnchorResolver.reconvertedAnchor(candidate, screens: screens)
        return true
    }

    mutating func reconcileDisplays(_ screens: [HaloScreenGeometry]) {
        guard let anchor else { return }
        self.anchor = HaloCaretAnchorResolver.reconvertedAnchor(anchor, screens: screens)
    }
}

struct HaloPanelPlacement: Equatable, Sendable {
    let frame: CGRect
    let screenID: String
    let isAboveAnchor: Bool
}

enum HaloPanelPlacementSide: Equatable, Sendable {
    case above
    case below
}

/// Pure geometry used by `HaloWindowManager` and its unit tests.
enum HaloPanelPositioner {
    static let edgeInset: CGFloat = 12
    static let anchorGap: CGFloat = 12

    /// Accessibility uses a top-left origin. AppKit uses a bottom-left origin,
    /// with the primary display's top edge as the vertical conversion baseline.
    static func appKitRect(fromAccessibilityRect rect: CGRect, primaryScreenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func screen(for rect: CGRect, in screens: [HaloScreenGeometry]) -> HaloScreenGeometry? {
        guard !screens.isEmpty else { return nil }

        let ranked = screens.map { screen in
            (screen: screen, area: intersectionArea(rect, screen.frame))
        }

        if let intersecting = ranked.max(by: { $0.area < $1.area }), intersecting.area > 0 {
            return intersecting.screen
        }

        return screens.min {
            squaredDistance(from: rect.center, to: $0.frame) < squaredDistance(from: rect.center, to: $1.frame)
        }
    }

    static func placement(
        panelSize: CGSize,
        anchorRect: CGRect?,
        preferredScreenID: String?,
        preferredSide: HaloPanelPlacementSide? = nil,
        screens: [HaloScreenGeometry]
    ) -> HaloPanelPlacement? {
        guard !screens.isEmpty else { return nil }

        let screen: HaloScreenGeometry
        if let anchorRect, let intersectingScreen = Self.screen(for: anchorRect, in: screens) {
            screen = intersectingScreen
        } else if let preferredScreenID, let preferred = screens.first(where: { $0.id == preferredScreenID }) {
            screen = preferred
        } else {
            screen = screens.first(where: \.isPrimary) ?? screens[0]
        }

        let usableFrame = screen.visibleFrame.insetBy(dx: edgeInset, dy: edgeInset)
        guard usableFrame.width > 0, usableFrame.height > 0 else { return nil }

        guard let anchorRect else {
            let frame = clamp(
                CGRect(
                    x: usableFrame.midX - panelSize.width / 2,
                    y: usableFrame.minY,
                    width: panelSize.width,
                    height: panelSize.height
                ),
                to: usableFrame
            )
            return HaloPanelPlacement(frame: frame, screenID: screen.id, isAboveAnchor: false)
        }

        let x = anchorRect.midX - panelSize.width / 2
        let aboveFrame = CGRect(
            x: x,
            y: anchorRect.maxY + anchorGap,
            width: panelSize.width,
            height: panelSize.height
        )
        let belowFrame = CGRect(
            x: x,
            y: anchorRect.minY - anchorGap - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )

        if let preferredSide {
            let preferredFrame = preferredSide == .above ? aboveFrame : belowFrame
            if usableFrame.containsVertically(preferredFrame) {
                return HaloPanelPlacement(
                    frame: clamp(preferredFrame, to: usableFrame),
                    screenID: screen.id,
                    isAboveAnchor: preferredSide == .above
                )
            }

            // Keep the original side while it fits, but do not pin a grown
            // review panel against a screen edge when the opposite side has
            // room. This preserves the stable-anchor intent without producing
            // a visibly detached overlay.
            let alternateFrame = preferredSide == .above ? belowFrame : aboveFrame
            if usableFrame.containsVertically(alternateFrame) {
                return HaloPanelPlacement(
                    frame: clamp(alternateFrame, to: usableFrame),
                    screenID: screen.id,
                    isAboveAnchor: preferredSide == .below
                )
            }

            return HaloPanelPlacement(
                frame: clamp(preferredFrame, to: usableFrame),
                screenID: screen.id,
                isAboveAnchor: preferredSide == .above
            )
        }

        if usableFrame.containsVertically(aboveFrame) {
            return HaloPanelPlacement(
                frame: clamp(aboveFrame, to: usableFrame),
                screenID: screen.id,
                isAboveAnchor: true
            )
        }

        if usableFrame.containsVertically(belowFrame) {
            return HaloPanelPlacement(
                frame: clamp(belowFrame, to: usableFrame),
                screenID: screen.id,
                isAboveAnchor: false
            )
        }

        // A very tall review can fit neither side. Preserve the preferred side's
        // horizontal alignment and clamp it wholly inside the visible frame.
        let preferred = anchorRect.midY >= usableFrame.midY ? belowFrame : aboveFrame
        return HaloPanelPlacement(
            frame: clamp(preferred, to: usableFrame),
            screenID: screen.id,
            isAboveAnchor: preferred == aboveFrame
        )
    }

    static func stableSide(
        anchorRect: CGRect?,
        preferredScreenID: String?,
        maximumPanelHeight: CGFloat,
        screens: [HaloScreenGeometry]
    ) -> HaloPanelPlacementSide? {
        guard let anchorRect, !screens.isEmpty else { return nil }
        let screen = Self.screen(for: anchorRect, in: screens)
            ?? preferredScreenID.flatMap { preferredID in
                screens.first(where: { $0.id == preferredID })
            }
            ?? screens.first(where: \.isPrimary)
            ?? screens[0]
        let usableFrame = screen.visibleFrame.insetBy(dx: edgeInset, dy: edgeInset)
        let availableAbove = usableFrame.maxY - anchorRect.maxY - anchorGap
        let availableBelow = anchorRect.minY - anchorGap - usableFrame.minY

        if availableAbove >= maximumPanelHeight { return .above }
        if availableBelow >= maximumPanelHeight { return .below }
        return availableAbove >= availableBelow ? .above : .below
    }

    private static func clamp(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        let width = min(frame.width, bounds.width)
        let height = min(frame.height, bounds.height)
        let x = min(max(frame.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(frame.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let nearestX = min(max(point.x, rect.minX), rect.maxX)
        let nearestY = min(max(point.y, rect.minY), rect.maxY)
        let deltaX = point.x - nearestX
        let deltaY = point.y - nearestY
        return deltaX * deltaX + deltaY * deltaY
    }
}

enum HaloCaretRangeStrategy {
    static func collapsedRange(from selectedRange: CFRange) -> CFRange? {
        guard selectedRange.location != kCFNotFound, selectedRange.location >= 0, selectedRange.length >= 0 else {
            return nil
        }
        let (caretLocation, overflow) = selectedRange.location.addingReportingOverflow(selectedRange.length)
        guard !overflow else { return nil }
        return CFRange(location: caretLocation, length: 0)
    }

    static func nearestGlyphRanges(caretLocation: CFIndex, valueLength: Int?) -> [CFRange] {
        guard caretLocation >= 0 else { return [] }
        var ranges: [CFRange] = []

        // Prefer the glyph after the insertion point. At a soft wrap or after a
        // newline it is on the same visual line as the caret, while the previous
        // glyph may be on the line above.
        if valueLength.map({ caretLocation < $0 }) ?? true {
            ranges.append(CFRange(location: caretLocation, length: 1))
        }

        if caretLocation > 0 {
            ranges.append(CFRange(location: caretLocation - 1, length: 1))
        }

        return ranges
    }
}

enum HaloCaretInsertionGeometry {
    /// Builds a zero-width insertion rect from the adjacent glyphs. Querying both
    /// sides avoids pinning a wrapped caret to the preceding visual line.
    static func caretRect(
        previousGlyph: CGRect?,
        nextGlyph: CGRect?
    ) -> CGRect? {
        switch (previousGlyph, nextGlyph) {
        case let (previous?, next?):
            let overlap = previous.intersection(next)
            let minimumHeight = min(previous.height, next.height)
            let sharesVisualLine = !overlap.isNull && overlap.height >= minimumHeight * 0.25

            if sharesVisualLine {
                let leftToRightDistance = abs(previous.maxX - next.minX)
                let rightToLeftDistance = abs(previous.minX - next.maxX)
                let x: CGFloat
                if leftToRightDistance <= rightToLeftDistance {
                    x = (previous.maxX + next.minX) / 2
                } else {
                    x = (previous.minX + next.maxX) / 2
                }
                return verticalCaret(at: x, matching: next)
            }

            // Different visual lines means the current glyph is the reliable
            // side of the insertion point (soft wrap/newline).
            return verticalCaret(at: next.minX, matching: next)

        case let (_, next?):
            return verticalCaret(at: next.minX, matching: next)

        case let (previous?, nil):
            return verticalCaret(at: previous.maxX, matching: previous)

        case (nil, nil):
            return nil
        }
    }

    private static func verticalCaret(at x: CGFloat, matching rect: CGRect) -> CGRect {
        CGRect(x: x, y: rect.minY, width: 0, height: rect.height)
    }
}

/// Lazy Accessibility reads used by the ordered fallback resolver. Production
/// supplies AX-backed closures; tests can drive every fallback without requiring
/// Accessibility permission or a live destination application.
struct HaloCaretLookupSteps {
    let selectedRange: () -> CFRange?
    let boundsForRange: (CFRange) -> CGRect?
    let focusedCharacterCount: () -> Int?
    let insertionLineBounds: (CFIndex) -> CGRect?
    let focusedElementIsTextCapable: () -> Bool
    let focusedElementFrame: () -> CGRect?
    let focusedWindowFrame: () -> CGRect?
}

enum HaloCaretFallbackResolver {
    static func resolve(
        using steps: HaloCaretLookupSteps
    ) -> (rect: CGRect, source: HaloCaretAnchorSource)? {
        let selectedRange = steps.selectedRange()
        let collapsedRange = selectedRange.flatMap(HaloCaretRangeStrategy.collapsedRange)

        if let collapsedRange {
            if let rect = steps.boundsForRange(collapsedRange) {
                return (rect, .collapsedSelection)
            }

            let characterCount = steps.focusedCharacterCount()
            let nextGlyph = characterCount.map({ collapsedRange.location < $0 }) ?? true
                ? steps.boundsForRange(CFRange(location: collapsedRange.location, length: 1))
                : nil
            let previousGlyph = collapsedRange.location > 0
                ? steps.boundsForRange(CFRange(location: collapsedRange.location - 1, length: 1))
                : nil

            if let rect = HaloCaretInsertionGeometry.caretRect(
                previousGlyph: previousGlyph,
                nextGlyph: nextGlyph
            ) {
                return (rect, .nearestGlyph)
            }

            if let rect = steps.insertionLineBounds(collapsedRange.location) {
                return (rect, .insertionLine)
            }
        }

        if (collapsedRange != nil || steps.focusedElementIsTextCapable()),
            let rect = steps.focusedElementFrame()
        {
            return (rect, .focusedTextElement)
        }

        if let rect = steps.focusedWindowFrame() {
            return (rect, .focusedWindow)
        }

        return nil
    }
}

enum HaloCaretBoundsValidator {
    private static let maximumGlyphWidth: CGFloat = 240
    private static let maximumLineHeight: CGFloat = 160
    private static let containerTolerance: CGFloat = 48

    static func isPlausibleTextBounds(
        _ accessibilityRect: CGRect,
        containerAccessibilityFrame: CGRect?,
        primaryScreenFrame: CGRect,
        screens: [HaloScreenGeometry]
    ) -> Bool {
        guard accessibilityRect.isHaloUsable,
            accessibilityRect.width <= maximumGlyphWidth,
            accessibilityRect.height <= maximumLineHeight
        else {
            return false
        }

        let appKitRect = HaloPanelPositioner.appKitRect(
            fromAccessibilityRect: accessibilityRect,
            primaryScreenFrame: primaryScreenFrame
        )
        let screenProbe = appKitRect.insetBy(dx: -1, dy: -1)
        guard screens.contains(where: { !$0.frame.intersection(screenProbe).isNull }) else {
            return false
        }

        guard let containerAccessibilityFrame else { return true }
        return !containerAccessibilityFrame
            .insetBy(dx: -containerTolerance, dy: -containerTolerance)
            .intersection(accessibilityRect.insetBy(dx: -1, dy: -1))
            .isNull
    }

    static func isPlausibleContainerFrame(
        _ accessibilityRect: CGRect,
        primaryScreenFrame: CGRect,
        screens: [HaloScreenGeometry]
    ) -> Bool {
        guard accessibilityRect.isHaloUsable, accessibilityRect.width > 0 else { return false }
        let appKitRect = HaloPanelPositioner.appKitRect(
            fromAccessibilityRect: accessibilityRect,
            primaryScreenFrame: primaryScreenFrame
        )
        return screens.contains { screen in
            let intersection = screen.frame.intersection(appKitRect)
            return !intersection.isNull && intersection.width > 0 && intersection.height > 0
        }
    }
}

enum HaloApproximateAnchorGeometry {
    static func normalizedAppKitRect(
        containerRect: CGRect,
        pointerLocation: CGPoint?,
        source: HaloCaretAnchorSource
    ) -> CGRect {
        let pointerInsideContainer = pointerLocation.flatMap { point in
            containerRect.contains(point) ? point : nil
        }
        let anchorPoint = pointerInsideContainer
            ?? CGPoint(x: containerRect.midX, y: containerRect.midY)

        let canReuseContainerHeight = source == .focusedTextElement && containerRect.height <= 64
        let height = canReuseContainerHeight ? max(1, containerRect.height) : 20
        let y = canReuseContainerHeight
            ? containerRect.minY
            : anchorPoint.y - height / 2
        return CGRect(x: anchorPoint.x, y: y, width: 0, height: height)
    }

    static func accessibilityRect(fromAppKitRect rect: CGRect, primaryScreenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

/// Performs the potentially blocking Accessibility query away from the main
/// actor. The AX connection also receives a short messaging timeout; a separate
/// completion gate guarantees callers regain control even if a third-party AX
/// implementation ignores that timeout.
final class HaloCaretAnchorResolver: @unchecked Sendable {
    static let defaultTimeout: TimeInterval = 0.18
    static let retryDelay: TimeInterval = 0.12
    static let retryTimeout: TimeInterval = 0.30

    private static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "HaloCaretAnchor"
    )

    typealias LookupOperation = @Sendable (
        _ destinationPID: pid_t?,
        _ applicationName: String?,
        _ screens: [HaloScreenGeometry],
        _ timeout: TimeInterval
    ) -> HaloCaretAnchor

    private let lookupQueue = DispatchQueue(
        label: "com.prakashjoshipax.voiceink.halo-caret",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let lookupOperation: LookupOperation
    private let usesSystemFocusedDestination: Bool

    init(lookupOperation: LookupOperation? = nil) {
        if let lookupOperation {
            self.lookupOperation = lookupOperation
            self.usesSystemFocusedDestination = false
        } else {
            self.lookupOperation = { destinationPID, applicationName, screens, timeout in
                Self.performLookup(
                    destinationPID: destinationPID,
                    applicationName: applicationName,
                    screens: screens,
                    timeout: timeout
                )
            }
            self.usesSystemFocusedDestination = true
        }
    }

    @MainActor
    func destinationSnapshot() -> HaloFocusedDestinationSnapshot {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        guard let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != currentProcessID
        else {
            return HaloFocusedDestinationSnapshot(
                processID: nil,
                applicationName: nil,
                bundleIdentifier: nil,
                focusedElementIdentity: nil
            )
        }
        return HaloFocusedDestinationSnapshot(
            processID: application.processIdentifier,
            applicationName: application.localizedName,
            bundleIdentifier: application.bundleIdentifier,
            focusedElementIdentity: nil
        )
    }

    /// Captures the system-wide focused app and focused AX element without
    /// retaining either AX object. Call from a background executor.
    nonisolated static func focusedDestinationSnapshot(
        timeout: TimeInterval = defaultTimeout
    ) -> HaloFocusedDestinationSnapshot {
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, Float(max(0.01, timeout)))

        guard let focusedApplication = copyElement(
            kAXFocusedApplicationAttribute,
            from: systemWideElement
        ) else {
            return HaloFocusedDestinationSnapshot(
                processID: nil,
                applicationName: nil,
                bundleIdentifier: nil,
                focusedElementIdentity: nil
            )
        }

        AXUIElementSetMessagingTimeout(focusedApplication, Float(max(0.01, timeout)))
        var processID: pid_t = 0
        guard AXUIElementGetPid(focusedApplication, &processID) == .success else {
            return HaloFocusedDestinationSnapshot(
                processID: nil,
                applicationName: nil,
                bundleIdentifier: nil,
                focusedElementIdentity: nil
            )
        }

        let focusedElement = copyElement(kAXFocusedUIElementAttribute, from: focusedApplication)
        let application = NSRunningApplication(processIdentifier: processID)
        return HaloFocusedDestinationSnapshot(
            processID: processID,
            applicationName: application?.localizedName,
            bundleIdentifier: application?.bundleIdentifier,
            focusedElementIdentity: focusedElement.map(focusedElementToken)
        )
    }

    func resolve(
        destinationPID: pid_t?,
        applicationName: String?,
        screens: [HaloScreenGeometry],
        preferredFallbackScreenID: String? = nil,
        fallbackPointerLocation: CGPoint? = nil,
        allowSystemFocusedDestination: Bool = true,
        timeout: TimeInterval = defaultTimeout
    ) async -> HaloCaretAnchor {
        guard !screens.isEmpty else {
            return Self.fallback(
                destinationPID: destinationPID,
                applicationName: applicationName,
                screens: screens,
                preferredScreenID: preferredFallbackScreenID
            )
        }

        let startedAt = ContinuousClock.now
        return await withCheckedContinuation { continuation in
            let gate = HaloCompletionGate(continuation: continuation)
            let frontmostFallback = HaloFocusedDestinationSnapshot(
                processID: destinationPID,
                applicationName: applicationName,
                bundleIdentifier: destinationPID.flatMap {
                    NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
                },
                focusedElementIdentity: nil
            )

            lookupQueue.async {
                let systemFocused = self.usesSystemFocusedDestination && allowSystemFocusedDestination
                    ? Self.focusedDestinationSnapshot(timeout: min(0.04, timeout * 0.20))
                    : frontmostFallback
                let destination = HaloDestinationSelection.preferred(
                    systemFocused: systemFocused,
                    frontmostFallback: frontmostFallback,
                    currentProcessID: ProcessInfo.processInfo.processIdentifier
                )
                let result = self.lookupOperation(
                    destination.processID,
                    destination.applicationName,
                    screens,
                    timeout
                )
                let normalizedResult = Self.normalizingApproximateAnchor(
                    result,
                    pointerLocation: fallbackPointerLocation,
                    screens: screens
                )
                let didPublish = gate.complete(
                    with: Self.applyingPreferredFallbackScreen(
                        to: normalizedResult,
                        preferredScreenID: preferredFallbackScreenID,
                        screens: screens
                    )
                )
                if didPublish {
                    let elapsed = startedAt.duration(to: .now)
                    Self.logger.debug(
                        "Resolved Halo anchor source=\(normalizedResult.source.diagnosticLabel, privacy: .public) quality=\(normalizedResult.quality.diagnosticLabel, privacy: .public) elapsed=\(String(describing: elapsed), privacy: .public)"
                    )
                }
            }

            // If a third-party editor stalls on range queries, race a bounded
            // container-only lookup after a short grace period. This preserves
            // useful element/window geometry instead of dropping straight to
            // screen bottom-center at the outer deadline.
            if self.usesSystemFocusedDestination {
                let gracePeriod = min(0.06, max(0.02, timeout * 0.33))
                self.lookupQueue.asyncAfter(deadline: .now() + gracePeriod) {
                    let systemFocused = allowSystemFocusedDestination
                        ? Self.focusedDestinationSnapshot(timeout: min(0.03, timeout * 0.16))
                        : frontmostFallback
                    let destination = HaloDestinationSelection.preferred(
                        systemFocused: systemFocused,
                        frontmostFallback: frontmostFallback,
                        currentProcessID: ProcessInfo.processInfo.processIdentifier
                    )
                    let approximate = Self.performApproximateLookup(
                        destinationPID: destination.processID,
                        applicationName: destination.applicationName,
                        screens: screens,
                        timeout: min(0.05, max(0.02, timeout - gracePeriod))
                    )
                    guard approximate.source != .screenFallback else { return }
                    let normalized = Self.normalizingApproximateAnchor(
                        approximate,
                        pointerLocation: fallbackPointerLocation,
                        screens: screens
                    )
                    let didPublish = gate.complete(
                        with: Self.applyingPreferredFallbackScreen(
                            to: normalized,
                            preferredScreenID: preferredFallbackScreenID,
                            screens: screens
                        )
                    )
                    if didPublish {
                        Self.logger.debug(
                            "Resolved Halo anchor through bounded approximate lookup source=\(normalized.source.diagnosticLabel, privacy: .public)"
                        )
                    }
                }
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0.01, timeout)) {
                let didPublish = gate.complete(
                    with: Self.fallback(
                        destinationPID: destinationPID,
                        applicationName: applicationName,
                        screens: screens,
                        preferredScreenID: preferredFallbackScreenID
                    )
                )
                if didPublish {
                    Self.logger.debug(
                        "Halo anchor deadline reached timeoutMs=\(Int(timeout * 1_000), privacy: .public)"
                    )
                }
            }
        }
    }

    static func reconvertedAnchor(
        _ anchor: HaloCaretAnchor,
        screens: [HaloScreenGeometry]
    ) -> HaloCaretAnchor {
        guard let accessibilityRect = anchor.accessibilityRect,
            let primary = screens.first(where: \.isPrimary) ?? screens.first
        else {
            return HaloCaretAnchor(
                destinationPID: anchor.destinationPID,
                applicationName: anchor.applicationName,
                bundleIdentifier: anchor.bundleIdentifier,
                focusedElementIdentity: anchor.focusedElementIdentity,
                source: anchor.source,
                accessibilityRect: anchor.accessibilityRect,
                appKitRect: nil,
                screenID: screens.first(where: { $0.id == anchor.screenID })?.id
                    ?? screens.first(where: \.isPrimary)?.id
                    ?? screens.first?.id
            )
        }

        let appKitRect = HaloPanelPositioner.appKitRect(
            fromAccessibilityRect: accessibilityRect,
            primaryScreenFrame: primary.frame
        )
        let screenID = HaloPanelPositioner.screen(for: appKitRect, in: screens)?.id
        return HaloCaretAnchor(
            destinationPID: anchor.destinationPID,
            applicationName: anchor.applicationName,
            bundleIdentifier: anchor.bundleIdentifier,
            focusedElementIdentity: anchor.focusedElementIdentity,
            source: anchor.source,
            accessibilityRect: accessibilityRect,
            appKitRect: appKitRect,
            screenID: screenID
        )
    }

    private static func performLookup(
        destinationPID: pid_t?,
        applicationName: String?,
        screens: [HaloScreenGeometry],
        timeout: TimeInterval
    ) -> HaloCaretAnchor {
        guard AXIsProcessTrusted(),
            let destinationPID,
            let primaryScreen = screens.first(where: \.isPrimary) ?? screens.first
        else {
            return fallback(
                destinationPID: destinationPID,
                applicationName: applicationName,
                screens: screens,
                preferredScreenID: nil
            )
        }

        let appElement = AXUIElementCreateApplication(destinationPID)
        let perCallTimeout = min(0.05, max(0.02, timeout * 0.16))
        AXUIElementSetMessagingTimeout(appElement, Float(perCallTimeout))

        let focusedElement = copyElement(kAXFocusedUIElementAttribute, from: appElement)
        if let focusedElement {
            AXUIElementSetMessagingTimeout(focusedElement, Float(perCallTimeout))
        }
        let textElement = focusedElement.flatMap {
            closestTextElement(startingAt: $0, messagingTimeout: perCallTimeout)
        }
        if let textElement {
            AXUIElementSetMessagingTimeout(textElement, Float(perCallTimeout))
        }

        let focusedElementIdentity = focusedElement.map(focusedElementToken)
        let runningApplication = NSRunningApplication(processIdentifier: destinationPID)
        var cachedTextElementFrame: CGRect?
        var didReadTextElementFrame = false
        func textElementFrame() -> CGRect? {
            if !didReadTextElementFrame {
                didReadTextElementFrame = true
                cachedTextElementFrame = textElement
                    .flatMap { frame(of: $0) }
                    .flatMap { frame in
                        HaloCaretBoundsValidator.isPlausibleContainerFrame(
                            frame,
                            primaryScreenFrame: primaryScreen.frame,
                            screens: screens
                        ) ? frame : nil
                    }
            }
            return cachedTextElementFrame
        }

        var cachedFocusedWindowFrame: CGRect?
        var didReadFocusedWindowFrame = false
        func focusedWindowFrame() -> CGRect? {
            if !didReadFocusedWindowFrame {
                didReadFocusedWindowFrame = true
                if let focusedWindow = copyElement(kAXFocusedWindowAttribute, from: appElement) {
                    AXUIElementSetMessagingTimeout(focusedWindow, Float(perCallTimeout))
                    cachedFocusedWindowFrame = frame(of: focusedWindow).flatMap { frame in
                        HaloCaretBoundsValidator.isPlausibleContainerFrame(
                            frame,
                            primaryScreenFrame: primaryScreen.frame,
                            screens: screens
                        ) ? frame : nil
                    }
                }
            }
            return cachedFocusedWindowFrame
        }

        func validatedBounds(for range: CFRange) -> CGRect? {
            guard let textElement,
                let rect = bounds(for: range, in: textElement),
                HaloCaretBoundsValidator.isPlausibleTextBounds(
                    rect,
                    containerAccessibilityFrame: textElementFrame(),
                    primaryScreenFrame: primaryScreen.frame,
                    screens: screens
                )
            else {
                return nil
            }
            return rect
        }

        let resolved = HaloCaretFallbackResolver.resolve(
            using: HaloCaretLookupSteps(
                selectedRange: {
                    textElement.flatMap { copyRange(kAXSelectedTextRangeAttribute, from: $0) }
                },
                boundsForRange: { range in
                    validatedBounds(for: range)
                },
                focusedCharacterCount: {
                    textElement.flatMap { copyInteger(kAXNumberOfCharactersAttribute, from: $0) }
                },
                insertionLineBounds: { caretLocation in
                    guard let textElement,
                        let rect = insertionLineCaretRect(
                            caretLocation: caretLocation,
                            in: textElement,
                            boundsReader: { bounds(for: $0, in: textElement) }
                        ),
                        HaloCaretBoundsValidator.isPlausibleTextBounds(
                            rect,
                            containerAccessibilityFrame: textElementFrame(),
                            primaryScreenFrame: primaryScreen.frame,
                            screens: screens
                        )
                    else {
                        return nil
                    }
                    return rect
                },
                focusedElementIsTextCapable: {
                    textElement != nil
                },
                focusedElementFrame: {
                    textElementFrame()
                },
                focusedWindowFrame: {
                    focusedWindowFrame()
                }
            )
        )

        if let resolved {
            return makeAnchor(
                rect: resolved.rect,
                source: resolved.source,
                destinationPID: destinationPID,
                applicationName: runningApplication?.localizedName ?? applicationName,
                bundleIdentifier: runningApplication?.bundleIdentifier,
                focusedElementIdentity: focusedElementIdentity,
                primaryScreen: primaryScreen,
                screens: screens
            )
        }

        return fallback(
            destinationPID: destinationPID,
            applicationName: runningApplication?.localizedName ?? applicationName,
            bundleIdentifier: runningApplication?.bundleIdentifier,
            focusedElementIdentity: focusedElementIdentity,
            screens: screens,
            preferredScreenID: nil
        )
    }

    private static func performApproximateLookup(
        destinationPID: pid_t?,
        applicationName: String?,
        screens: [HaloScreenGeometry],
        timeout: TimeInterval
    ) -> HaloCaretAnchor {
        guard AXIsProcessTrusted(),
            let destinationPID,
            let primaryScreen = screens.first(where: \.isPrimary) ?? screens.first
        else {
            return fallback(
                destinationPID: destinationPID,
                applicationName: applicationName,
                screens: screens,
                preferredScreenID: nil
            )
        }

        let appElement = AXUIElementCreateApplication(destinationPID)
        let perCallTimeout = min(0.025, max(0.01, timeout * 0.30))
        AXUIElementSetMessagingTimeout(appElement, Float(perCallTimeout))
        let focusedElement = copyElement(kAXFocusedUIElementAttribute, from: appElement)
        if let focusedElement {
            AXUIElementSetMessagingTimeout(focusedElement, Float(perCallTimeout))
        }
        let focusedElementIdentity = focusedElement.map(focusedElementToken)
        let runningApplication = NSRunningApplication(processIdentifier: destinationPID)

        if let textElement = focusedElement.flatMap({
            closestTextElement(startingAt: $0, messagingTimeout: perCallTimeout)
        }) {
            AXUIElementSetMessagingTimeout(textElement, Float(perCallTimeout))
            if let textFrame = frame(of: textElement),
                HaloCaretBoundsValidator.isPlausibleContainerFrame(
                    textFrame,
                    primaryScreenFrame: primaryScreen.frame,
                    screens: screens
                )
            {
                return makeAnchor(
                    rect: textFrame,
                    source: .focusedTextElement,
                    destinationPID: destinationPID,
                    applicationName: runningApplication?.localizedName ?? applicationName,
                    bundleIdentifier: runningApplication?.bundleIdentifier,
                    focusedElementIdentity: focusedElementIdentity,
                    primaryScreen: primaryScreen,
                    screens: screens
                )
            }
        }

        if let focusedWindow = copyElement(kAXFocusedWindowAttribute, from: appElement) {
            AXUIElementSetMessagingTimeout(focusedWindow, Float(perCallTimeout))
            if let windowFrame = frame(of: focusedWindow),
                HaloCaretBoundsValidator.isPlausibleContainerFrame(
                    windowFrame,
                    primaryScreenFrame: primaryScreen.frame,
                    screens: screens
                )
            {
                return makeAnchor(
                    rect: windowFrame,
                    source: .focusedWindow,
                    destinationPID: destinationPID,
                    applicationName: runningApplication?.localizedName ?? applicationName,
                    bundleIdentifier: runningApplication?.bundleIdentifier,
                    focusedElementIdentity: focusedElementIdentity,
                    primaryScreen: primaryScreen,
                    screens: screens
                )
            }
        }

        return fallback(
            destinationPID: destinationPID,
            applicationName: runningApplication?.localizedName ?? applicationName,
            bundleIdentifier: runningApplication?.bundleIdentifier,
            focusedElementIdentity: focusedElementIdentity,
            screens: screens,
            preferredScreenID: nil
        )
    }

    private static func closestTextElement(
        startingAt focusedElement: AXUIElement,
        messagingTimeout: TimeInterval
    ) -> AXUIElement? {
        var candidate: AXUIElement? = focusedElement
        for _ in 0..<5 {
            guard let current = candidate else { return nil }
            AXUIElementSetMessagingTimeout(current, Float(max(0.01, messagingTimeout)))
            if isTextCapable(current) {
                return current
            }
            candidate = copyElement(kAXParentAttribute, from: current)
        }
        return nil
    }

    private static func isTextCapable(_ element: AXUIElement) -> Bool {
        if let role = copyString(kAXRoleAttribute, from: element) {
            switch role {
            case kAXTextFieldRole, kAXTextAreaRole, "AXComboBox":
                return true
            default:
                break
            }
        }

        if copyBoolean(kAXIsEditableAttribute, from: element) == true {
            return true
        }

        var attributeNames: CFArray?
        guard AXUIElementCopyAttributeNames(element, &attributeNames) == .success,
            let names = attributeNames as? [String]
        else {
            return false
        }
        return names.contains(kAXSelectedTextRangeAttribute)
    }

    private static func insertionLineCaretRect(
        caretLocation: CFIndex,
        in element: AXUIElement,
        boundsReader: (CFRange) -> CGRect?
    ) -> CGRect? {
        guard let lineNumber = copyInteger(kAXInsertionPointLineNumberAttribute, from: element),
            let lineRange = range(forLine: lineNumber, in: element),
            let lineBounds = boundsReader(lineRange)
        else {
            return nil
        }

        let caretOffset = max(0, min(caretLocation - lineRange.location, lineRange.length))
        let x: CGFloat
        if caretOffset > 0,
            let prefixBounds = boundsReader(
                CFRange(location: lineRange.location, length: caretOffset)
            )
        {
            x = prefixBounds.maxX
        } else {
            x = lineBounds.minX
        }
        return CGRect(x: x, y: lineBounds.minY, width: 0, height: lineBounds.height)
    }

    private static func makeAnchor(
        rect accessibilityRect: CGRect,
        source: HaloCaretAnchorSource,
        destinationPID: pid_t,
        applicationName: String?,
        bundleIdentifier: String?,
        focusedElementIdentity: UInt?,
        primaryScreen: HaloScreenGeometry,
        screens: [HaloScreenGeometry]
    ) -> HaloCaretAnchor {
        let appKitRect = HaloPanelPositioner.appKitRect(
            fromAccessibilityRect: accessibilityRect,
            primaryScreenFrame: primaryScreen.frame
        )
        return HaloCaretAnchor(
            destinationPID: destinationPID,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            focusedElementIdentity: focusedElementIdentity,
            source: source,
            accessibilityRect: accessibilityRect,
            appKitRect: appKitRect,
            screenID: HaloPanelPositioner.screen(for: appKitRect, in: screens)?.id
        )
    }

    private static func fallback(
        destinationPID: pid_t?,
        applicationName: String?,
        bundleIdentifier: String? = nil,
        focusedElementIdentity: UInt? = nil,
        screens: [HaloScreenGeometry],
        preferredScreenID: String?
    ) -> HaloCaretAnchor {
        HaloCaretAnchor(
            destinationPID: destinationPID,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            focusedElementIdentity: focusedElementIdentity,
            source: .screenFallback,
            accessibilityRect: nil,
            appKitRect: nil,
            screenID: preferredScreenID.flatMap { preferredID in
                screens.first(where: { $0.id == preferredID })?.id
            } ?? screens.first(where: \.isPrimary)?.id ?? screens.first?.id
        )
    }

    private static func applyingPreferredFallbackScreen(
        to anchor: HaloCaretAnchor,
        preferredScreenID: String?,
        screens: [HaloScreenGeometry]
    ) -> HaloCaretAnchor {
        guard anchor.source == .screenFallback,
            let preferredScreenID,
            screens.contains(where: { $0.id == preferredScreenID })
        else {
            return anchor
        }

        return HaloCaretAnchor(
            destinationPID: anchor.destinationPID,
            applicationName: anchor.applicationName,
            bundleIdentifier: anchor.bundleIdentifier,
            focusedElementIdentity: anchor.focusedElementIdentity,
            source: anchor.source,
            accessibilityRect: anchor.accessibilityRect,
            appKitRect: anchor.appKitRect,
            screenID: preferredScreenID
        )
    }

    private static func normalizingApproximateAnchor(
        _ anchor: HaloCaretAnchor,
        pointerLocation: CGPoint?,
        screens: [HaloScreenGeometry]
    ) -> HaloCaretAnchor {
        guard anchor.source == .focusedTextElement || anchor.source == .focusedWindow,
            let containerRect = anchor.appKitRect,
            let primary = screens.first(where: \.isPrimary) ?? screens.first
        else {
            return anchor
        }

        let appKitRect = HaloApproximateAnchorGeometry.normalizedAppKitRect(
            containerRect: containerRect,
            pointerLocation: pointerLocation,
            source: anchor.source
        )
        let accessibilityRect = HaloApproximateAnchorGeometry.accessibilityRect(
            fromAppKitRect: appKitRect,
            primaryScreenFrame: primary.frame
        )
        return HaloCaretAnchor(
            destinationPID: anchor.destinationPID,
            applicationName: anchor.applicationName,
            bundleIdentifier: anchor.bundleIdentifier,
            focusedElementIdentity: anchor.focusedElementIdentity,
            source: anchor.source,
            accessibilityRect: accessibilityRect,
            appKitRect: appKitRect,
            screenID: HaloPanelPositioner.screen(for: appKitRect, in: screens)?.id
        )
    }

    private static func bounds(for range: CFRange, in element: AXUIElement) -> CGRect? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }

        var rawBounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &rawBounds
        ) == .success,
            let rawBounds,
            CFGetTypeID(rawBounds) == AXValueGetTypeID()
        else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(rawBounds as! AXValue, .cgRect, &rect), isUsable(rect) else {
            return nil
        }
        return rect
    }

    private static func range(forLine lineNumber: Int, in element: AXUIElement) -> CFRange? {
        let parameter = NSNumber(value: lineNumber)
        var rawRange: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXRangeForLineParameterizedAttribute as CFString,
            parameter,
            &rawRange
        ) == .success,
            let rawRange,
            CFGetTypeID(rawRange) == AXValueGetTypeID(),
            AXValueGetType(rawRange as! AXValue) == .cfRange
        else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(rawRange as! AXValue, .cfRange, &range),
            range.location != kCFNotFound,
            range.location >= 0,
            range.length >= 0
        else {
            return nil
        }
        return range
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = copyPoint(kAXPositionAttribute, from: element),
            let size = copySize(kAXSizeAttribute, from: element)
        else {
            return nil
        }

        let rect = CGRect(origin: position, size: size)
        return isUsable(rect) ? rect : nil
    }

    private static func copyElement(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
            let rawValue,
            CFGetTypeID(rawValue) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (rawValue as! AXUIElement)
    }

    private static func copyRange(_ attribute: String, from element: AXUIElement) -> CFRange? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
            let rawValue,
            CFGetTypeID(rawValue) == AXValueGetTypeID(),
            AXValueGetType(rawValue as! AXValue) == .cfRange
        else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(rawValue as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func copyString(_ attribute: String, from element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }
        return rawValue as? String
    }

    private static func copyInteger(_ attribute: String, from element: AXUIElement) -> Int? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
            let number = rawValue as? NSNumber
        else {
            return nil
        }
        return number.intValue
    }

    private static func copyBoolean(_ attribute: String, from element: AXUIElement) -> Bool? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
            let number = rawValue as? NSNumber
        else {
            return nil
        }
        return number.boolValue
    }

    private static func focusedElementToken(_ element: AXUIElement) -> UInt {
        UInt(CFHash(element))
    }

    private static func copyPoint(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
            let rawValue,
            CFGetTypeID(rawValue) == AXValueGetTypeID(),
            AXValueGetType(rawValue as! AXValue) == .cgPoint
        else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(rawValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func copySize(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
            let rawValue,
            CFGetTypeID(rawValue) == AXValueGetTypeID(),
            AXValueGetType(rawValue as! AXValue) == .cgSize
        else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(rawValue as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.isHaloUsable
    }
}

private final class HaloCompletionGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func complete(with value: Value) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
        return continuation != nil
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    var isHaloUsable: Bool {
        let values = [minX, minY, width, height]
        return values.allSatisfy(\.isFinite) && height > 0 && width >= 0
    }

    func containsVertically(_ other: CGRect) -> Bool {
        other.minY >= minY && other.maxY <= maxY
    }
}

private extension NSScreen {
    var haloDisplayID: String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = deviceDescription[key] as? NSNumber {
            return number.stringValue
        }
        return "screen-\(frame.origin.x)-\(frame.origin.y)-\(frame.width)-\(frame.height)"
    }
}
