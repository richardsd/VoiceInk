import AppKit
import Foundation

typealias PasteReviewDestinationSnapshot = HaloFocusedDestinationSnapshot

struct PasteReviewDestinationMismatch: Equatable, Sendable {
    let expectedApplicationName: String?
    let currentApplicationName: String?
}

enum PasteReviewDestinationValidation: Equatable, Sendable {
    /// Both the destination process and focused Accessibility element still match.
    case focusedElementMatch

    /// Accessibility did not expose one of the focused elements, but the original
    /// destination process is still frontmost.
    case processMatch

    /// No original process was available to validate. Delivery remains available
    /// so Accessibility-denied configurations retain the existing paste behavior.
    case validationUnavailable

    /// A known process or focused element changed. Applying must remain blocked
    /// until focus returns to the captured destination.
    case mismatch(PasteReviewDestinationMismatch)

    var permitsDelivery: Bool {
        switch self {
        case .focusedElementMatch, .processMatch, .validationUnavailable:
            return true
        case .mismatch:
            return false
        }
    }
}

enum PasteReviewDestinationMatcher {
    static func validate(
        expected: PasteReviewDestinationSnapshot,
        current: PasteReviewDestinationSnapshot
    ) -> PasteReviewDestinationValidation {
        guard let expectedPID = expected.processID else {
            return .validationUnavailable
        }

        guard current.processID == expectedPID else {
            return .mismatch(
                PasteReviewDestinationMismatch(
                    expectedApplicationName: expected.applicationName,
                    currentApplicationName: current.applicationName
                )
            )
        }

        guard let expectedElement = expected.focusedElementIdentity,
            let currentElement = current.focusedElementIdentity
        else {
            return .processMatch
        }

        guard expectedElement == currentElement else {
            return .mismatch(
                PasteReviewDestinationMismatch(
                    expectedApplicationName: expected.applicationName,
                    currentApplicationName: current.applicationName
                )
            )
        }

        return .focusedElementMatch
    }
}

@MainActor
protocol PasteReviewDestinationProviding: AnyObject {
    /// The immutable destination captured before VoiceInk presented its recorder.
    var pasteReviewDestinationSnapshot: PasteReviewDestinationSnapshot? { get }
}

@MainActor
protocol PasteReviewRecoveryPresenting: AnyObject {
    /// Orders Halo out without ending its anchor session or removing review
    /// shortcuts. The destination application therefore remains ready for Cmd-V.
    func hidePasteReviewForDelivery()

    /// Restores the unchanged review after a paste command could not be posted.
    func restorePasteReviewAfterFailedDelivery()
}

@MainActor
protocol PasteReviewDestinationServicing: AnyObject {
    /// A process-only snapshot used as a fallback at recording start. Focused AX
    /// identity is supplied by the pre-recording Halo anchor whenever available.
    func frontmostApplicationSnapshot() -> PasteReviewDestinationSnapshot

    /// Performs the focused-element lookup away from MainActor before comparing
    /// it with the immutable destination snapshot.
    func validate(_ expected: PasteReviewDestinationSnapshot) async -> PasteReviewDestinationValidation
}

@MainActor
final class PasteReviewDestinationService: PasteReviewDestinationServicing {
    private let focusedSnapshot: @Sendable () -> PasteReviewDestinationSnapshot

    init(
        focusedSnapshot: @escaping @Sendable () -> PasteReviewDestinationSnapshot = {
            HaloCaretAnchorResolver.focusedDestinationSnapshot(timeout: 0.12)
        }
    ) {
        self.focusedSnapshot = focusedSnapshot
    }

    func frontmostApplicationSnapshot() -> PasteReviewDestinationSnapshot {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        guard let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != currentProcessID
        else {
            return PasteReviewDestinationSnapshot(
                processID: nil,
                applicationName: nil,
                bundleIdentifier: nil,
                focusedElementIdentity: nil
            )
        }

        return PasteReviewDestinationSnapshot(
            processID: application.processIdentifier,
            applicationName: application.localizedName,
            bundleIdentifier: application.bundleIdentifier,
            focusedElementIdentity: nil
        )
    }

    func validate(_ expected: PasteReviewDestinationSnapshot) async -> PasteReviewDestinationValidation {
        let lookup = focusedSnapshot
        let focused = await Task.detached(priority: .userInitiated) {
            lookup()
        }.value
        // Sample the frontmost process after the AX lookup so an app switch that
        // occurs while Accessibility is responding cannot be accepted as the
        // earlier destination through the PID-only fallback.
        let application = frontmostApplicationSnapshot()

        // NSWorkspace still supplies a reliable frontmost PID when Accessibility
        // is denied. Only merge the AX identity when both sources name that PID.
        let current = PasteReviewDestinationSnapshot(
            processID: application.processID,
            applicationName: application.applicationName ?? focused.applicationName,
            bundleIdentifier: application.bundleIdentifier ?? focused.bundleIdentifier,
            focusedElementIdentity: focused.processID == application.processID
                ? focused.focusedElementIdentity
                : nil
        )

        return PasteReviewDestinationMatcher.validate(expected: expected, current: current)
    }
}
