import SwiftUI
import SwiftData

struct RecordTranscribeView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var engine: VoiceInkEngine
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @StateObject private var recordManager = RecordTranscriptionManager.shared
    @State private var isEnhancementEnabled = false
    @State private var selectedPromptId: UUID?

    var body: some View {
        ZStack {
            Color(NSColor.controlBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                switch recordManager.recordingState {
                case .idle, .error:
                    idleView
                case .recording:
                    recordingView
                case .processingAudio, .transcribing, .enhancing:
                    processingView
                case .completed:
                    completedView
                }

                if let transcription = recordManager.currentTranscription {
                    Divider()
                        .padding(.vertical)
                    TranscriptionResultView(transcription: transcription)
                }
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
            isEnhancementEnabled = enhancementService.isEnhancementEnabled
            selectedPromptId = enhancementService.selectedPromptId
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
                    recordManager.cancelRecording()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .font(.body)
                }
                .buttonStyle(.bordered)

                Button {
                    recordManager.stopRecording(modelContext: modelContext, engine: engine)
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

    // MARK: - Completed State

    private var completedView: some View {
        VStack(spacing: 16) {
            Button {
                recordManager.reset()
            } label: {
                Label("New Recording", systemImage: "mic.circle")
                    .font(.body)
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Enhancement Settings

    private var enhancementSettingsCard: some View {
        VStack(spacing: 12) {
            Toggle("AI Enhancement", isOn: $isEnhancementEnabled)
                .toggleStyle(.switch)
                .onChange(of: isEnhancementEnabled) { _, newValue in
                    enhancementService.isEnhancementEnabled = newValue
                }

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
                                enhancementService.selectedPromptId = newValue
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
        .background(CardBackground(isSelected: false))
        .frame(maxWidth: 400)
    }

    // MARK: - Helpers

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
