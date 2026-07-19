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

    @Test func escapeCanCancelOnlyRefinementAndKeepReviewMonitorInstalled() {
        var lifecycle = RecorderReviewShortcutLifecycle()
        lifecycle.begin()
        lifecycle.recordKeyDown(.recorderPanelEscape)

        // Cancelling a refinement does not request review teardown. The key-up
        // is still suppressed, but the review monitor remains active so a
        // second Escape can cancel the review itself.
        let shouldRestoreShortcuts = lifecycle.recordKeyUp(.recorderPanelEscape)
        #expect(!shouldRestoreShortcuts)
        #expect(lifecycle.isHandlingReview)
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
        #expect(
            RecorderPanelShortcutManager.shouldHandle(
                .recorderPanelReviewChanges,
                in: .keyDown
            )
        )
        #expect(
            !RecorderPanelShortcutManager.shouldHandle(
                .recorderPanelReviewChanges,
                in: .keyUp
            )
        )
    }

    @Test func reviewLensAndRevisionShortcutsAreNonPersistedAndMapped() {
        let shortcuts = RecorderPanelShortcutManager.pasteReviewShortcuts(
            cancelShortcut: nil
        )

        #expect(!ShortcutAction.recorderPanelReviewFinal.isStored)
        #expect(!ShortcutAction.recorderPanelReviewChanges.isStored)
        #expect(!ShortcutAction.recorderPanelReviewOriginal.isStored)
        #expect(!ShortcutAction.recorderPanelPreviousRevision.isStored)
        #expect(!ShortcutAction.recorderPanelNextRevision.isStored)
        #expect(
            shortcuts[.recorderPanelReviewFinal]
                == .key(keyCode: UInt16(kVK_ANSI_1), modifierFlags: [.command])
        )
        #expect(
            shortcuts[.recorderPanelReviewChanges]
                == .key(keyCode: UInt16(kVK_ANSI_2), modifierFlags: [.command])
        )
        #expect(
            shortcuts[.recorderPanelReviewOriginal]
                == .key(keyCode: UInt16(kVK_ANSI_3), modifierFlags: [.command])
        )
        #expect(
            shortcuts[.recorderPanelPreviousRevision]
                == .key(keyCode: UInt16(kVK_ANSI_LeftBracket), modifierFlags: [.command])
        )
        #expect(
            shortcuts[.recorderPanelNextRevision]
                == .key(keyCode: UInt16(kVK_ANSI_RightBracket), modifierFlags: [.command])
        )
    }

    @Test func reviewBuiltInsWinRecordingShortcutCollisions() {
        let commandReturn = Shortcut.key(
            keyCode: UInt16(kVK_Return),
            modifierFlags: [.command]
        )
        let commandTwo = Shortcut.key(
            keyCode: UInt16(kVK_ANSI_2),
            modifierFlags: [.command]
        )
        let nonConflicting = Shortcut.key(
            keyCode: UInt16(kVK_ANSI_R),
            modifierFlags: [.control, .option]
        )

        #expect(RecorderPanelShortcutManager.isBuiltInPasteReviewShortcut(commandReturn))
        #expect(RecorderPanelShortcutManager.isBuiltInPasteReviewShortcut(commandTwo))
        #expect(!RecorderPanelShortcutManager.isBuiltInPasteReviewShortcut(nonConflicting))
        #expect(
            !RecordingShortcutManager.shouldInstallRecordingShortcut(
                commandReturn,
                whileReviewing: true
            )
        )
        #expect(
            RecordingShortcutManager.shouldInstallRecordingShortcut(
                commandReturn,
                whileReviewing: false
            )
        )
        #expect(
            RecordingShortcutManager.shouldInstallRecordingShortcut(
                nonConflicting,
                whileReviewing: true
            )
        )
        #expect(
            ShortcutValidator.validationError(
                for: commandReturn,
                action: .primaryRecording
            )
                == .alreadyUsedBy(
                    ShortcutAction.recorderPanelToggleHaloDelivery.displayName
                )
        )
    }

    @Test func manualEditingLeavesPlainReturnForMultilineTextAndKeepsCommandReturnSave() {
        let shortcuts = RecorderPanelShortcutManager.pasteReviewShortcuts(
            cancelShortcut: nil,
            includePlainReturn: false
        )

        #expect(shortcuts[.recorderPanelApply] == nil)
        #expect(
            shortcuts[.recorderPanelToggleHaloDelivery]
                == .key(keyCode: UInt16(kVK_Return), modifierFlags: [.command])
        )
        #expect(shortcuts[.recorderPanelEscape] != nil)
    }

    @Test func configuredCancelWinsAReviewShortcutCollision() {
        let configuredCancel = Shortcut.key(
            keyCode: UInt16(kVK_ANSI_2),
            modifierFlags: [.command]
        )
        let shortcuts = RecorderPanelShortcutManager.pasteReviewShortcuts(
            cancelShortcut: configuredCancel
        )

        #expect(shortcuts[.cancelRecorder] == configuredCancel)
        #expect(shortcuts[.recorderPanelReviewChanges] == nil)
        #expect(shortcuts[.recorderPanelReviewFinal] != nil)
        #expect(shortcuts[.recorderPanelApply] != nil)
    }

    @Test func configuredCancelAlsoWinsApplyAndEscapeCollisions() {
        let returnShortcut = Shortcut.key(
            keyCode: UInt16(kVK_Return),
            modifierFlags: []
        )
        let returnShortcuts = RecorderPanelShortcutManager.pasteReviewShortcuts(
            cancelShortcut: returnShortcut
        )
        #expect(returnShortcuts[.cancelRecorder] == returnShortcut)
        #expect(returnShortcuts[.recorderPanelApply] == nil)

        let commandReturnShortcut = Shortcut.key(
            keyCode: UInt16(kVK_Return),
            modifierFlags: [.command]
        )
        let commandReturnShortcuts = RecorderPanelShortcutManager.pasteReviewShortcuts(
            cancelShortcut: commandReturnShortcut
        )
        #expect(commandReturnShortcuts[.cancelRecorder] == commandReturnShortcut)
        #expect(commandReturnShortcuts[.recorderPanelToggleHaloDelivery] == nil)

        let escapeShortcut = Shortcut.key(
            keyCode: UInt16(kVK_Escape),
            modifierFlags: []
        )
        let escapeShortcuts = RecorderPanelShortcutManager.pasteReviewShortcuts(
            cancelShortcut: escapeShortcut
        )
        #expect(escapeShortcuts[.cancelRecorder] == escapeShortcut)
        #expect(escapeShortcuts[.recorderPanelEscape] == nil)
    }

    @Test func physicalEscapeConfiguredAsCancelStillUsesRefinementFirstBehavior() {
        let escapeShortcut = Shortcut.key(
            keyCode: UInt16(kVK_Escape),
            modifierFlags: []
        )
        let nonEscapeShortcut = Shortcut.key(
            keyCode: UInt16(kVK_ANSI_X),
            modifierFlags: [.command]
        )

        #expect(
            RecorderPanelShortcutManager.shouldCancelActiveRefinementFirst(
                for: .cancelRecorder,
                configuredCancelShortcut: escapeShortcut
            )
        )
        #expect(
            !RecorderPanelShortcutManager.shouldCancelActiveRefinementFirst(
                for: .cancelRecorder,
                configuredCancelShortcut: nonEscapeShortcut
            )
        )
        #expect(
            RecorderPanelShortcutManager.shouldCancelActiveRefinementFirst(
                for: .recorderPanelEscape,
                configuredCancelShortcut: nil
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
    @Test func reviewLensAndRevisionKeysSuppressBothTransitions() {
        let monitor = ShortcutMonitor()
        monitor.configureForEventSimulation(
            shortcuts: RecorderPanelShortcutManager.pasteReviewShortcuts(
                cancelShortcut: nil
            ),
            onKeyDown: { _, _ in },
            onKeyUp: { _, _ in }
        )

        let keyCodes = [
            UInt16(kVK_ANSI_1),
            UInt16(kVK_ANSI_2),
            UInt16(kVK_ANSI_3),
            UInt16(kVK_ANSI_LeftBracket),
            UInt16(kVK_ANSI_RightBracket),
        ]
        for (index, keyCode) in keyCodes.enumerated() {
            #expect(
                monitor.simulateEvent(
                    kind: .keyDown,
                    keyCode: keyCode,
                    modifierFlags: [.command],
                    eventTime: TimeInterval(index * 2 + 1)
                )
            )
            #expect(
                monitor.simulateEvent(
                    kind: .keyUp,
                    keyCode: keyCode,
                    modifierFlags: [.command],
                    eventTime: TimeInterval(index * 2 + 2)
                )
            )
        }
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
        #expect(monitor.startCalls[0].shortcuts[.recorderPanelReviewFinal] != nil)
        #expect(monitor.startCalls[0].shortcuts[.recorderPanelPreviousRevision] != nil)
    }
}
