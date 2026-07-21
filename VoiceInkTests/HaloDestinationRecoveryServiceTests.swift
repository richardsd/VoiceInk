import Foundation
import Testing
@testable import VoiceInk

@MainActor
struct HaloDestinationRecoveryServiceTests {
    @Test func missingProcessIdentifierFailsBeforeLookupOrActivation() {
        var didLookup = false
        var didActivate = false
        let service = HaloDestinationRecoveryService(
            applicationLookup: { _ in
                didLookup = true
                return nil
            },
            applicationActivation: { _ in
                didActivate = true
                return true
            }
        )

        let outcome = service.activateDestinationApplication(
            for: destination(processIdentifier: nil)
        )

        #expect(outcome == .failed(.processIdentifierUnavailable))
        #expect(!didLookup)
        #expect(!didActivate)
    }

    @Test func bundleMismatchFailsWithoutActivation() {
        var didActivate = false
        let service = HaloDestinationRecoveryService(
            applicationLookup: { processIdentifier in
                HaloDestinationRecoveryApplication(
                    processIdentifier: processIdentifier,
                    bundleIdentifier: "test.mail"
                )
            },
            applicationActivation: { _ in
                didActivate = true
                return true
            }
        )

        let outcome = service.activateDestinationApplication(
            for: destination(bundleIdentifier: "test.textedit")
        )

        #expect(outcome == .failed(.applicationIdentityMismatch))
        #expect(!didActivate)
    }

    @Test func activationFailureIsSanitized() {
        let service = HaloDestinationRecoveryService(
            applicationLookup: matchingApplication,
            applicationActivation: { _ in false }
        )

        let outcome = service.activateDestinationApplication(for: destination())

        #expect(outcome == .failed(.activationFailed))
    }

    @Test func matchingProcessAndBundleCanActivate() {
        var activationCount = 0
        let service = HaloDestinationRecoveryService(
            applicationLookup: matchingApplication,
            applicationActivation: { _ in
                activationCount += 1
                return true
            }
        )

        let outcome = service.activateDestinationApplication(for: destination())

        #expect(outcome == .activated)
        #expect(activationCount == 1)
    }

    @Test func bundleIdentityComparisonIsCaseInsensitive() {
        let service = HaloDestinationRecoveryService(
            applicationLookup: { processIdentifier in
                HaloDestinationRecoveryApplication(
                    processIdentifier: processIdentifier,
                    bundleIdentifier: "TEST.TextEdit"
                )
            },
            applicationActivation: { _ in true }
        )

        #expect(
            service.activateDestinationApplication(for: destination())
                == .activated
        )
    }

    private func destination(
        processIdentifier: pid_t? = 41,
        bundleIdentifier: String? = "test.textedit"
    ) -> PasteReviewDestinationSnapshot {
        PasteReviewDestinationSnapshot(
            processID: processIdentifier,
            applicationName: "TextEdit",
            bundleIdentifier: bundleIdentifier,
            focusedElementIdentity: 700
        )
    }

    private func matchingApplication(
        processIdentifier: pid_t
    ) -> HaloDestinationRecoveryApplication {
        HaloDestinationRecoveryApplication(
            processIdentifier: processIdentifier,
            bundleIdentifier: "test.textedit"
        )
    }
}
