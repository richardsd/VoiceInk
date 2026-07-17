import CoreGraphics
import Testing
@testable import VoiceInk

struct HaloPresentationLayoutTests {
    @Test func listeningUsesCompactSizeUntilTheFirstVisiblePartialArrives() {
        #expect(
            HaloPanelMetrics.size(
                for: .listening,
                hasVisiblePartialTranscript: false
            ) == CGSize(width: 240, height: 48)
        )
        #expect(
            HaloPanelMetrics.size(
                for: .listening,
                hasVisiblePartialTranscript: true
            ) == CGSize(width: 360, height: 124)
        )
    }

    @Test func processingAndReviewPhasesIgnoreStalePartialTranscriptState() {
        #expect(
            HaloPanelMetrics.size(
                for: .transcribing,
                hasVisiblePartialTranscript: true
            ) == CGSize(width: 240, height: 48)
        )
        #expect(
            HaloPanelMetrics.size(
                for: .enhancing,
                hasVisiblePartialTranscript: true
            ) == CGSize(width: 320, height: 72)
        )
        #expect(
            HaloPanelMetrics.size(
                for: .reviewing,
                hasVisiblePartialTranscript: true
            ) == CGSize(width: 500, height: 380)
        )
        #expect(
            HaloPanelMetrics.size(
                for: .confirmed,
                hasVisiblePartialTranscript: true
            ) == CGSize(width: 132, height: 44)
        )
    }

    @Test func refinementOrbitUsesTheFiveProductActionsInOrder() {
        #expect(
            HaloRefinementOrbitPolicy.actions == [
                .shorter,
                .clearer,
                .friendlier,
                .formal,
                .fixTerms,
            ]
        )
        #expect(HaloRefinementOrbitPolicy.actions.count == 5)
    }

    @Test func refinementOrbitDisablesEveryActionDuringRefinementDeliveryOrAtTheLimit() {
        #expect(
            HaloRefinementOrbitPolicy.actionsAreEnabled(
                canRefine: true,
                isRefining: false,
                isDelivering: false
            )
        )
        #expect(
            !HaloRefinementOrbitPolicy.actionsAreEnabled(
                canRefine: false,
                isRefining: false,
                isDelivering: false
            )
        )
        #expect(
            !HaloRefinementOrbitPolicy.actionsAreEnabled(
                canRefine: true,
                isRefining: true,
                isDelivering: false
            )
        )
        #expect(
            !HaloRefinementOrbitPolicy.actionsAreEnabled(
                canRefine: true,
                isRefining: false,
                isDelivering: true
            )
        )
    }

    @Test func refinementOrbitUsesHorizontalOverflowWithoutGrowingTheReviewPanel() {
        // The 500-point review panel leaves approximately 468 points after
        // its outer and content insets. Compact CJK labels remain inline,
        // while long localized labels retain their full width and scroll.
        let availableWidth: CGFloat = 468
        let compactChineseActionWidths: [CGFloat] = [38, 42, 52, 40, 62]
        let longGermanActionWidths: [CGFloat] = [58, 60, 100, 58, 190]

        #expect(
            !HaloRefinementOrbitPolicy.requiresHorizontalScrolling(
                actionWidths: compactChineseActionWidths,
                availableWidth: availableWidth
            )
        )
        #expect(
            HaloRefinementOrbitPolicy.requiresHorizontalScrolling(
                actionWidths: longGermanActionWidths,
                availableWidth: availableWidth
            )
        )
        #expect(HaloRefinementOrbitPolicy.rowHeight == 28)
        #expect(HaloPanelMetrics.review == CGSize(width: 500, height: 380))
        #expect(HaloPanelMetrics.focusRecovery == CGSize(width: 380, height: 76))
    }
}
