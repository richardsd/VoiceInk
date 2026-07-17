import AppKit
import Foundation

typealias PasteReviewDestinationSnapshot = HaloFocusedDestinationSnapshot

enum PasteReviewDestinationMismatchReason: Equatable, Sendable {
    case processChanged
    case stableElementChanged
    case transientElementChanged
    case elementIdentityUnavailable
    case unknown
}

struct PasteReviewDestinationMismatch: Equatable, Sendable {
    let expectedApplicationName: String?
    let currentApplicationName: String?
    let reason: PasteReviewDestinationMismatchReason

    init(
        expectedApplicationName: String?,
        currentApplicationName: String?,
        reason: PasteReviewDestinationMismatchReason = .unknown
    ) {
        self.expectedApplicationName = expectedApplicationName
        self.currentApplicationName = currentApplicationName
        self.reason = reason
    }
}

enum PasteReviewDestinationValidation: Equatable, Sendable {
    /// A stable Accessibility identifier still names the same focused field.
    case stableElementMatch

    /// Both the destination process and focused Accessibility element still match.
    case focusedElementMatch

    /// The original capture did not expose any focused-element identity, but
    /// the original destination process is still frontmost.
    case processMatch

    /// No original process was available to validate. Delivery remains available
    /// so Accessibility-denied configurations retain the existing paste behavior.
    case validationUnavailable

    /// A known process or focused element changed. Applying must remain blocked
    /// until focus returns to the captured destination.
    case mismatch(PasteReviewDestinationMismatch)

    var permitsDelivery: Bool {
        switch self {
        case .stableElementMatch, .focusedElementMatch, .processMatch, .validationUnavailable:
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
                    currentApplicationName: current.applicationName,
                    reason: .processChanged
                )
            )
        }

        if let expectedStableElement = expected.focusedElementStableIdentity,
            let currentStableElement = current.focusedElementStableIdentity
        {
            guard expectedStableElement == currentStableElement else {
                return .mismatch(
                    PasteReviewDestinationMismatch(
                        expectedApplicationName: expected.applicationName,
                        currentApplicationName: current.applicationName,
                        reason: .stableElementChanged
                    )
                )
            }
            return .stableElementMatch
        }

        if let expectedElement = expected.focusedElementIdentity,
            let currentElement = current.focusedElementIdentity
        {
            guard expectedElement == currentElement else {
                return .mismatch(
                    PasteReviewDestinationMismatch(
                        expectedApplicationName: expected.applicationName,
                        currentApplicationName: current.applicationName,
                        reason: .transientElementChanged
                    )
                )
            }
            return .focusedElementMatch
        }

        // PID-only validation is compatible only when the original capture did
        // not know a field identity. If VoiceInk captured a concrete field and
        // the current AX lookup cannot identify it, delivery is indeterminate:
        // block and let the user refocus or Copy instead of guessing within the
        // same application process.
        guard expected.focusedElementStableIdentity == nil,
            expected.focusedElementIdentity == nil
        else {
            return .mismatch(
                PasteReviewDestinationMismatch(
                    expectedApplicationName: expected.applicationName,
                    currentApplicationName: current.applicationName,
                    reason: .elementIdentityUnavailable
                )
            )
        }

        return .processMatch
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

    /// Collapses the review to a mouse-transparent instruction so the user can
    /// manually focus the original destination without Halo intercepting it.
    func beginPasteReviewFocusRecovery()

    /// Restores the unchanged review after destination focus was revalidated or
    /// a recovery attempt failed. Neither operation consumes the review.
    func endPasteReviewFocusRecovery()
}

extension PasteReviewRecoveryPresenting {
    func beginPasteReviewFocusRecovery() {}
    func endPasteReviewFocusRecovery() {}
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

        // A nonactivating Halo editor can temporarily own system focus while the
        // destination remains NSWorkspace's frontmost application. Treat a
        // concrete AX process disagreement as a known mismatch; only use the
        // frontmost PID fallback when Accessibility returned no focused app.
        let current: PasteReviewDestinationSnapshot
        if let focusedPID = focused.processID,
            focusedPID != application.processID
        {
            current = focused
        } else {
            current = PasteReviewDestinationSnapshot(
                processID: application.processID,
                applicationName: application.applicationName ?? focused.applicationName,
                bundleIdentifier: application.bundleIdentifier ?? focused.bundleIdentifier,
                focusedElementIdentity: focused.processID == application.processID
                    ? focused.focusedElementIdentity
                    : nil,
                focusedElementStableIdentity: focused.processID == application.processID
                    ? focused.focusedElementStableIdentity
                    : nil
            )
        }

        return PasteReviewDestinationMatcher.validate(expected: expected, current: current)
    }
}
