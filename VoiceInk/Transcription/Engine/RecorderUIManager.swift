import Foundation
import SwiftUI
import os

enum RecorderPanelStyle: String, CaseIterable, Identifiable {
    case notch
    case mini
    case halo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notch:
            return String(localized: "Notch")
        case .mini:
            return String(localized: "Mini")
        case .halo:
            return String(localized: "Halo")
        }
    }

    static var stored: RecorderPanelStyle {
        let rawValue = UserDefaults.standard.string(forKey: "RecorderType") ?? RecorderPanelStyle.mini.rawValue
        return RecorderPanelStyle(rawValue: rawValue) ?? .mini
    }
}

enum RecorderPanelRouting {
    static func effectiveStyle(
        selectedStyle: RecorderPanelStyle,
        outputMode: ModeOutputMode
    ) -> RecorderPanelStyle {
        guard selectedStyle == .halo else { return selectedStyle }
        return outputMode == .paste ? .halo : .mini
    }
}

@MainActor
protocol RecorderPanelPresenting: AnyObject {
    var isRecorderPanelVisible: Bool { get }
    var isHaloPanelActive: Bool { get }
    func dismissRecorderPanel() async
    func reconcileRecorderPanel(for outputMode: ModeOutputMode)
    func preparePasteReviewKeyboardHandling() -> Bool
    func refreshPasteReviewKeyboardHandling()
    func finishPasteReviewKeyboardHandling()
    func presentPasteReview(_ review: PendingPasteReview)
    func clearPasteReview()
    func showHaloPasteConfirmation()
}

extension RecorderPanelPresenting {
    func refreshPasteReviewKeyboardHandling() {}
}

@MainActor
class RecorderUIManager: ObservableObject, RecorderPanelPresenting {
    @Published var recorderPanelStyle: RecorderPanelStyle = .stored {
        didSet {
            guard oldValue != recorderPanelStyle else { return }
            UserDefaults.standard.set(recorderPanelStyle.rawValue, forKey: "RecorderType")
            handleStoredStyleChange()
        }
    }

    @Published private(set) var effectiveRecorderPanelStyle: RecorderPanelStyle = .stored

    var recorderType: String {
        get { recorderPanelStyle.rawValue }
        set { recorderPanelStyle = RecorderPanelStyle(rawValue: newValue) ?? .mini }
    }

    @Published var isRecorderPanelVisible = false {
        didSet {
            guard oldValue != isRecorderPanelVisible else { return }

            if isRecorderPanelVisible {
                showRecorderPanel()
            } else {
                hideRecorderPanel()
            }
        }
    }

    private var notchWindowManager: NotchWindowManager?
    private var miniWindowManager: MiniWindowManager?
    private var haloWindowManager: HaloWindowManager?
    private weak var reviewShortcutController: (any RecorderReviewShortcutControlling)?
    private var haloPasteConfirmationTask: Task<Void, Never>?

    private weak var engine: VoiceInkEngine?
    private var recorder: Recorder?

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderUIManager")

    init() {}

    var isHaloPanelActive: Bool {
        isRecorderPanelVisible && effectiveRecorderPanelStyle == .halo
    }

    var isHaloManualEditActive: Bool {
        engine?.haloReviewState?.isEditingManually == true
    }

    /// Call after VoiceInkEngine is created to break the circular init dependency.
    func configure(engine: VoiceInkEngine, recorder: Recorder) {
        self.engine = engine
        self.recorder = recorder
        setupNotifications()
    }

    func setReviewShortcutController(_ controller: any RecorderReviewShortcutControlling) {
        reviewShortcutController = controller
    }

    // MARK: - Recorder Panel Management

    private func showRecorderPanel() {
        guard let engine = engine, let recorder = recorder else { return }

        switch effectiveRecorderPanelStyle {
        case .notch:
            if notchWindowManager == nil {
                notchWindowManager = NotchWindowManager(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: engine.assistantSession,
                    onRecordButtonTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.toggleRecorderPanel()
                        }
                    },
                    onCloseTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.dismissRecorderPanel()
                        }
                    },
                    onAssistantFollowUp: { [weak engine] text in
                        Task { @MainActor in
                            await engine?.sendAssistantFollowUp(text)
                        }
                    }
                )
            }
            notchWindowManager?.show()
        case .mini:
            if miniWindowManager == nil {
                miniWindowManager = MiniWindowManager(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: engine.assistantSession,
                    onRecordButtonTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.toggleRecorderPanel()
                        }
                    },
                    onCloseTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.dismissRecorderPanel()
                        }
                    },
                    onAssistantFollowUp: { [weak engine] text in
                        Task { @MainActor in
                            await engine?.sendAssistantFollowUp(text)
                        }
                    }
                )
            }
            miniWindowManager?.show()
        case .halo:
            ensureHaloWindowManager(engine: engine, recorder: recorder).show()
        }
    }

    @discardableResult
    private func ensureHaloWindowManager(
        engine: VoiceInkEngine,
        recorder: Recorder
    ) -> HaloWindowManager {
        if let haloWindowManager {
            return haloWindowManager
        }

        let manager = HaloWindowManager(engine: engine, recorder: recorder)
        haloWindowManager = manager
        return manager
    }

    private func hideRecorderPanel() {
        hideRecorderPanel(style: effectiveRecorderPanelStyle)
    }

    private func hideRecorderPanel(
        style: RecorderPanelStyle,
        preservingHaloSession: Bool = false
    ) {
        switch style {
        case .notch:
            notchWindowManager?.hide()
        case .mini:
            miniWindowManager?.hide()
        case .halo:
            haloWindowManager?.hide(preservingSession: preservingHaloSession)
        }
    }

    private func rebuildVisiblePanel(previousStyle: RecorderPanelStyle) {
        guard isRecorderPanelVisible else { return }

        switch previousStyle {
        case .notch:
            notchWindowManager?.destroyWindow()
            notchWindowManager = nil
        case .mini:
            miniWindowManager?.destroyWindow()
            miniWindowManager = nil
        case .halo:
            haloWindowManager?.destroyWindow()
            haloWindowManager = nil
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            showRecorderPanel()
        }
    }

    private func handleStoredStyleChange() {
        haloPasteConfirmationTask?.cancel()
        haloPasteConfirmationTask = nil
        engine?.clearHaloSessionDeliveryOverride()
        if engine?.recordingState == .reviewing {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.cancelPendingPasteReview()
                self.effectiveRecorderPanelStyle = RecorderPanelRouting.effectiveStyle(
                    selectedStyle: self.recorderPanelStyle,
                    outputMode: ModeRuntimeResolver.outputConfiguration().outputMode
                )
            }
            return
        }

        let previousStyle = effectiveRecorderPanelStyle
        effectiveRecorderPanelStyle = RecorderPanelRouting.effectiveStyle(
            selectedStyle: recorderPanelStyle,
            outputMode: ModeRuntimeResolver.outputConfiguration().outputMode
        )
        if recorderPanelStyle == .halo,
            isRecorderPanelVisible,
            let engine,
            let recorder
        {
            ensureHaloWindowManager(engine: engine, recorder: recorder).beginRecordingSession()
        }
        rebuildVisiblePanel(previousStyle: previousStyle)
    }

    func reconcileRecorderPanel(for outputMode: ModeOutputMode) {
        let desiredStyle = RecorderPanelRouting.effectiveStyle(
            selectedStyle: recorderPanelStyle,
            outputMode: outputMode
        )
        guard desiredStyle != effectiveRecorderPanelStyle else { return }

        let previousStyle = effectiveRecorderPanelStyle
        if isRecorderPanelVisible {
            hideRecorderPanel(style: previousStyle, preservingHaloSession: true)
        }
        effectiveRecorderPanelStyle = desiredStyle

        if isRecorderPanelVisible {
            showRecorderPanel()
        }
    }

    // MARK: - Recorder Panel Management

    func toggleRecorderPanel(modeId: UUID? = nil) async {
        guard let engine = engine else { return }

        if isRecorderPanelVisible {
            switch engine.recordingState {
            case .recording:
                await engine.toggleRecord(modeId: modeId)
            case .starting, .transcribing, .enhancing:
                await cancelRecording()
            case .reviewing:
                return
            case .idle:
                if engine.assistantSession.canSendFollowUp {
                    SoundManager.shared.playStartSound()
                    await engine.toggleRecord(
                        modeId: modeId,
                        isAssistantFollowUp: true
                    )
                } else {
                    await dismissRecorderPanel()
                }
            case .busy:
                await dismissRecorderPanel()
            }
        } else {
            SoundManager.shared.playStartSound()
            if recorderPanelStyle == .halo, let recorder {
                ensureHaloWindowManager(engine: engine, recorder: recorder).beginRecordingSession()
            }
            let outputMode: ModeOutputMode
            if let modeId,
                let mode = ModeManager.shared.getConfiguration(with: modeId)
            {
                outputMode = mode.outputMode
            } else {
                outputMode = ModeRuntimeResolver.outputConfiguration().outputMode
            }
            effectiveRecorderPanelStyle = RecorderPanelRouting.effectiveStyle(
                selectedStyle: recorderPanelStyle,
                outputMode: outputMode
            )
            isRecorderPanelVisible = true
            await engine.toggleRecord(modeId: modeId)
        }
    }

    func dismissRecorderPanel() async {
        guard let engine = engine else { return }

        if engine.pendingPasteReview != nil {
            await engine.cancelPendingPasteReview()
            return
        }

        hideRecorderPanel()
        haloPasteConfirmationTask?.cancel()
        haloPasteConfirmationTask = nil
        isRecorderPanelVisible = false
        haloWindowManager?.endRecordingSession()
        finishPasteReviewKeyboardHandling()
        engine.assistantSession.reset()
    }

    func resetOnLaunch() async {
        guard let engine = engine else { return }
        logger.notice("Resetting recording state on launch")
        await engine.resetRecordingSession()
        haloPasteConfirmationTask?.cancel()
        haloPasteConfirmationTask = nil
        hideRecorderPanel()
        isRecorderPanelVisible = false
        haloWindowManager?.endRecordingSession()
        engine.assistantSession.reset()
    }

    func cancelRecording() async {
        guard let engine = engine else { return }
        await engine.cancelRecording()
        await dismissRecorderPanel()
    }

    func approvePendingPasteReview() async {
        await engine?.approvePendingPasteReview()
    }

    func cancelPendingPasteReview() async {
        await engine?.cancelPendingPasteReview()
    }

    func toggleHaloSessionDeliveryOverride() {
        engine?.toggleHaloSessionDeliveryOverride()
    }

    @discardableResult
    func selectHaloReviewLens(_ lens: HaloReviewLens) -> Bool {
        engine?.selectHaloReviewLens(lens) ?? false
    }

    @discardableResult
    func moveHaloReviewRevision(by offset: Int) -> Bool {
        engine?.moveHaloReviewRevision(by: offset) ?? false
    }

    @discardableResult
    func beginHaloRefinement(_ action: HaloRefinementAction) -> Bool {
        engine?.beginHaloRefinement(action) ?? false
    }

    @discardableResult
    func cancelHaloRefinementIfActive() -> Bool {
        engine?.cancelHaloRefinementIfActive() ?? false
    }

    @discardableResult
    func toggleHaloVoiceRefinementCapture() -> Bool {
        engine?.toggleHaloVoiceRefinementCapture() ?? false
    }

    @discardableResult
    func cancelHaloVoiceRefinementIfActive() -> Bool {
        engine?.cancelHaloVoiceRefinementIfActive() ?? false
    }

    @discardableResult
    func cancelHaloReviewTransientActionIfActive() -> Bool {
        if engine?.cancelHaloVoiceRefinementIfActive() == true {
            return true
        }
        if engine?.cancelHaloRefinementIfActive() == true {
            return true
        }
        return engine?.cancelHaloManualEditIfActive() ?? false
    }

    @discardableResult
    func beginPasteReviewFocusRecovery() -> Bool {
        engine?.beginPasteReviewFocusRecovery() ?? false
    }

    @discardableResult
    func useOriginalHaloReview() -> Bool {
        engine?.useOriginalHaloReview() ?? false
    }

    @discardableResult
    func beginHaloManualEdit() -> Bool {
        engine?.beginHaloManualEdit() ?? false
    }

    @discardableResult
    func updateHaloManualEdit(_ text: String) -> Bool {
        engine?.updateHaloManualEdit(text) ?? false
    }

    @discardableResult
    func saveHaloManualEdit() -> Bool {
        engine?.saveHaloManualEdit() ?? false
    }

    @discardableResult
    func cancelHaloManualEdit() -> Bool {
        engine?.cancelHaloManualEditIfActive() ?? false
    }

    func preparePasteReviewKeyboardHandling() -> Bool {
        guard isHaloPanelActive else { return false }
        return reviewShortcutController?.prepareForPasteReview() == true
    }

    func finishPasteReviewKeyboardHandling() {
        reviewShortcutController?.finishPasteReview()
    }

    func refreshPasteReviewKeyboardHandling() {
        reviewShortcutController?.refreshPasteReviewShortcuts()
    }

    func presentPasteReview(_ review: PendingPasteReview) {
        guard isHaloPanelActive else { return }
        haloWindowManager?.presentReview(
            rawText: review.rawText,
            finalText: review.finalText,
            modeName: review.modeName,
            providerLabel: review.providerLabel,
            connectionLabel: review.connectionLabel,
            modelLabel: review.modelLabel,
            enhancementWarning: review.enhancementWarning,
            deliveryReviewReason: review.deliveryReviewReason
        )
    }

    func clearPasteReview() {
        haloWindowManager?.clearReview()
    }

    func showHaloPasteConfirmation() {
        guard isRecorderPanelVisible,
            effectiveRecorderPanelStyle == .halo
        else {
            Task { @MainActor [weak self] in
                await self?.dismissRecorderPanel()
            }
            return
        }

        finishPasteReviewKeyboardHandling()
        haloWindowManager?.presentPasteConfirmation()
        haloPasteConfirmationTask?.cancel()
        haloPasteConfirmationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            guard let self else { return }
            self.haloPasteConfirmationTask = nil
            await self.dismissRecorderPanel()
        }
    }

    // MARK: - Notification Handling

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleRecorderPanelNotification),
            name: .toggleRecorderPanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissRecorderPanelNotification),
            name: .dismissRecorderPanel,
            object: nil
        )
    }

    @objc public func handleToggleRecorderPanelNotification() {
        Task {
            await toggleRecorderPanel()
        }
    }

    @objc public func handleDismissRecorderPanelNotification() {
        Task {
            switch engine?.recordingState {
            case .starting, .recording, .transcribing, .enhancing:
                await cancelRecording()
            case .reviewing:
                await cancelPendingPasteReview()
            case .idle, .busy, nil:
                await dismissRecorderPanel()
            }
        }
    }
}

extension RecorderUIManager: PasteReviewDestinationProviding {
    var pasteReviewDestinationSnapshot: PasteReviewDestinationSnapshot? {
        haloWindowManager?.capturedDestinationSnapshot
    }
}

extension RecorderUIManager: PasteReviewRecoveryPresenting {
    func hidePasteReviewForDelivery() {
        guard effectiveRecorderPanelStyle == .halo else { return }
        haloWindowManager?.hide(preservingSession: true)
    }

    func restorePasteReviewAfterFailedDelivery() {
        guard isRecorderPanelVisible,
            effectiveRecorderPanelStyle == .halo,
            let review = engine?.pendingPasteReview
        else {
            return
        }

        haloWindowManager?.show()
        presentPasteReview(review)
    }

    func beginPasteReviewFocusRecovery() {
        guard effectiveRecorderPanelStyle == .halo else { return }
        haloWindowManager?.beginFocusRecovery()
    }

    func endPasteReviewFocusRecovery() {
        guard isRecorderPanelVisible,
            effectiveRecorderPanelStyle == .halo
        else {
            return
        }
        haloWindowManager?.endFocusRecovery()
    }
}
