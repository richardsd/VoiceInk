import CoreGraphics
import Testing
@testable import VoiceInk

struct HaloInteractionTests {
    @Test func convertsAppKitBottomLeftPointIntoSwiftUITopLeftPoint() {
        let converted = HaloInteractionCoordinateConverter.swiftUIPoint(
            fromAppKitPoint: CGPoint(x: 32, y: 70),
            contentHeight: 380
        )

        #expect(converted == CGPoint(x: 32, y: 310))
    }

    @Test func hitTesterAcceptsPointsInsideAnyInteractiveRegion() {
        let regions = [
            HaloInteractionRegion.rectangle(CGRect(x: 10, y: 20, width: 80, height: 40)),
            HaloInteractionRegion.rectangle(CGRect(x: 180, y: 200, width: 60, height: 28)),
        ]

        #expect(HaloInteractionHitTester.contains(CGPoint(x: 45, y: 35), in: regions))
        #expect(HaloInteractionHitTester.contains(CGPoint(x: 200, y: 214), in: regions))
        #expect(!HaloInteractionHitTester.contains(CGPoint(x: 140, y: 110), in: regions))
    }

    @Test func hitTesterAllowsOnePointToleranceAtReportedEdges() {
        let regions = [
            HaloInteractionRegion.rectangle(CGRect(x: 20, y: 20, width: 40, height: 40))
        ]

        #expect(HaloInteractionHitTester.contains(CGPoint(x: 19.5, y: 40), in: regions))
        #expect(!HaloInteractionHitTester.contains(CGPoint(x: 18, y: 40), in: regions))
    }

    @Test func transparencyPolicyStaysClickThroughUntilReviewRegionsAreReady() {
        let button = HaloInteractionRegion.rectangle(
            CGRect(x: 20, y: 20, width: 80, height: 30)
        )

        #expect(
            HaloPanelMouseTransparencyPolicy.ignoresMouseEvents(
                interactionState: .inactive,
                pointer: CGPoint(x: 40, y: 30),
                interactiveRegions: [button]
            )
        )
        #expect(
            HaloPanelMouseTransparencyPolicy.ignoresMouseEvents(
                interactionState: .awaitingRegions,
                pointer: CGPoint(x: 40, y: 30),
                interactiveRegions: []
            )
        )
        #expect(
            !HaloPanelMouseTransparencyPolicy.ignoresMouseEvents(
                interactionState: .selective,
                pointer: CGPoint(x: 40, y: 30),
                interactiveRegions: [button]
            )
        )
        #expect(
            HaloPanelMouseTransparencyPolicy.ignoresMouseEvents(
                interactionState: .selective,
                pointer: CGPoint(x: 180, y: 80),
                interactiveRegions: [button]
            )
        )
        #expect(
            !HaloPanelMouseTransparencyPolicy.ignoresMouseEvents(
                interactionState: .wholePanelFallback,
                pointer: CGPoint(x: 180, y: 80),
                interactiveRegions: [button]
            )
        )
    }

    @Test func visibleRoundedReviewSurfaceAbsorbsBlankClicksButShadowMarginPassesThrough() {
        let surface = HaloInteractionRegion.roundedRectangle(
            CGRect(x: 10, y: 8, width: 500, height: 380),
            cornerRadius: 16
        )

        // Header, metadata, and otherwise blank surface areas all remain
        // inside the nonactivating panel instead of reaching the destination.
        for point in [
            CGPoint(x: 40, y: 32),
            CGPoint(x: 260, y: 70),
            CGPoint(x: 490, y: 360),
        ] {
            #expect(
                !HaloPanelMouseTransparencyPolicy.ignoresMouseEvents(
                    interactionState: .selective,
                    pointer: point,
                    interactiveRegions: [surface]
                )
            )
        }

        // The visual-effect envelope and transparent rounded corner remain
        // click-through to the destination application.
        for point in [
            CGPoint(x: 5, y: 100),
            CGPoint(x: 250, y: 395),
            CGPoint(x: 10, y: 8),
        ] {
            #expect(
                HaloPanelMouseTransparencyPolicy.ignoresMouseEvents(
                    interactionState: .selective,
                    pointer: point,
                    interactiveRegions: [surface]
                )
            )
        }
    }

    @Test func clippingDropsStaleRegionsOutsideTheCurrentPanelBounds() {
        let clipped = HaloInteractionHitTester.clipped(
            [
                .rectangle(CGRect(x: 20, y: 20, width: 80, height: 30)),
                .rectangle(CGRect(x: 260, y: 30, width: 40, height: 30)),
                .rectangle(CGRect(x: -20, y: 40, width: 35, height: 30)),
            ],
            to: CGRect(x: 0, y: 0, width: 240, height: 120)
        )

        #expect(clipped == [
            .rectangle(CGRect(x: 20, y: 20, width: 80, height: 30)),
            .rectangle(CGRect(x: 0, y: 40, width: 15, height: 30)),
        ])
    }
}
