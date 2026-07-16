import Testing
@testable import VoiceInk

struct HaloDeliveryDecisionTests {
    @Test(arguments: [
        (HaloDeliveryPolicy.alwaysReview, HaloEnhancementOutcome.succeeded, HaloDeliveryRoute.review),
        (.alwaysReview, .rawFallback, .review),
        (.reviewWhenNeeded, .succeeded, .direct),
        (.reviewWhenNeeded, .rawFallback, .review),
        (.pasteImmediately, .succeeded, .direct),
        (.pasteImmediately, .rawFallback, .direct),
    ])
    func policyAndEnhancementOutcomeResolveExpectedRoute(
        policy: HaloDeliveryPolicy,
        outcome: HaloEnhancementOutcome,
        expected: HaloDeliveryRoute
    ) {
        let route = HaloDeliveryDecisionResolver.route(
            for: HaloDeliveryDecisionContext(
                policy: policy,
                enhancementOutcome: outcome,
                sessionOverride: nil,
                destinationState: .unresolved
            )
        )

        #expect(route == expected)
    }

    @Test func explicitSessionOverrideWinsAfterModePolicyResolution() {
        let forceDirect = HaloDeliveryDecisionResolver.route(
            for: HaloDeliveryDecisionContext(
                policy: .alwaysReview,
                enhancementOutcome: .rawFallback,
                sessionOverride: .forceDirect,
                destinationState: .valid
            )
        )
        let forceReview = HaloDeliveryDecisionResolver.route(
            for: HaloDeliveryDecisionContext(
                policy: .pasteImmediately,
                enhancementOutcome: .succeeded,
                sessionOverride: .forceReview,
                destinationState: .valid
            )
        )

        #expect(forceDirect == .direct)
        #expect(forceReview == .review)
    }

    @Test func knownChangedDestinationAlwaysRequiresReview() {
        for policy in HaloDeliveryPolicy.allCases {
            for outcome in [HaloEnhancementOutcome.succeeded, .rawFallback] {
                for override in [HaloSessionDeliveryOverride?.none, .some(.forceDirect), .some(.forceReview)] {
                    let route = HaloDeliveryDecisionResolver.route(
                        for: HaloDeliveryDecisionContext(
                            policy: policy,
                            enhancementOutcome: outcome,
                            sessionOverride: override,
                            destinationState: .changed
                        )
                    )
                    #expect(route == .review)
                }
            }
        }
    }
}
