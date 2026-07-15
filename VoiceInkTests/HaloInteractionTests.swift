import CoreGraphics
import Testing
@testable import VoiceInk

struct HaloInteractionTests {
    @Test func convertsAppKitBottomLeftPointIntoSwiftUITopLeftPoint() {
        let converted = HaloInteractionCoordinateConverter.swiftUIPoint(
            fromAppKitPoint: CGPoint(x: 32, y: 70),
            contentHeight: 280
        )

        #expect(converted == CGPoint(x: 32, y: 210))
    }

    @Test func hitTesterAcceptsPointsInsideAnyInteractiveRegion() {
        let regions = [
            CGRect(x: 10, y: 20, width: 80, height: 40),
            CGRect(x: 180, y: 200, width: 60, height: 28),
        ]

        #expect(HaloInteractionHitTester.contains(CGPoint(x: 45, y: 35), in: regions))
        #expect(HaloInteractionHitTester.contains(CGPoint(x: 200, y: 214), in: regions))
        #expect(!HaloInteractionHitTester.contains(CGPoint(x: 140, y: 110), in: regions))
    }

    @Test func hitTesterAllowsOnePointToleranceAtReportedEdges() {
        let regions = [CGRect(x: 20, y: 20, width: 40, height: 40)]

        #expect(HaloInteractionHitTester.contains(CGPoint(x: 19.5, y: 40), in: regions))
        #expect(!HaloInteractionHitTester.contains(CGPoint(x: 18, y: 40), in: regions))
    }

    @Test func transparencyPolicyIsPhaseSpecificAndFailsOpenForReviewControls() {
        let button = CGRect(x: 20, y: 20, width: 80, height: 30)

        #expect(
            HaloPanelMouseTransparencyPolicy.ignoresMouseEvents(
                reviewInteractionEnabled: false,
                selectiveMonitoringAvailable: true,
                pointer: CGPoint(x: 40, y: 30),
                interactiveRegions: [button]
            )
        )
        #expect(
            !HaloPanelMouseTransparencyPolicy.ignoresMouseEvents(
                reviewInteractionEnabled: true,
                selectiveMonitoringAvailable: true,
                pointer: CGPoint(x: 40, y: 30),
                interactiveRegions: [button]
            )
        )
        #expect(
            HaloPanelMouseTransparencyPolicy.ignoresMouseEvents(
                reviewInteractionEnabled: true,
                selectiveMonitoringAvailable: true,
                pointer: CGPoint(x: 180, y: 80),
                interactiveRegions: [button]
            )
        )
        #expect(
            !HaloPanelMouseTransparencyPolicy.ignoresMouseEvents(
                reviewInteractionEnabled: true,
                selectiveMonitoringAvailable: false,
                pointer: CGPoint(x: 180, y: 80),
                interactiveRegions: [button]
            )
        )
    }
}
