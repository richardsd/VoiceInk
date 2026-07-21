import AppKit
import Foundation

enum HaloDestinationRecoveryFailure: Equatable, Sendable {
    case processIdentifierUnavailable
    case bundleIdentifierUnavailable
    case applicationUnavailable
    case applicationIdentityMismatch
    case activationFailed
}

enum HaloDestinationRecoveryOutcome: Equatable, Sendable {
    case activated
    case failed(HaloDestinationRecoveryFailure)
}

/// Activates only the application captured with a pending Halo review.
///
/// Recovery deliberately stops at the application boundary. It never retains
/// or focuses an Accessibility element and never attempts paste delivery.
@MainActor
protocol HaloDestinationRecoveryServicing: AnyObject {
    func activateDestinationApplication(
        for destination: PasteReviewDestinationSnapshot
    ) -> HaloDestinationRecoveryOutcome
}

/// A narrow application handle keeps AppKit out of the recovery result and
/// provides deterministic lookup and activation seams for tests.
struct HaloDestinationRecoveryApplication {
    let processIdentifier: pid_t
    let bundleIdentifier: String?

    fileprivate let activate: () -> Bool

    init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        activate: @escaping () -> Bool = { false }
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.activate = activate
    }
}

@MainActor
final class HaloDestinationRecoveryService: HaloDestinationRecoveryServicing {
    typealias ApplicationLookup = (pid_t) -> HaloDestinationRecoveryApplication?
    typealias ApplicationActivation = (HaloDestinationRecoveryApplication) -> Bool

    private let applicationLookup: ApplicationLookup
    private let applicationActivation: ApplicationActivation

    init(
        applicationLookup: @escaping ApplicationLookup = { processIdentifier in
            guard let application = NSRunningApplication(
                processIdentifier: processIdentifier
            ) else {
                return nil
            }

            return HaloDestinationRecoveryApplication(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                activate: {
                    application.activate(options: .activateIgnoringOtherApps)
                }
            )
        },
        applicationActivation: @escaping ApplicationActivation = { application in
            application.activate()
        }
    ) {
        self.applicationLookup = applicationLookup
        self.applicationActivation = applicationActivation
    }

    func activateDestinationApplication(
        for destination: PasteReviewDestinationSnapshot
    ) -> HaloDestinationRecoveryOutcome {
        guard let expectedProcessIdentifier = destination.processID else {
            return .failed(.processIdentifierUnavailable)
        }

        guard let expectedBundleIdentifier = normalizedBundleIdentifier(
            destination.bundleIdentifier
        ) else {
            return .failed(.bundleIdentifierUnavailable)
        }

        guard let application = applicationLookup(expectedProcessIdentifier) else {
            return .failed(.applicationUnavailable)
        }

        guard application.processIdentifier == expectedProcessIdentifier,
            normalizedBundleIdentifier(application.bundleIdentifier) == expectedBundleIdentifier
        else {
            // A reused PID or a changed bundle is reported only as a categorical
            // mismatch. Do not expose either application identity to the UI.
            return .failed(.applicationIdentityMismatch)
        }

        guard applicationActivation(application) else {
            return .failed(.activationFailed)
        }

        return .activated
    }

    private func normalizedBundleIdentifier(_ identifier: String?) -> String? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
            !identifier.isEmpty
        else {
            return nil
        }
        return identifier.lowercased()
    }
}
