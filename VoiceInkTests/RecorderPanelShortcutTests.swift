import AppKit
import Carbon.HIToolbox
import Testing
@testable import VoiceInk

@MainActor
private final class FailingShortcutMonitor: ShortcutMonitoring {
    struct StartCall {
        let shortcuts: [ShortcutAction: Shortcut]
    }

    private(set) var startCalls: [StartCall] = []

    func start(
        shortcuts: [ShortcutAction: Shortcut],
        interruptibleActions: Set<ShortcutAction>,
        onKeyDown: @escaping (ShortcutAction, TimeInterval) -> Void,
        onKeyUp: @escaping (ShortcutAction, TimeInterval) -> Void,
        onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)?
    ) -> Bool {
        startCalls.append(StartCall(shortcuts: shortcuts))
        return false
    }

    func stop() {}
}

struct RecorderPanelShortcutTests {
    @Test func cancelKeepsReviewMonitorUntilItsKeyUpIsSuppressed() {
        var lifecycle = RecorderReviewShortcutLifecycle()
        lifecycle.begin()
        lifecycle.recordKeyDown(.recorderPanelEscape)

        #expect(lifecycle.requestFinish() == .deferredUntilKeyUp)
        #expect(lifecycle.isHandlingReview)
        #expect(lifecycle.isAwaitingKeyUp)

        let restoredAfterKeyUp = lifecycle.recordKeyUp(.recorderPanelEscape)
        #expect(restoredAfterKeyUp)
        #expect(!lifecycle.isHandlingReview)
        #expect(!lifecycle.isAwaitingKeyUp)
    }

    @Test func reviewEventPolicyAppliesReturnOnKeyUpAndEscapeOnKeyDown() {
        #expect(
            !RecorderPanelShortcutManager.shouldHandle(
                .recorderPanelApply,
                in: .keyDown
            )
        )
        #expect(
            RecorderPanelShortcutManager.shouldHandle(
                .recorderPanelApply,
                in: .keyUp
            )
        )
        #expect(
            RecorderPanelShortcutManager.shouldHandle(
                .recorderPanelEscape,
                in: .keyDown
            )
        )
        #expect(
            !RecorderPanelShortcutManager.shouldHandle(
                .recorderPanelEscape,
                in: .keyUp
            )
        )
        #expect(
            !RecorderPanelShortcutManager.shouldHandle(
                .recorderPanelToggleHaloDelivery,
                in: .keyDown
            )
        )
        #expect(
            RecorderPanelShortcutManager.shouldHandle(
                .recorderPanelToggleHaloDelivery,
                in: .keyUp
            )
        )
    }

    @MainActor
    @Test func reviewReturnAndEscapeSuppressBothKeyTransitions() {
        let monitor = ShortcutMonitor()
        monitor.configureForEventSimulation(
            shortcuts: [
                .recorderPanelApply: .key(
                    keyCode: UInt16(kVK_Return),
                    modifierFlags: []
                ),
                .recorderPanelEscape: .key(
                    keyCode: UInt16(kVK_Escape),
                    modifierFlags: []
                ),
                .recorderPanelToggleHaloDelivery: .key(
                    keyCode: UInt16(kVK_Return),
                    modifierFlags: [.command]
                ),
            ],
            onKeyDown: { _, _ in },
            onKeyUp: { _, _ in }
        )

        #expect(
            monitor.simulateEvent(
                kind: .keyDown,
                keyCode: UInt16(kVK_Return),
                eventTime: 1
            )
        )
        #expect(
            monitor.simulateEvent(
                kind: .keyUp,
                keyCode: UInt16(kVK_Return),
                eventTime: 2
            )
        )
        #expect(
            monitor.simulateEvent(
                kind: .keyDown,
                keyCode: UInt16(kVK_Escape),
                eventTime: 3
            )
        )
        #expect(
            monitor.simulateEvent(
                kind: .keyUp,
                keyCode: UInt16(kVK_Escape),
                eventTime: 4
            )
        )
        #expect(
            monitor.simulateEvent(
                kind: .keyDown,
                keyCode: UInt16(kVK_Return),
                modifierFlags: [.command],
                eventTime: 5
            )
        )
        #expect(
            monitor.simulateEvent(
                kind: .keyUp,
                keyCode: UInt16(kVK_Return),
                modifierFlags: [.command],
                eventTime: 6
            )
        )
    }

    @MainActor
    @Test func failedReviewEventTapLeavesReviewMouseOnlyWithoutNormalShortcuts() {
        let recorderUIManager = RecorderUIManager()
        recorderUIManager.isRecorderPanelVisible = true
        let monitor = FailingShortcutMonitor()
        let manager = RecorderPanelShortcutManager(
            recorderUIManager: recorderUIManager,
            visibleRecorderMonitor: monitor
        )

        #expect(!manager.prepareForPasteReview())
        #expect(monitor.startCalls.count == 1)
        #expect(monitor.startCalls[0].shortcuts[.recorderPanelApply] != nil)
        #expect(monitor.startCalls[0].shortcuts[.recorderPanelEscape] != nil)
    }
}
