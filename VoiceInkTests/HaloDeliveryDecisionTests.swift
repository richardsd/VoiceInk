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
        let riskyResult = HaloDeliveryRiskAssessment(risks: [.autoSend, .substantialRewrite])
        let forceDirect = HaloDeliveryDecisionResolver.route(
            for: HaloDeliveryDecisionContext(
                policy: .alwaysReview,
                enhancementOutcome: .rawFallback,
                sessionOverride: .forceDirect,
                destinationState: .valid,
                riskAssessment: riskyResult
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

    @Test func reviewWhenNeededRequiresReviewForEverySuccessfulRiskSignal() {
        let risks: [HaloDeliveryRisk] = [
            .autoSend,
            .emptyResult,
            .suspiciousLengthChange,
            .substantialRewrite,
        ]

        for risk in risks {
            let route = HaloDeliveryDecisionResolver.route(
                for: HaloDeliveryDecisionContext(
                    policy: .reviewWhenNeeded,
                    enhancementOutcome: .succeeded,
                    sessionOverride: nil,
                    destinationState: .valid,
                    riskAssessment: HaloDeliveryRiskAssessment(risks: [risk])
                )
            )

            #expect(route == .review)
        }
    }

    @Test func pasteImmediatelyIgnoresResultRiskWithoutKnownDestinationChange() {
        let route = HaloDeliveryDecisionResolver.route(
            for: HaloDeliveryDecisionContext(
                policy: .pasteImmediately,
                enhancementOutcome: .succeeded,
                sessionOverride: nil,
                destinationState: .valid,
                riskAssessment: HaloDeliveryRiskAssessment(
                    risks: [.autoSend, .emptyResult, .suspiciousLengthChange, .substantialRewrite]
                )
            )
        )

        #expect(route == .direct)
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

    @Test func commandReturnToggleArmsThePolicyOppositeAndSecondPressClearsIt() {
        #expect(
            HaloSessionDeliveryOverrideResolver.toggled(
                current: nil,
                policy: .alwaysReview
            ) == .forceDirect
        )
        #expect(
            HaloSessionDeliveryOverrideResolver.toggled(
                current: nil,
                policy: .reviewWhenNeeded
            ) == .forceDirect
        )
        #expect(
            HaloSessionDeliveryOverrideResolver.toggled(
                current: nil,
                policy: .pasteImmediately
            ) == .forceReview
        )
        #expect(
            HaloSessionDeliveryOverrideResolver.toggled(
                current: .forceDirect,
                policy: .pasteImmediately
            ) == nil
        )
    }

    @Test func riskEvaluatorTreatsSmallCleanupAsSafe() {
        let assessment = HaloDeliveryRiskEvaluator.assess(
            rawText: "hello world this is a test",
            finalText: "Hello, world. This is a test.",
            autoSendEnabled: false,
            enhancementOutcome: .succeeded
        )

        #expect(assessment == .none)
    }

    @Test func riskEvaluatorCapturesDeliveryAndFallbackRisk() {
        let assessment = HaloDeliveryRiskEvaluator.assess(
            rawText: "Raw transcript",
            finalText: "Raw transcript",
            autoSendEnabled: true,
            enhancementOutcome: .rawFallback
        )

        #expect(assessment.risks == [.autoSend, .rawFallback])
    }

    @Test func riskEvaluatorCapturesEmptySuccessfulResult() {
        let assessment = HaloDeliveryRiskEvaluator.assess(
            rawText: "A usable raw transcript",
            finalText: "  \n",
            autoSendEnabled: false,
            enhancementOutcome: .succeeded
        )

        #expect(assessment.risks == [.emptyResult])
    }

    @Test func riskEvaluatorCapturesSuspiciousLengthChange() {
        let assessment = HaloDeliveryRiskEvaluator.assess(
            rawText: "This is a considerably longer source transcript that should remain recognizable.",
            finalText: "Short result.",
            autoSendEnabled: false,
            enhancementOutcome: .succeeded
        )

        #expect(assessment.risks.contains(.suspiciousLengthChange))
    }

    @Test func riskEvaluatorCapturesSameLengthSubstantialRewrite() {
        let assessment = HaloDeliveryRiskEvaluator.assess(
            rawText: "alpha beta gamma delta epsilon zeta eta theta",
            finalText: "one two three four five six seven eight",
            autoSendEnabled: false,
            enhancementOutcome: .succeeded
        )

        #expect(assessment.risks.contains(.substantialRewrite))
        #expect(!assessment.risks.contains(.suspiciousLengthChange))
        #expect(assessment.reviewMessage?.contains("rewritten substantially") == true)
    }

    @Test func riskEvaluatorCapturesUnspacedCJKRewrite() {
        let assessment = HaloDeliveryRiskEvaluator.assess(
            rawText: "今日は公園で友達と楽しく散歩しました",
            finalText: "明日は会社で同僚と静かに仕事をします",
            autoSendEnabled: false,
            enhancementOutcome: .succeeded
        )

        #expect(assessment.risks.contains(.substantialRewrite))
    }

    @Test func contentRiskMessageTakesPriorityOverAutoSend() {
        let assessment = HaloDeliveryRiskEvaluator.assess(
            rawText: "alpha beta gamma delta epsilon zeta eta theta",
            finalText: "one two three four five six seven eight",
            autoSendEnabled: true,
            enhancementOutcome: .succeeded
        )

        #expect(assessment.risks.contains(.autoSend))
        #expect(assessment.reviewMessage?.contains("rewritten substantially") == true)
    }

    @Test func longRewriteUsesBoundedRiskPath() {
        let raw = Array(repeating: "alpha", count: 1_500).joined(separator: " ")
        let final = Array(repeating: "omega", count: 1_500).joined(separator: " ")
        let assessment = HaloDeliveryRiskEvaluator.assess(
            rawText: raw,
            finalText: final,
            autoSendEnabled: false,
            enhancementOutcome: .succeeded
        )

        #expect(assessment.risks.contains(.substantialRewrite))
    }
}
