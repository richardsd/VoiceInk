import SwiftUI
import SwiftData

struct RecordTranscribeView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var engine: VoiceInkEngine
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @StateObject private var recordManager = RecordTranscriptionManager.shared
    @ObservedObject private var mediaController = MediaController.shared
    @ObservedObject private var modeManager = ModeManager.shared
    @State private var isEnhancementEnabled = false
    @State private var selectedPromptId: UUID?
    @State private var isAIRequestExpanded = false

    var body: some View {
        ZStack {
            Color(NSColor.controlBackgroundColor)
                .ignoresSafeArea()

            switch recordManager.recordingState {
            case .idle, .error:
                idleView
            case .recording:
                recordingView
            case .processingAudio, .transcribing, .enhancing:
                processingView
            case .completed:
                resultView
            }
        }
        .alert("Error", isPresented: .constant(recordManager.errorMessage != nil)) {
            Button("OK", role: .cancel) {
                recordManager.errorMessage = nil
            }
        } message: {
            if let errorMessage = recordManager.errorMessage {
                Text(errorMessage)
            }
        }
        .onAppear {
            refreshEnhancementStateFromMode()
        }
    }

    // MARK: - Idle State

    private var idleView: some View {
        VStack(spacing: 24) {
            Spacer()

            Button {
                Task {
                    await recordManager.startRecording()
                }
            } label: {
                VStack(spacing: 12) {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.red)

                    Text("Tap to start recording")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            enhancementSettingsCard

            Spacer()
        }
        .padding()
    }

    // MARK: - Recording State

    private var recordingView: some View {
        VStack(spacing: 24) {
            Spacer()

            AudioVisualizer(
                audioMeter: recordManager.recorder.audioMeter,
                color: .red,
                isActive: true
            )
            .frame(height: 40)
            .padding(.horizontal, 40)

            Text(formatDuration(recordManager.recordingDuration))
                .font(.system(size: 48, weight: .light, design: .monospaced))
                .foregroundStyle(.primary)

            HStack(spacing: 24) {
                Button {
                    Task {
                        await recordManager.cancelRecording()
                    }
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .font(.body)
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        await recordManager.stopRecording(modelContext: modelContext, engine: engine)
                    }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Processing State

    private var processingView: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView()
                .scaleEffect(0.8)

            Text(recordManager.processingPhaseMessage)
                .font(.headline)

            Spacer()
        }
        .padding()
    }

    // MARK: - Result State (rich layout)

    private var resultView: some View {
        VStack(spacing: 0) {
            // Top bar with New Recording button
            HStack {
                Button {
                    isAIRequestExpanded = false
                    recordManager.reset()
                } label: {
                    Label("New Recording", systemImage: "mic.circle")
                        .font(.body)
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if let transcription = recordManager.currentTranscription {
                ScrollView {
                    VStack(spacing: 16) {
                        // Message bubbles
                        MessageBubble(
                            label: "Original",
                            text: transcription.text,
                            isEnhanced: false
                        )

                        if let enhancedText = transcription.enhancedText {
                            MessageBubble(
                                label: "Enhanced",
                                text: enhancedText,
                                isEnhanced: true
                            )
                        }

                        // Audio player
                        if let urlString = transcription.audioFileURL,
                           let url = URL(string: urlString),
                           FileManager.default.fileExists(atPath: url.path) {
                            AudioPlayerView(url: url, transcription: transcription)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                                )
                        }

                        // Metadata details card
                        metadataCard(for: transcription)

                        // Collapsible AI Request
                        if transcription.aiRequestSystemMessage != nil || transcription.aiRequestUserMessage != nil {
                            aiRequestSection(for: transcription)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - Metadata Card

    private func metadataCard(for transcription: Transcription) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.system(size: 14, weight: .semibold))
                .padding(.bottom, 2)

            metadataRow(icon: "calendar", label: "Date", value: transcription.timestamp.formatted(date: .abbreviated, time: .shortened))

            Divider()

            metadataRow(icon: "hourglass", label: "Duration", value: transcription.duration.formatTiming())

            if let modelName = transcription.transcriptionModelName {
                Divider()
                metadataRow(icon: "cpu.fill", label: "Transcription Model", value: modelName)

                if let duration = transcription.transcriptionDuration {
                    Divider()
                    metadataRow(icon: "clock.fill", label: "Transcription Time", value: duration.formatTiming())
                }
            }

            if let aiModel = transcription.aiEnhancementModelName {
                Divider()
                metadataRow(icon: "sparkles", label: "Enhancement Model", value: aiModel)

                if let duration = transcription.enhancementDuration {
                    Divider()
                    metadataRow(icon: "clock.fill", label: "Enhancement Time", value: duration.formatTiming())
                }
            }

            if let promptName = transcription.promptName {
                Divider()
                metadataRow(icon: "text.bubble.fill", label: "Prompt", value: promptName)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
    }

    private func metadataRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 20)

            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            Spacer(minLength: 0)

            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
    }

    // MARK: - AI Request Section

    private func aiRequestSection(for transcription: Transcription) -> some View {
        DisclosureGroup("AI Request", isExpanded: $isAIRequestExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if let systemMsg = transcription.aiRequestSystemMessage, !systemMsg.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("System Prompt")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(systemMsg)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .foregroundColor(.primary)
                    }
                }

                if let userMsg = transcription.aiRequestUserMessage, !userMsg.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("User Message")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(userMsg)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .foregroundColor(.primary)
                    }
                }
            }
            .padding(.top, 8)
        }
        .font(.system(size: 14, weight: .semibold))
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
    }

    // MARK: - Enhancement Settings

    private var enhancementSettingsCard: some View {
        VStack(spacing: 12) {
            Toggle("AI Enhancement", isOn: $isEnhancementEnabled)
                .toggleStyle(.switch)
                .onChange(of: isEnhancementEnabled) { _, newValue in
                    updateCurrentMode { mode in
                        mode.isAIEnhancementEnabled = newValue
                        if newValue, mode.selectedPrompt == nil {
                            mode.selectedPrompt = enhancementService.allPrompts.first?.id.uuidString
                        }
                    }
                }

            Divider()

            Toggle("Mute Device Audio", isOn: $mediaController.isSystemMuteEnabled)
                .toggleStyle(.switch)

            if isEnhancementEnabled {
                Divider()

                HStack(spacing: 8) {
                    Text("Prompt:")
                        .font(.subheadline)
                        .fixedSize()

                    if enhancementService.allPrompts.isEmpty {
                        Text("No prompts available")
                            .foregroundColor(.secondary)
                            .italic()
                            .font(.caption)
                    } else {
                        let promptBinding = Binding<UUID>(
                            get: {
                                selectedPromptId ?? enhancementService.allPrompts.first?.id ?? UUID()
                            },
                            set: { newValue in
                                selectedPromptId = newValue
                                updateCurrentMode { mode in
                                    mode.selectedPrompt = newValue.uuidString
                                }
                            }
                        )

                        Picker("", selection: promptBinding) {
                            ForEach(enhancementService.allPrompts) { prompt in
                                Text(prompt.title).tag(prompt.id)
                            }
                        }
                        .labelsHidden()
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppCardBackground(isSelected: false, cornerRadius: 12))
        .frame(maxWidth: 400)
    }

    // MARK: - Helpers

    private func refreshEnhancementStateFromMode() {
        let mode = modeManager.currentEffectiveConfiguration
        isEnhancementEnabled = mode?.isAIEnhancementEnabled ?? false
        selectedPromptId = mode?.selectedPrompt.flatMap(UUID.init(uuidString:))
    }

    private func updateCurrentMode(_ update: (inout ModeConfig) -> Void) {
        guard var mode = modeManager.currentEffectiveConfiguration ?? modeManager.configurations.first else {
            return
        }
        update(&mode)
        modeManager.updateConfiguration(mode)
        if modeManager.activeConfiguration?.id == mode.id {
            modeManager.setActiveConfiguration(mode)
        }
        refreshEnhancementStateFromMode()
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
