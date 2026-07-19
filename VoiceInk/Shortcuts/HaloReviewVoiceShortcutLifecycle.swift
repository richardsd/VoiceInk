import Foundation

/// Commands emitted by the review-only recording-shortcut lifecycle. The
/// receiver owns microphone and transcription work; this type only translates
/// the configured shortcut activation mode into deterministic intent.
enum HaloReviewVoiceShortcutCommand: Equatable {
    case startCapture
    case stopCapture
    case cancelCapture
}

struct HaloReviewVoiceShortcutTransition: Equatable {
    let isHandled: Bool
    let command: HaloReviewVoiceShortcutCommand?

    static let unhandled = HaloReviewVoiceShortcutTransition(
        isHandled: false,
        command: nil
    )

    static func handled(
        _ command: HaloReviewVoiceShortcutCommand? = nil
    ) -> HaloReviewVoiceShortcutTransition {
        HaloReviewVoiceShortcutTransition(isHandled: true, command: command)
    }
}

/// Pure shortcut state used while Halo Review owns Primary and Secondary
/// recording shortcuts. It intentionally does not know about the engine,
/// microphone, event taps, or persisted shortcut settings.
struct HaloReviewVoiceShortcutLifecycle {
    private enum State: Equatable {
        case idle
        case pressed(
            action: ShortcutAction,
            mode: RecordingShortcutManager.Mode,
            startedAt: TimeInterval
        )
        case handsFree
    }

    private(set) var isCaptureActive = false
    private var state: State = .idle

    mutating func synchronizeCapture(isActive: Bool) {
        guard isActive != isCaptureActive else { return }

        isCaptureActive = isActive
        state = isActive ? .handsFree : .idle
    }

    mutating func handleKeyDown(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        isReviewAvailable: Bool
    ) -> HaloReviewVoiceShortcutTransition {
        guard isReviewAvailable, Self.supports(action) else {
            reset()
            return .unhandled
        }

        switch state {
        case .idle:
            state = .pressed(action: action, mode: mode, startedAt: eventTime)
            isCaptureActive = true
            return .handled(.startCapture)

        case .pressed:
            // Key-repeat or a second recording shortcut cannot start a second
            // capture, but the review still owns and suppresses the event.
            return .handled()

        case .handsFree:
            // Once a toggle or short Hybrid press is hands-free, either
            // configured recording shortcut acts as the explicit stop control.
            state = .idle
            isCaptureActive = false
            return .handled(.stopCapture)
        }
    }

    mutating func handleKeyUp(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode _: RecordingShortcutManager.Mode,
        isReviewAvailable: Bool,
        hybridPressThreshold: TimeInterval = 0.5
    ) -> HaloReviewVoiceShortcutTransition {
        guard isReviewAvailable, Self.supports(action) else {
            reset()
            return .unhandled
        }

        guard
            case .pressed(
                let activeAction,
                let activeMode,
                let startedAt
            ) = state,
            activeAction == action
        else {
            // The review owns releases for configured recording shortcuts even
            // when another action began the capture.
            return .handled()
        }

        switch activeMode {
        case .toggle:
            state = .handsFree
            return .handled()

        case .pushToTalk:
            state = .idle
            isCaptureActive = false
            return .handled(.stopCapture)

        case .hybrid:
            let duration = max(0, eventTime - startedAt)
            if duration >= hybridPressThreshold {
                state = .idle
                isCaptureActive = false
                return .handled(.stopCapture)
            }

            state = .handsFree
            return .handled()
        }
    }

    mutating func handleInterruption(
        action: ShortcutAction,
        isReviewAvailable: Bool
    ) -> HaloReviewVoiceShortcutTransition {
        guard isReviewAvailable, Self.supports(action) else {
            reset()
            return .unhandled
        }

        guard case .pressed(let activeAction, _, _) = state,
            activeAction == action
        else {
            return .handled()
        }

        reset()
        return .handled(.cancelCapture)
    }

    mutating func reset() {
        state = .idle
        isCaptureActive = false
    }

    private static func supports(_ action: ShortcutAction) -> Bool {
        action == .primaryRecording || action == .secondaryRecording
    }
}

/// Injectable bridge between the global shortcut owner and Halo Review. The
/// implementation can reject a command when the review is busy; rejection
/// never falls through to the normal recorder while a review remains active.
@MainActor
protocol HaloReviewVoiceShortcutRouting: AnyObject {
    var isHaloReviewVoiceShortcutRoutingActive: Bool { get }
    var isHaloReviewVoiceCaptureActive: Bool { get }

    /// Accepts an immediate shortcut intent. A successful start must publish
    /// its listening state before returning so a following key-up observes the
    /// same capture and preserves Push-to-Talk and Hybrid ordering.
    @discardableResult
    func handleHaloReviewVoiceShortcutCommand(
        _ command: HaloReviewVoiceShortcutCommand
    ) -> Bool
}
