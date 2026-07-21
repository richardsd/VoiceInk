import Foundation
import Testing
@testable import VoiceInk

struct PasteReviewSafetyTests {
    @Test func destinationRequiresMatchingProcessAndFocusedElementWhenAvailable() {
        let expected = destination(pid: 41, app: "TextEdit", element: 700)

        #expect(
            PasteReviewDestinationMatcher.validate(
                expected: expected,
                current: destination(pid: 41, app: "TextEdit", element: 700)
            ) == .focusedElementMatch
        )

        let validation = PasteReviewDestinationMatcher.validate(
            expected: expected,
            current: destination(pid: 41, app: "TextEdit", element: 701)
        )
        guard case .mismatch(let mismatch) = validation else {
            Issue.record("A changed focused element must block delivery")
            return
        }
        #expect(mismatch.expectedApplicationName == "TextEdit")
        #expect(mismatch.reason == .transientElementChanged)
    }

    @Test func stableElementIdentitySurvivesRecreatedAccessibilityProxy() {
        let expected = destination(
            pid: 41,
            app: "Browser",
            element: 700,
            stableElement: 9_001
        )
        let current = destination(
            pid: 41,
            app: "Browser",
            element: 999,
            stableElement: 9_001
        )

        #expect(
            PasteReviewDestinationMatcher.validate(expected: expected, current: current)
                == .stableElementMatch
        )
    }

    @Test func changedStableElementBlocksEvenWhenTransientProxyMatches() {
        let validation = PasteReviewDestinationMatcher.validate(
            expected: destination(pid: 41, app: "Browser", element: 700, stableElement: 9_001),
            current: destination(pid: 41, app: "Browser", element: 700, stableElement: 9_002)
        )

        guard case .mismatch(let mismatch) = validation else {
            Issue.record("A changed stable field identity must block delivery")
            return
        }
        #expect(mismatch.reason == .stableElementChanged)
    }

    @Test func knownOriginalFieldBlocksWhenCurrentElementIdentityIsUnavailable() {
        let expected = destination(pid: 41, app: "TextEdit", element: 700)
        let current = destination(pid: 41, app: "TextEdit", element: nil)

        let validation = PasteReviewDestinationMatcher.validate(expected: expected, current: current)
        guard case .mismatch(let mismatch) = validation else {
            Issue.record("An indeterminate current field must not downgrade to PID-only delivery")
            return
        }
        #expect(mismatch.reason == .elementIdentityUnavailable)
    }

    @Test func originalPIDOnlyCaptureRetainsCompatibilityFallback() {
        let expected = destination(pid: 41, app: "TextEdit", element: nil)
        let current = destination(pid: 41, app: "TextEdit", element: nil)

        #expect(
            PasteReviewDestinationMatcher.validate(expected: expected, current: current)
                == .processMatch
        )
    }

    @Test func transientIdentityCanSafelyMatchWhenStableIdentityIsTemporarilyUnavailable() {
        let expected = destination(pid: 41, app: "Browser", element: 700, stableElement: 9_001)
        let current = destination(pid: 41, app: "Browser", element: 700, stableElement: nil)

        #expect(
            PasteReviewDestinationMatcher.validate(expected: expected, current: current)
                == .focusedElementMatch
        )
    }

    @Test func destinationProcessMismatchBlocksWithoutUsingElementIdentity() {
        let validation = PasteReviewDestinationMatcher.validate(
            expected: destination(pid: 41, app: "TextEdit", element: nil),
            current: destination(pid: 52, app: "Mail", element: nil)
        )

        guard case .mismatch(let mismatch) = validation else {
            Issue.record("A changed process must block delivery")
            return
        }
        #expect(mismatch.expectedApplicationName == "TextEdit")
        #expect(mismatch.currentApplicationName == "Mail")
        #expect(mismatch.reason == .processChanged)
    }

    @Test func reusedProcessIdentifierWithDifferentBundleBlocksDelivery() {
        let expected = PasteReviewDestinationSnapshot(
            processID: 41,
            applicationName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit",
            focusedElementIdentity: nil
        )
        let current = PasteReviewDestinationSnapshot(
            processID: 41,
            applicationName: "Unexpected",
            bundleIdentifier: "com.example.Unexpected",
            focusedElementIdentity: nil
        )

        let validation = PasteReviewDestinationMatcher.validate(
            expected: expected,
            current: current
        )
        guard case .mismatch(let mismatch) = validation else {
            Issue.record("A reused PID with another bundle must block delivery")
            return
        }
        #expect(mismatch.reason == .applicationIdentityChanged)
    }

    @Test func unavailableOriginalPIDPreservesAccessibilityDeniedCompatibility() {
        let validation = PasteReviewDestinationMatcher.validate(
            expected: destination(pid: nil, app: nil, element: nil),
            current: destination(pid: 52, app: "Mail", element: 900)
        )

        #expect(validation == .validationUnavailable)
        #expect(validation.permitsDelivery)
    }

    @Test func resolutionGatePreventsDoubleDeliveryAndSupportsOneRetry() {
        let reviewID = UUID()
        var gate = PasteReviewResolutionGate()

        let staged = gate.stage(reviewID)
        let duplicateStage = gate.stage(UUID())
        let beganDelivery = gate.beginDelivery(reviewID)
        let duplicateDelivery = gate.beginDelivery(reviewID)
        #expect(staged)
        #expect(!duplicateStage)
        #expect(beganDelivery)
        #expect(!duplicateDelivery)
        #expect(!gate.permitsNonDeliveryAction(for: reviewID))
        let restored = gate.restoreAfterFailure(reviewID)
        #expect(restored)
        #expect(gate.permitsNonDeliveryAction(for: reviewID))
        let beganRetry = gate.beginDelivery(reviewID)
        let completed = gate.completeDelivery(reviewID)
        let duplicateCompletion = gate.completeDelivery(reviewID)
        let cancelAfterCompletion = gate.cancel(reviewID)
        #expect(beganRetry)
        #expect(completed)
        #expect(!duplicateCompletion)
        #expect(!cancelAfterCompletion)
    }

    @Test func cancelIsAtomicAndBlocksLaterDelivery() {
        let reviewID = UUID()
        var gate = PasteReviewResolutionGate()

        let staged = gate.stage(reviewID)
        let canceled = gate.cancel(reviewID)
        let duplicateCancel = gate.cancel(reviewID)
        let deliveryAfterCancel = gate.beginDelivery(reviewID)
        #expect(staged)
        #expect(canceled)
        #expect(!duplicateCancel)
        #expect(!deliveryAfterCancel)
    }

    @Test func finalFifteenSecondWindowIsExplicit() {
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(PasteReviewExpiration.secondsRemaining(until: now.addingTimeInterval(15), at: now) == 15)
        #expect(PasteReviewExpiration.isInWarningWindow(secondsRemaining: 15))
        #expect(!PasteReviewExpiration.isInWarningWindow(secondsRemaining: 16))
        #expect(!PasteReviewExpiration.isInWarningWindow(secondsRemaining: 0))
    }

    @Test func reviewKeepsImmutableDestinationWhenCopied() {
        let destination = destination(pid: 41, app: "TextEdit", element: 700)
        let original = PendingPasteReview(
            rawText: "Raw",
            finalText: "Final",
            payload: PreparedPastePayload(
                displayText: "Final",
                pastedText: "Final ",
                autoSendKey: .enter
            )
        )
        let staged = original.withDestination(destination)

        #expect(staged.id == original.id)
        #expect(staged.payload == original.payload)
        #expect(staged.destination == destination)
        #expect(staged.expiresAt == original.expiresAt)
    }

    @Test func destinationUnavailableMakesTimeShiftReviewCopyOnly() {
        let feedback = PasteReviewFeedback.destinationUnavailable

        #expect(feedback.blocksDelivery)
        #expect(!feedback.allowsRetry)
        #expect(!feedback.allowsRefocus)
        #expect(feedback.message.contains("Copy"))
        #expect(!PasteReviewFeedback.copied.blocksDelivery)
        #expect(!PasteReviewFeedback.pasteFailed.blocksDelivery)
    }

    private func destination(
        pid: pid_t?,
        app: String?,
        element: UInt?,
        stableElement: UInt64? = nil
    ) -> PasteReviewDestinationSnapshot {
        PasteReviewDestinationSnapshot(
            processID: pid,
            applicationName: app,
            bundleIdentifier: app.map { "test.\($0.lowercased())" },
            focusedElementIdentity: element,
            focusedElementStableIdentity: stableElement
        )
    }
}
