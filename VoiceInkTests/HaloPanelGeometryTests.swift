import CoreGraphics
import Foundation
import Testing
@testable import VoiceInk

struct HaloPanelGeometryTests {
    private let primary = HaloScreenGeometry(
        id: "primary",
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 852),
        isPrimary: true
    )

    @Test func convertsAccessibilityTopLeftCoordinatesToAppKitCoordinates() {
        let converted = HaloPanelPositioner.appKitRect(
            fromAccessibilityRect: CGRect(x: 120, y: 200, width: 2, height: 20),
            primaryScreenFrame: primary.frame
        )

        #expect(converted == CGRect(x: 120, y: 680, width: 2, height: 20))
    }

    @Test func convertsCoordinatesForDisplaysAboveAndBelowPrimary() {
        let above = HaloPanelPositioner.appKitRect(
            fromAccessibilityRect: CGRect(x: 200, y: -100, width: 0, height: 20),
            primaryScreenFrame: primary.frame
        )
        let below = HaloPanelPositioner.appKitRect(
            fromAccessibilityRect: CGRect(x: 200, y: 1_000, width: 0, height: 20),
            primaryScreenFrame: primary.frame
        )

        #expect(above == CGRect(x: 200, y: 980, width: 0, height: 20))
        #expect(below == CGRect(x: 200, y: -120, width: 0, height: 20))
    }

    @Test func selectsScreenByLargestIntersectionWithNegativeMonitorOrigins() throws {
        let left = HaloScreenGeometry(
            id: "left",
            frame: CGRect(x: -1920, y: -180, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: -180, width: 1920, height: 1056),
            isPrimary: false
        )

        let selected = try #require(
            HaloPanelPositioner.screen(
                for: CGRect(x: -220, y: 100, width: 300, height: 40),
                in: [primary, left]
            )
        )
        #expect(selected.id == "left")
    }

    @Test func prefersTwelvePointsAboveCaretWhenItFits() throws {
        let placement = try #require(
            HaloPanelPositioner.placement(
                panelSize: CGSize(width: 240, height: 48),
                anchorRect: CGRect(x: 600, y: 350, width: 2, height: 20),
                preferredScreenID: nil,
                screens: [primary]
            )
        )

        #expect(placement.isAboveAnchor)
        #expect(placement.frame.minY == 382)
        #expect(placement.frame.midX == 601)
    }

    @Test func placesBelowCaretWhenAboveWouldCrossVisibleFrame() throws {
        let placement = try #require(
            HaloPanelPositioner.placement(
                panelSize: CGSize(width: 240, height: 48),
                anchorRect: CGRect(x: 700, y: 850, width: 2, height: 18),
                preferredScreenID: nil,
                screens: [primary]
            )
        )

        #expect(!placement.isAboveAnchor)
        #expect(placement.frame.maxY == 838)
    }

    @Test func clampsHorizontalPlacementToVisibleFrameInset() throws {
        let placement = try #require(
            HaloPanelPositioner.placement(
                panelSize: CGSize(width: 420, height: 240),
                anchorRect: CGRect(x: 2, y: 350, width: 2, height: 20),
                preferredScreenID: nil,
                screens: [primary]
            )
        )

        #expect(placement.frame.minX == 12)
        #expect(placement.frame.maxX <= primary.visibleFrame.maxX - 12)
    }

    @Test func screenFallbackUsesBottomCenterWithTwelvePointInset() throws {
        let placement = try #require(
            HaloPanelPositioner.placement(
                panelSize: CGSize(width: 240, height: 48),
                anchorRect: nil,
                preferredScreenID: "primary",
                screens: [primary]
            )
        )

        #expect(placement.frame.midX == primary.visibleFrame.midX)
        #expect(placement.frame.minY == primary.visibleFrame.minY + 12)
    }

    @Test func stableSideReservesRoomForExpandedReview() throws {
        let anchor = CGRect(x: 600, y: 700, width: 2, height: 20)
        let side = try #require(
            HaloPanelPositioner.stableSide(
                anchorRect: anchor,
                preferredScreenID: nil,
                maximumPanelHeight: 380,
                screens: [primary]
            )
        )
        #expect(side == .below)

        let compact = try #require(
            HaloPanelPositioner.placement(
                panelSize: CGSize(width: 240, height: 48),
                anchorRect: anchor,
                preferredScreenID: nil,
                preferredSide: side,
                screens: [primary]
            )
        )
        let expanded = try #require(
            HaloPanelPositioner.placement(
                panelSize: CGSize(width: 500, height: 380),
                anchorRect: anchor,
                preferredScreenID: nil,
                preferredSide: side,
                screens: [primary]
            )
        )

        #expect(!compact.isAboveAnchor)
        #expect(!expanded.isAboveAnchor)
        #expect(compact.frame.maxY == anchor.minY - HaloPanelPositioner.anchorGap)
        #expect(expanded.frame.maxY == anchor.minY - HaloPanelPositioner.anchorGap)
    }

    @Test func collapsesMultilineSelectionAtItsTrailingCaret() throws {
        let collapsed = try #require(
            HaloCaretRangeStrategy.collapsedRange(
                from: CFRange(location: 21, length: 9)
            )
        )
        #expect(collapsed.location == 30)
        #expect(collapsed.length == 0)
    }

    @Test func nearestGlyphHandlesDocumentStartAndEnd() {
        let atStart = HaloCaretRangeStrategy.nearestGlyphRanges(caretLocation: 0, valueLength: 4)
        #expect(atStart.count == 1)
        #expect(atStart.first?.location == 0)
        #expect(atStart.first?.length == 1)

        let atEnd = HaloCaretRangeStrategy.nearestGlyphRanges(caretLocation: 4, valueLength: 4)
        #expect(atEnd.count == 1)
        #expect(atEnd.first?.location == 3)
        #expect(atEnd.first?.length == 1)

        let inMiddle = HaloCaretRangeStrategy.nearestGlyphRanges(caretLocation: 2, valueLength: 4)
        #expect(inMiddle.map(\.location) == [2, 1])
    }

    @Test func glyphInsertionUsesCurrentVisualLineAcrossWrap() throws {
        let previousLineGlyph = CGRect(x: 400, y: 100, width: 8, height: 18)
        let currentLineGlyph = CGRect(x: 20, y: 122, width: 7, height: 18)
        let caret = try #require(
            HaloCaretInsertionGeometry.caretRect(
                previousGlyph: previousLineGlyph,
                nextGlyph: currentLineGlyph
            )
        )

        #expect(caret == CGRect(x: 20, y: 122, width: 0, height: 18))
    }

    @Test func glyphInsertionFindsSharedBoundaryForBidirectionalGeometry() throws {
        let logicalPrevious = CGRect(x: 80, y: 100, width: 8, height: 18)
        let logicalNext = CGRect(x: 72, y: 100, width: 8, height: 18)
        let caret = try #require(
            HaloCaretInsertionGeometry.caretRect(
                previousGlyph: logicalPrevious,
                nextGlyph: logicalNext
            )
        )

        #expect(caret.minX == 80)
        #expect(caret.width == 0)
    }

    @Test func accessibilityFallbackPrefersCollapsedCaretBounds() throws {
        var calls: [String] = []
        let caretRect = CGRect(x: 20, y: 30, width: 1, height: 18)
        let resolved = try #require(
            HaloCaretFallbackResolver.resolve(
                using: HaloCaretLookupSteps(
                    selectedRange: {
                        calls.append("range")
                        return CFRange(location: 4, length: 0)
                    },
                    boundsForRange: { range in
                        calls.append("bounds:\(range.location):\(range.length)")
                        return caretRect
                    },
                    focusedCharacterCount: {
                        calls.append("length")
                        return 8
                    },
                    insertionLineBounds: { _ in nil },
                    focusedElementIsTextCapable: {
                        calls.append("text-role")
                        return true
                    },
                    focusedElementFrame: {
                        calls.append("text-frame")
                        return .zero
                    },
                    focusedWindowFrame: {
                        calls.append("window-frame")
                        return .zero
                    }
                )
            )
        )

        #expect(resolved.source == .collapsedSelection)
        #expect(resolved.rect == caretRect)
        #expect(calls == ["range", "bounds:4:0"])
    }

    @Test func accessibilityFallbackUsesNearestGlyphBeforeElementFrame() throws {
        var requestedRanges: [CFRange] = []
        let glyphRect = CGRect(x: 12, y: 16, width: 7, height: 18)
        let resolved = try #require(
            HaloCaretFallbackResolver.resolve(
                using: HaloCaretLookupSteps(
                    selectedRange: { CFRange(location: 4, length: 0) },
                    boundsForRange: { range in
                        requestedRanges.append(range)
                        return range.length == 1 && range.location == 3 ? glyphRect : nil
                    },
                    focusedCharacterCount: { 9 },
                    insertionLineBounds: { _ in nil },
                    focusedElementIsTextCapable: { true },
                    focusedElementFrame: { CGRect(x: 0, y: 0, width: 100, height: 30) },
                    focusedWindowFrame: { CGRect(x: 0, y: 0, width: 500, height: 400) }
                )
            )
        )

        #expect(resolved.source == .nearestGlyph)
        #expect(resolved.rect == CGRect(x: glyphRect.maxX, y: glyphRect.minY, width: 0, height: glyphRect.height))
        #expect(requestedRanges.count == 3)
        #expect(requestedRanges[0].location == 4)
        #expect(requestedRanges[0].length == 0)
        #expect(requestedRanges[1].location == 4)
        #expect(requestedRanges[1].length == 1)
        #expect(requestedRanges[2].location == 3)
        #expect(requestedRanges[2].length == 1)
    }

    @Test func accessibilityFallbackUsesInsertionLineBeforeContainer() throws {
        let insertionLineCaret = CGRect(x: 140, y: 80, width: 0, height: 19)
        let resolved = try #require(
            HaloCaretFallbackResolver.resolve(
                using: HaloCaretLookupSteps(
                    selectedRange: { CFRange(location: 7, length: 0) },
                    boundsForRange: { _ in nil },
                    focusedCharacterCount: { 7 },
                    insertionLineBounds: { location in
                        #expect(location == 7)
                        return insertionLineCaret
                    },
                    focusedElementIsTextCapable: { true },
                    focusedElementFrame: { CGRect(x: 20, y: 60, width: 500, height: 300) },
                    focusedWindowFrame: { CGRect(x: 0, y: 0, width: 900, height: 700) }
                )
            )
        )

        #expect(resolved.source == .insertionLine)
        #expect(resolved.rect == insertionLineCaret)
    }

    @Test func accessibilityFallbackUsesTextFrameThenWindowFrame() throws {
        let textFrame = CGRect(x: 30, y: 40, width: 300, height: 80)
        let textResolved = try #require(
            HaloCaretFallbackResolver.resolve(
                using: HaloCaretLookupSteps(
                    selectedRange: { nil },
                    boundsForRange: { _ in nil },
                    focusedCharacterCount: { nil },
                    insertionLineBounds: { _ in nil },
                    focusedElementIsTextCapable: { true },
                    focusedElementFrame: { textFrame },
                    focusedWindowFrame: { CGRect(x: 0, y: 0, width: 900, height: 700) }
                )
            )
        )
        #expect(textResolved.source == .focusedTextElement)
        #expect(textResolved.rect == textFrame)

        var didReadNonTextFrame = false
        let windowFrame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let windowResolved = try #require(
            HaloCaretFallbackResolver.resolve(
                using: HaloCaretLookupSteps(
                    selectedRange: { nil },
                    boundsForRange: { _ in nil },
                    focusedCharacterCount: { nil },
                    insertionLineBounds: { _ in nil },
                    focusedElementIsTextCapable: { false },
                    focusedElementFrame: {
                        didReadNonTextFrame = true
                        return textFrame
                    },
                    focusedWindowFrame: { windowFrame }
                )
            )
        )
        #expect(!didReadNonTextFrame)
        #expect(windowResolved.source == .focusedWindow)
        #expect(windowResolved.rect == windowFrame)
    }

    @Test func accessibilityLookupReturnsAtDeadlineWhenBackendDoesNotRespond() async {
        let resolver = HaloCaretAnchorResolver { processID, applicationName, screens, _ in
            Thread.sleep(forTimeInterval: 0.20)
            return HaloCaretAnchor(
                destinationPID: processID,
                applicationName: applicationName,
                source: .focusedTextElement,
                accessibilityRect: CGRect(x: 10, y: 10, width: 10, height: 10),
                appKitRect: CGRect(x: 10, y: 10, width: 10, height: 10),
                screenID: screens.first?.id
            )
        }

        let startedAt = Date()
        let result = await resolver.resolve(
            destinationPID: 42,
            applicationName: "Slow AX app",
            screens: [primary],
            preferredFallbackScreenID: "primary",
            timeout: 0.02
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(result.source == .screenFallback)
        #expect(result.destinationPID == 42)
        #expect(result.screenID == "primary")
        #expect(elapsed < 0.12)
    }

    @Test func systemFocusedDestinationWinsUnlessItIsVoiceInk() {
        let frontmost = HaloFocusedDestinationSnapshot(
            processID: 41,
            applicationName: "Editor",
            bundleIdentifier: "example.editor",
            focusedElementIdentity: 100
        )
        let systemFocused = HaloFocusedDestinationSnapshot(
            processID: 42,
            applicationName: "Browser",
            bundleIdentifier: "example.browser",
            focusedElementIdentity: 200
        )

        #expect(
            HaloDestinationSelection.preferred(
                systemFocused: systemFocused,
                frontmostFallback: frontmost,
                currentProcessID: 99
            ) == systemFocused
        )
        #expect(
            HaloDestinationSelection.preferred(
                systemFocused: systemFocused,
                frontmostFallback: frontmost,
                currentProcessID: 42
            ) == frontmost
        )
    }

    @Test func rejectsImplausibleOrOffscreenCaretBounds() {
        let container = CGRect(x: 100, y: 100, width: 500, height: 300)
        #expect(
            HaloCaretBoundsValidator.isPlausibleTextBounds(
                CGRect(x: 160, y: 140, width: 0, height: 18),
                containerAccessibilityFrame: container,
                primaryScreenFrame: primary.frame,
                screens: [primary]
            )
        )
        #expect(
            !HaloCaretBoundsValidator.isPlausibleTextBounds(
                CGRect(x: 160, y: 140, width: 900, height: 18),
                containerAccessibilityFrame: container,
                primaryScreenFrame: primary.frame,
                screens: [primary]
            )
        )
        #expect(
            !HaloCaretBoundsValidator.isPlausibleTextBounds(
                CGRect(x: 4_000, y: 4_000, width: 0, height: 18),
                containerAccessibilityFrame: container,
                primaryScreenFrame: primary.frame,
                screens: [primary]
            )
        )
        #expect(
            !HaloCaretBoundsValidator.isPlausibleContainerFrame(
                CGRect(x: 3_000, y: 3_000, width: 600, height: 400),
                primaryScreenFrame: primary.frame,
                screens: [primary]
            )
        )
    }

    @Test func approximateContainerUsesPointerOnlyWhenInsideDestination() {
        let container = CGRect(x: 100, y: 100, width: 600, height: 400)
        let nearPointer = HaloApproximateAnchorGeometry.normalizedAppKitRect(
            containerRect: container,
            pointerLocation: CGPoint(x: 180, y: 220),
            source: .focusedTextElement
        )
        let stalePointer = HaloApproximateAnchorGeometry.normalizedAppKitRect(
            containerRect: container,
            pointerLocation: CGPoint(x: 900, y: 800),
            source: .focusedTextElement
        )

        #expect(nearPointer.midX == 180)
        #expect(nearPointer.midY == 220)
        #expect(stalePointer.midX == container.midX)
        #expect(stalePointer.midY == container.midY)
    }

    @Test func qualityPolicyRetriesOnlyApproximateAnchorsAndAcceptsRefinement() {
        let approximate = HaloCaretAnchor(
            destinationPID: 7,
            applicationName: "Editor",
            focusedElementIdentity: 31,
            source: .focusedTextElement,
            accessibilityRect: CGRect(x: 100, y: 100, width: 0, height: 20),
            appKitRect: CGRect(x: 100, y: 780, width: 0, height: 20),
            screenID: "primary"
        )
        let precise = HaloCaretAnchor(
            destinationPID: 7,
            applicationName: "Editor",
            focusedElementIdentity: 31,
            source: .collapsedSelection,
            accessibilityRect: CGRect(x: 130, y: 120, width: 0, height: 20),
            appKitRect: CGRect(x: 130, y: 760, width: 0, height: 20),
            screenID: "primary"
        )

        #expect(approximate.quality.shouldRetry)
        #expect(!precise.quality.shouldRetry)
        #expect(precise.isHigherQuality(than: approximate))
        #expect(!approximate.isHigherQuality(than: precise))
        #expect(HaloCaretAnchorResolver.retryDelay == 0.12)
        #expect(HaloCaretAnchorResolver.retryTimeout == 0.30)
    }

    @Test func anchorSessionPreservesAndReconcilesSnapshotAcrossHiddenShellChanges() throws {
        var session = HaloAnchorSessionState()
        let sessionID = session.begin()
        let accessibilityRect = CGRect(x: 300, y: 200, width: 2, height: 18)
        let initial = HaloCaretAnchor(
            destinationPID: 77,
            applicationName: "Editor",
            bundleIdentifier: "example.editor",
            focusedElementIdentity: 912,
            source: .collapsedSelection,
            accessibilityRect: accessibilityRect,
            appKitRect: nil,
            screenID: "primary"
        )

        let acceptedInitialAnchor = session.accept(initial, for: sessionID, screens: [primary])
        #expect(acceptedInitialAnchor)
        let firstAnchor = try #require(session.anchor)

        let movedPrimary = HaloScreenGeometry(
            id: "replacement",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 24, width: 1920, height: 1032),
            isPrimary: true
        )
        // Visibility changes do not mutate the session. A display update while
        // Halo is hidden still reconverts the saved AX rectangle.
        session.reconcileDisplays([movedPrimary])
        let reconciled = try #require(session.anchor)

        #expect(session.id == sessionID)
        #expect(reconciled.destinationPID == firstAnchor.destinationPID)
        #expect(reconciled.bundleIdentifier == "example.editor")
        #expect(reconciled.focusedElementIdentity == 912)
        #expect(reconciled.accessibilityRect == accessibilityRect)
        #expect(reconciled.appKitRect != firstAnchor.appKitRect)
        #expect(reconciled.screenID == "replacement")
    }

    @Test func anchorSessionRejectsLateLookupFromPreviousRecording() {
        var session = HaloAnchorSessionState()
        let staleSessionID = session.begin()
        let currentSessionID = session.begin()
        let staleAnchor = HaloCaretAnchor(
            destinationPID: 88,
            applicationName: "Slow editor",
            source: .focusedWindow,
            accessibilityRect: CGRect(x: 0, y: 0, width: 500, height: 400),
            appKitRect: nil,
            screenID: "primary"
        )

        #expect(staleSessionID != currentSessionID)
        let acceptedStaleAnchor = session.accept(
            staleAnchor,
            for: staleSessionID,
            screens: [primary]
        )
        #expect(!acceptedStaleAnchor)
        #expect(session.anchor == nil)
    }

    @Test func haloPhaseRestoresCurrentPipelineStateWhenShellChanges() {
        #expect(HaloPresentationPhase.resolve(recordingState: .recording) == .listening)
        #expect(HaloPresentationPhase.resolve(recordingState: .transcribing) == .transcribing)
        #expect(HaloPresentationPhase.resolve(recordingState: .enhancing) == .enhancing)
        #expect(HaloPresentationPhase.resolve(recordingState: .reviewing) == .reviewing)
        #expect(HaloPresentationPhase.resolve(recordingState: .busy) == .transcribing)
    }
}
