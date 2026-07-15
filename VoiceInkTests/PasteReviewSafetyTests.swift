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
    }

    @Test func destinationFallsBackToPIDWhenAccessibilityElementIsUnavailable() {
        let expected = destination(pid: 41, app: "TextEdit", element: 700)
        let current = destination(pid: 41, app: "TextEdit", element: nil)

        #expect(
            PasteReviewDestinationMatcher.validate(expected: expected, current: current)
                == .processMatch
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

    private func destination(
        pid: pid_t?,
        app: String?,
        element: UInt?
    ) -> PasteReviewDestinationSnapshot {
        PasteReviewDestinationSnapshot(
            processID: pid,
            applicationName: app,
            bundleIdentifier: app.map { "test.\($0.lowercased())" },
            focusedElementIdentity: element
        )
    }
}
