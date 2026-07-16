import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
protocol RecorderReviewShortcutControlling: AnyObject {
    func prepareForPasteReview() -> Bool
    func finishPasteReview()
}

struct RecorderReviewShortcutLifecycle {
    enum FinishDisposition: Equatable {
        case inactive
        case deferredUntilKeyUp
        case restoreNow
    }

    private(set) var isHandlingReview = false
    private(set) var actionAwaitingKeyUp: ShortcutAction?
    private var finishRequested = false

    var isAwaitingKeyUp: Bool { actionAwaitingKeyUp != nil }

    mutating func begin() {
        isHandlingReview = true
        actionAwaitingKeyUp = nil
        finishRequested = false
    }

    mutating func recordKeyDown(_ action: ShortcutAction) {
        guard isHandlingReview,
            action == .recorderPanelEscape || action == .cancelRecorder
        else {
            return
        }
        actionAwaitingKeyUp = action
    }

    mutating func requestFinish() -> FinishDisposition {
        guard isHandlingReview else { return .inactive }
        guard actionAwaitingKeyUp == nil else {
            finishRequested = true
            return .deferredUntilKeyUp
        }
        reset()
        return .restoreNow
    }

    /// Returns true when the deferred review monitor can now be replaced. The
    /// monitor sees and suppresses this release before its callbacks run.
    mutating func recordKeyUp(_ action: ShortcutAction) -> Bool {
        guard action == actionAwaitingKeyUp else { return false }
        actionAwaitingKeyUp = nil
        guard finishRequested else { return false }
        reset()
        return true
    }

    @discardableResult
    mutating func forceFinish() -> Bool {
        guard isHandlingReview else { return false }
        reset()
        return true
    }

    private mutating func reset() {
        isHandlingReview = false
        actionAwaitingKeyUp = nil
        finishRequested = false
    }
}

@MainActor
final class RecorderPanelShortcutManager: ObservableObject, RecorderReviewShortcutControlling {
    enum EventPhase {
        case keyDown
        case keyUp
    }

    private var recorderUIManager: RecorderUIManager
    private var visibilityTask: Task<Void, Never>?
    private var shortcutChangeObserver: NSObjectProtocol?
    private let visibleRecorderMonitor: any ShortcutMonitoring
    private var reviewLifecycle = RecorderReviewShortcutLifecycle()
    private var reviewReleaseSafetyTask: Task<Void, Never>?

    private var isHandlingPasteReview: Bool {
        reviewLifecycle.isHandlingReview
    }

    // Double-tap Escape handling
    private var firstEscapePressTime: Date? = nil
    private let escapeDoublePressThreshold: TimeInterval = 1.5
    private var escapeTimeoutTask: Task<Void, Never>?

    init(
        recorderUIManager: RecorderUIManager,
        visibleRecorderMonitor: any ShortcutMonitoring = ShortcutMonitor()
    ) {
        self.recorderUIManager = recorderUIManager
        self.visibleRecorderMonitor = visibleRecorderMonitor
        setupShortcutChangeObserver()
        setupVisibilityObserver()
    }

    private func setupShortcutChangeObserver() {
        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let action = notification.object as? ShortcutAction,
                action == .cancelRecorder
            else {
                return
            }

            Task { @MainActor in
                self?.refreshVisibleShortcuts()
            }
        }
    }

    private func setupVisibilityObserver() {
        visibilityTask = Task { @MainActor in
            for await isVisible in recorderUIManager.$isRecorderPanelVisible.values {
                if isVisible {
                    refreshVisibleShortcuts()
                } else {
                    // Escape and configured cancel actions resolve on key-down.
                    // Keep the review monitor alive until it suppresses key-up.
                    guard !reviewLifecycle.isAwaitingKeyUp else {
                        resetEscapeState()
                        continue
                    }
                    visibleRecorderMonitor.stop()
                    resetEscapeState()
                }
            }
        }
    }

    private var canUseModeShortcuts: Bool {
        !ModeManager.shared.enabledConfigurations.isEmpty
    }

    private func resetEscapeState() {
        firstEscapePressTime = nil
        escapeTimeoutTask?.cancel()
        escapeTimeoutTask = nil
    }

    @discardableResult
    private func refreshVisibleShortcuts() -> Bool {
        guard recorderUIManager.isRecorderPanelVisible else {
            visibleRecorderMonitor.stop()
            resetEscapeState()
            return false
        }

        var shortcuts: [ShortcutAction: Shortcut]

        if isHandlingPasteReview {
            shortcuts = Self.pasteReviewShortcuts(
                cancelShortcut: ShortcutStore.shortcut(for: .cancelRecorder)
            )
        } else {
            shortcuts = ShortcutStore.shortcuts(for: ShortcutAction.recorderPanelStoredActions)

            if recorderUIManager.isHaloPanelActive {
                shortcuts[.recorderPanelToggleHaloDelivery] = .key(
                    keyCode: UInt16(kVK_Return),
                    modifierFlags: [.command]
                )
            }

            if ShortcutStore.shortcut(for: .cancelRecorder) == nil {
                shortcuts[.recorderPanelEscape] = .key(keyCode: UInt16(kVK_Escape), modifierFlags: [])
            }

            if canUseModeShortcuts {
                for (index, keyCode) in Self.digitKeyCodes.enumerated() {
                    shortcuts[.recorderPanelMode(index)] = .key(
                        keyCode: keyCode,
                        modifierFlags: [.option]
                    )
                }
            }
        }

        return visibleRecorderMonitor.start(
            shortcuts: shortcuts,
            interruptibleActions: [],
            onKeyDown: { [weak self] action, _ in
                Task { @MainActor in
                    guard Self.shouldHandle(action, in: .keyDown) else { return }
                    await self?.handleRecorderPanelShortcut(action)
                }
            },
            onKeyUp: { [weak self] action, _ in
                Task { @MainActor in
                    if self?.completeDeferredReviewRelease(for: action) == true {
                        return
                    }
                    guard Self.shouldHandle(action, in: .keyUp) else { return }
                    await self?.handleRecorderPanelShortcut(action)
                }
            },
            onShortcutInterrupted: nil
        )
    }

    nonisolated static func shouldHandle(_ action: ShortcutAction, in phase: EventPhase) -> Bool {
        switch phase {
        case .keyDown:
            return action != .recorderPanelApply
                && action != .recorderPanelToggleHaloDelivery
        case .keyUp:
            return action == .recorderPanelApply
                || action == .recorderPanelToggleHaloDelivery
        }
    }

    /// Returns the complete non-persisted review shortcut set. A configured
    /// Cancel shortcut wins any physical-key collision so one press can never
    /// both cancel and mutate or apply the pending review.
    nonisolated static func pasteReviewShortcuts(
        cancelShortcut: Shortcut?
    ) -> [ShortcutAction: Shortcut] {
        var shortcuts: [ShortcutAction: Shortcut] = [:]
        if let cancelShortcut {
            shortcuts[.cancelRecorder] = cancelShortcut
        }

        let builtInShortcuts: [(ShortcutAction, Shortcut)] = [
            (
                .recorderPanelApply,
                .key(keyCode: UInt16(kVK_Return), modifierFlags: [])
            ),
            (
                .recorderPanelToggleHaloDelivery,
                .key(keyCode: UInt16(kVK_Return), modifierFlags: [.command])
            ),
            (
                .recorderPanelEscape,
                .key(keyCode: UInt16(kVK_Escape), modifierFlags: [])
            ),
            (
                .recorderPanelReviewFinal,
                .key(keyCode: UInt16(kVK_ANSI_1), modifierFlags: [.command])
            ),
            (
                .recorderPanelReviewChanges,
                .key(keyCode: UInt16(kVK_ANSI_2), modifierFlags: [.command])
            ),
            (
                .recorderPanelReviewOriginal,
                .key(keyCode: UInt16(kVK_ANSI_3), modifierFlags: [.command])
            ),
            (
                .recorderPanelPreviousRevision,
                .key(keyCode: UInt16(kVK_ANSI_LeftBracket), modifierFlags: [.command])
            ),
            (
                .recorderPanelNextRevision,
                .key(keyCode: UInt16(kVK_ANSI_RightBracket), modifierFlags: [.command])
            ),
        ]

        for (action, shortcut) in builtInShortcuts
        where cancelShortcut?.conflicts(with: shortcut) != true {
            shortcuts[action] = shortcut
        }
        return shortcuts
    }

    private func handleRecorderPanelShortcut(_ action: ShortcutAction) async {
        guard recorderUIManager.isRecorderPanelVisible else { return }

        if isHandlingPasteReview {
            switch action {
            case .recorderPanelApply, .recorderPanelToggleHaloDelivery:
                await recorderUIManager.approvePendingPasteReview()
            case .recorderPanelEscape, .cancelRecorder:
                reviewLifecycle.recordKeyDown(action)
                await recorderUIManager.cancelPendingPasteReview()
            case .recorderPanelReviewFinal:
                recorderUIManager.selectHaloReviewLens(.final)
            case .recorderPanelReviewChanges:
                recorderUIManager.selectHaloReviewLens(.changes)
            case .recorderPanelReviewOriginal:
                recorderUIManager.selectHaloReviewLens(.original)
            case .recorderPanelPreviousRevision:
                recorderUIManager.moveHaloReviewRevision(by: -1)
            case .recorderPanelNextRevision:
                recorderUIManager.moveHaloReviewRevision(by: 1)
            default:
                break
            }
            return
        }

        switch action {
        case .cancelRecorder:
            guard ShortcutStore.shortcut(for: .cancelRecorder) != nil else { return }
            await recorderUIManager.cancelRecording()
        case .recorderPanelEscape:
            await handleEscapeShortcut()
        case .recorderPanelMode(let index):
            handleModeSelectionShortcut(index: index)
        case .recorderPanelToggleHaloDelivery:
            recorderUIManager.toggleHaloSessionDeliveryOverride()
        default:
            break
        }
    }

    func prepareForPasteReview() -> Bool {
        reviewReleaseSafetyTask?.cancel()
        reviewReleaseSafetyTask = nil
        reviewLifecycle.begin()
        resetEscapeState()

        guard refreshVisibleShortcuts() else {
            // Keep the logical review lifecycle active without installing the
            // normal recorder shortcuts. Mouse controls remain available and
            // finishing the review restores the ordinary shortcut set.
            visibleRecorderMonitor.stop()
            return false
        }

        return true
    }

    func finishPasteReview() {
        switch reviewLifecycle.requestFinish() {
        case .inactive:
            return
        case .deferredUntilKeyUp:
            scheduleReviewReleaseSafetyReset()
        case .restoreNow:
            reviewReleaseSafetyTask?.cancel()
            reviewReleaseSafetyTask = nil
            _ = refreshVisibleShortcuts()
        }
    }

    private func completeDeferredReviewRelease(for action: ShortcutAction) -> Bool {
        guard reviewLifecycle.recordKeyUp(action) else { return false }
        reviewReleaseSafetyTask?.cancel()
        reviewReleaseSafetyTask = nil
        _ = refreshVisibleShortcuts()
        return true
    }

    private func scheduleReviewReleaseSafetyReset() {
        reviewReleaseSafetyTask?.cancel()
        reviewReleaseSafetyTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            guard let self, self.reviewLifecycle.forceFinish() else { return }
            self.reviewReleaseSafetyTask = nil
            _ = self.refreshVisibleShortcuts()
        }
    }

    private func handleEscapeShortcut() async {
        guard ShortcutStore.shortcut(for: .cancelRecorder) == nil else { return }

        let now = Date()
        if let firstTime = firstEscapePressTime,
            now.timeIntervalSince(firstTime) <= escapeDoublePressThreshold
        {
            resetEscapeState()
            await recorderUIManager.cancelRecording()
            return
        }

        firstEscapePressTime = now
        NotificationManager.shared.showNotification(
            title: String(localized: "Press Esc again to cancel"),
            type: .info,
            duration: escapeDoublePressThreshold
        )
        escapeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.escapeDoublePressThreshold ?? 1.5) * 1_000_000_000))
            await MainActor.run {
                self?.firstEscapePressTime = nil
            }
        }
    }

    private func handleModeSelectionShortcut(index: Int) {
        guard canUseModeShortcuts else { return }

        let modeManager = ModeManager.shared
        let availableConfigurations = modeManager.enabledConfigurations

        guard index < availableConfigurations.count else { return }

        let selectedConfig = availableConfigurations[index]
        modeManager.setActiveConfiguration(selectedConfig)
        recorderUIManager.reconcileRecorderPanel(for: selectedConfig.outputMode)
    }

    deinit {
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }

        visibilityTask?.cancel()
        reviewReleaseSafetyTask?.cancel()
        MainActor.assumeIsolated {
            visibleRecorderMonitor.stop()
            resetEscapeState()
        }
    }

    private static let digitKeyCodes: [UInt16] = [
        UInt16(kVK_ANSI_1),
        UInt16(kVK_ANSI_2),
        UInt16(kVK_ANSI_3),
        UInt16(kVK_ANSI_4),
        UInt16(kVK_ANSI_5),
        UInt16(kVK_ANSI_6),
        UInt16(kVK_ANSI_7),
        UInt16(kVK_ANSI_8),
        UInt16(kVK_ANSI_9),
        UInt16(kVK_ANSI_0),
    ]
}
