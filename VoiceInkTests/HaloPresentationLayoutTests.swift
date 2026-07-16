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
}
