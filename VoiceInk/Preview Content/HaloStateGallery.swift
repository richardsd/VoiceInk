#if DEBUG
import SwiftUI

/// Development-only visual regression canvas for the focus-preserving Halo.
///
/// Open the canvas for this file in Xcode to inspect production Halo rendering
/// across representative states and destination contrast levels. The gallery
/// is intentionally disconnected from app navigation and uses a volatile
/// UserDefaults domain so inspecting it cannot change recorder settings.
@MainActor
private struct HaloStateGallery: View {
    @StateObject private var recorder: Recorder

    init() {
        let recorder = Recorder()
        recorder.audioMeter = AudioMeter(averagePower: 0.58, peakPower: 0.76)
        _recorder = StateObject(wrappedValue: recorder)
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 26) {
                galleryHeader

                ForEach(HaloGalleryScenario.allCases) { scenario in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: scenario.title)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.primary)

                        HStack(alignment: .top, spacing: 16) {
                            ForEach(HaloGalleryBackdrop.allCases) { backdrop in
                                HaloStateGalleryStage(
                                    scenario: scenario,
                                    backdrop: backdrop,
                                    recorder: recorder
                                )
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .defaultAppStorage(HaloStateGalleryDefaults.store)
    }

    private var galleryHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: "Halo state gallery")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(verbatim: "Production views on light, dark, and high-contrast destination surfaces")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.secondary)

            HStack(spacing: 16) {
                ForEach(HaloGalleryBackdrop.allCases) { backdrop in
                    Text(verbatim: backdrop.title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.secondary)
                        .frame(width: HaloStateGalleryStage.stageWidth, alignment: .leading)
                }
            }
            .padding(.top, 11)
        }
    }
}

@MainActor
private struct HaloStateGalleryStage: View {
    static let stageWidth: CGFloat = 560

    let scenario: HaloGalleryScenario
    let backdrop: HaloGalleryBackdrop
    @ObservedObject var recorder: Recorder

    @StateObject private var stateProvider: HaloGalleryStateProvider
    @StateObject private var presentation: HaloPresentationModel

    init(
        scenario: HaloGalleryScenario,
        backdrop: HaloGalleryBackdrop,
        recorder: Recorder
    ) {
        self.scenario = scenario
        self.backdrop = backdrop
        self.recorder = recorder

        _stateProvider = StateObject(
            wrappedValue: HaloGalleryStateProvider(
                recordingState: scenario.recordingState,
                partialTranscript: scenario.partialTranscript
            )
        )

        let presentation = HaloPresentationModel()
        scenario.configure(presentation)
        _presentation = StateObject(wrappedValue: presentation)
    }

    var body: some View {
        ZStack {
            HaloGalleryBackdropView(backdrop: backdrop)

            HaloRecorderView(
                stateProvider: stateProvider,
                recorder: recorder,
                presentation: presentation,
                onApply: {},
                onCancel: {},
                onCopy: {},
                onRetry: {},
                onRefocus: {},
                onUseOriginal: {},
                onBeginManualEdit: {},
                onUpdateManualEdit: { _ in },
                onSaveManualEdit: {},
                onCancelManualEdit: {},
                onSelectReviewLens: { _ in },
                onMoveReviewRevision: { _ in },
                onRefine: { _ in },
                onReviewInteractiveRegionsChange: { _ in }
            )
            .frame(width: panelWindowSize.width, height: panelWindowSize.height)
            .environment(\.colorScheme, .dark)
        }
        .frame(width: Self.stageWidth, height: stageHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(backdrop.borderColor, lineWidth: 0.7)
        }
    }

    private var surfaceSize: CGSize {
        if scenario == .reviewFocusRecovery {
            return HaloPanelMetrics.focusRecovery
        }
        return HaloPanelMetrics.size(
            for: scenario.phase,
            hasVisiblePartialTranscript: !scenario.partialTranscript.isEmpty
        )
    }

    private var panelWindowSize: CGSize {
        HaloPanelMetrics.windowSize(for: surfaceSize)
    }

    private var stageHeight: CGFloat {
        max(142, panelWindowSize.height + 48)
    }
}

@MainActor
private final class HaloGalleryStateProvider: ObservableObject, RecorderStateProvider {
    @Published var recordingState: RecordingState
    @Published var partialTranscript: String

    init(recordingState: RecordingState, partialTranscript: String) {
        self.recordingState = recordingState
        self.partialTranscript = partialTranscript
    }
}

private enum HaloGalleryScenario: String, CaseIterable, Identifiable {
    case compactListening
    case liveTranscript
    case transcribing
    case enhancing
    case reviewFinal
    case reviewFallbackWarning
    case reviewFocusMismatch
    case reviewFocusRecovery
    case reviewManualEdit
    case pastedConfirmation

    var id: Self { self }

    var title: String {
        switch self {
        case .compactListening:
            return "Listening · compact"
        case .liveTranscript:
            return "Listening · live transcript"
        case .transcribing:
            return "Transcribing"
        case .enhancing:
            return "Enhancing · Quick Apply armed"
        case .reviewFinal:
            return "Review · enhanced result"
        case .reviewFallbackWarning:
            return "Review · raw fallback warning"
        case .reviewFocusMismatch:
            return "Review · destination focus mismatch"
        case .reviewFocusRecovery:
            return "Review · manual focus recovery"
        case .reviewManualEdit:
            return "Review · manual edit"
        case .pastedConfirmation:
            return "Direct delivery · confirmation pulse"
        }
    }

    var phase: HaloPresentationPhase {
        switch self {
        case .compactListening, .liveTranscript:
            return .listening
        case .transcribing:
            return .transcribing
        case .enhancing:
            return .enhancing
        case .reviewFinal,
            .reviewFallbackWarning,
            .reviewFocusMismatch,
            .reviewFocusRecovery,
            .reviewManualEdit:
            return .reviewing
        case .pastedConfirmation:
            return .confirmed
        }
    }

    var recordingState: RecordingState {
        switch phase {
        case .listening:
            return .recording
        case .transcribing:
            return .transcribing
        case .enhancing:
            return .enhancing
        case .reviewing:
            return .reviewing
        case .confirmed:
            return .idle
        }
    }

    var partialTranscript: String {
        guard self == .liveTranscript else { return "" }
        return "We can move forward with the restructuring, but let’s do one section at a time and start with the introduction."
    }

    @MainActor
    func configure(_ presentation: HaloPresentationModel) {
        presentation.updateMetadata(
            HaloPresentationMetadata(
                applicationName: "TextEdit",
                modeName: "Voice Dictation",
                contextLabels: ["Clipboard", "Selected text"],
                providerLabel: "OpenAI",
                connectionLabel: "ChatGPT OAuth",
                modelLabel: "gpt-5.6-luna"
            )
        )

        switch self {
        case .compactListening, .liveTranscript, .transcribing:
            presentation.setPhase(phase)

        case .enhancing:
            presentation.updateDeliveryOverride(.forceDirect)
            presentation.setPhase(.enhancing)

        case .reviewFinal:
            presentReview(
                on: presentation,
                warning: nil,
                feedback: nil
            )

        case .reviewFallbackWarning:
            presentReview(
                on: presentation,
                finalText: "We can move forward with the restructuring, but let’s work through one section at a time.",
                warning: "Enhancement was unavailable. Review the original transcript before applying.",
                feedback: nil
            )

        case .reviewFocusMismatch:
            presentReview(
                on: presentation,
                warning: nil,
                feedback: .destinationChanged(
                    PasteReviewDestinationMismatch(
                        expectedApplicationName: "TextEdit",
                        currentApplicationName: "Safari"
                    )
                )
            )

        case .reviewFocusRecovery:
            presentReview(
                on: presentation,
                warning: nil,
                feedback: nil
            )
            presentation.updateFocusRecovery(isRefocusing: true)

        case .reviewManualEdit:
            presentReview(
                on: presentation,
                warning: nil,
                feedback: nil,
                isEditingManually: true
            )

        case .pastedConfirmation:
            presentation.presentPasteConfirmation()
        }
    }

    @MainActor
    private func presentReview(
        on presentation: HaloPresentationModel,
        finalText: String = "We can move forward with the restructuring, but let’s handle one section at a time, beginning with the introduction.",
        warning: String?,
        feedback: PasteReviewFeedback?,
        isEditingManually: Bool = false
    ) {
        let rawText = "We can move forward with the restructuring but lets do one section at a time and start with the introduction please."
        let metadata = HaloReviewModelMetadata(
            modeName: "Voice Dictation",
            modeEmoji: "mic.fill",
            providerLabel: "OpenAI",
            connectionLabel: "ChatGPT OAuth",
            modelLabel: "gpt-5.6-luna"
        )
        let output = OutputRuntimeConfiguration(
            mode: nil,
            outputMode: .paste,
            haloDeliveryPolicy: .alwaysReview,
            autoSendKey: .none,
            customCommand: nil
        )
        let prompt = CustomPrompt(
            title: "Voice Dictation",
            promptText: "Keep every material fact.",
            useSystemInstructions: false
        )
        let configuration = EnhancementRuntimeConfiguration(
            mode: nil,
            isEnabled: true,
            prompt: prompt,
            provider: .openAI,
            modelName: "gpt-5.6-luna",
            openAIAuthMode: .oauth,
            useClipboardContext: true,
            useSelectedTextContext: true,
            useScreenCaptureContext: true
        )
        let session = HaloReviewSession(
            transcriptionID: UUID(),
            rawText: rawText,
            initialEnhancement: warning == nil ? finalText : nil,
            destination: nil,
            metadata: metadata,
            enhancementWarning: warning,
            output: output,
            enhancementConfiguration: configuration,
            frozenContext: nil
        )
        let initialRevision = HaloReviewRevision(
            parentID: nil,
            action: .initial,
            text: finalText,
            metadata: metadata,
            payload: PreparedPastePayload(
                displayText: finalText,
                pastedText: finalText,
                autoSendKey: .none
            )
        )
        var state = HaloReviewState(session: session, initialRevision: initialRevision)
        if isEditingManually {
            let now = Date()
            _ = HaloReviewReducer.reduce(
                state: &state,
                action: .beginManualEdit(at: now)
            )
            _ = HaloReviewReducer.reduce(
                state: &state,
                action: .updateManualEdit(
                    "We can move forward with the restructuring, one section at a time, starting with the introduction.",
                    at: now
                )
            )
        }
        presentation.updateReviewState(state)
        presentation.updateReviewStatus(
            feedback: feedback,
            secondsRemaining: feedback == nil ? 12 : 84,
            isDelivering: false
        )
    }
}

private enum HaloGalleryBackdrop: String, CaseIterable, Identifiable {
    case light
    case dark
    case highContrast

    var id: Self { self }

    var title: String {
        switch self {
        case .light:
            return "Light destination"
        case .dark:
            return "Dark destination"
        case .highContrast:
            return "High contrast"
        }
    }

    var borderColor: Color {
        switch self {
        case .light:
            return Color.black.opacity(0.14)
        case .dark:
            return Color.white.opacity(0.13)
        case .highContrast:
            return Color.white.opacity(0.72)
        }
    }
}

private struct HaloGalleryBackdropView: View {
    let backdrop: HaloGalleryBackdrop

    var body: some View {
        ZStack {
            background

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Circle().frame(width: 8, height: 8)
                    Circle().frame(width: 8, height: 8)
                    Circle().frame(width: 8, height: 8)
                }
                .opacity(0.24)

                ForEach([0.86, 0.72, 0.91, 0.54], id: \.self) { width in
                    Capsule()
                        .frame(width: 330 * width, height: 7)
                        .opacity(0.10)
                }
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(18)
        }
    }

    @ViewBuilder
    private var background: some View {
        switch backdrop {
        case .light:
            Color(red: 0.96, green: 0.97, blue: 0.98)
        case .dark:
            Color(red: 0.055, green: 0.06, blue: 0.07)
        case .highContrast:
            ZStack {
                Color.black
                HStack(spacing: 0) {
                    Color.white
                    Color.black
                }
                .opacity(0.96)
            }
        }
    }

    private var foreground: Color {
        switch backdrop {
        case .light:
            return .black
        case .dark:
            return .white
        case .highContrast:
            return .gray
        }
    }
}

private enum HaloStateGalleryDefaults {
    private static let suiteName = "com.voiceink.preview.halo-state-gallery"

    static let store: UserDefaults = {
        guard let store = UserDefaults(suiteName: suiteName) else {
            return .standard
        }
        store.setVolatileDomain(
            [RecorderDisplaySettingsKeys.showLiveTranscript: true],
            forName: suiteName
        )
        return store
    }()
}

#Preview("Halo state gallery") {
    HaloStateGallery()
        .frame(width: 1760, height: 1080)
}
#endif
