import SwiftUI

struct HaloSettingsView: View {
    @EnvironmentObject private var capabilities: HaloCapabilityStore
    @EnvironmentObject private var engine: VoiceInkEngine
    @EnvironmentObject private var recorderUIManager: RecorderUIManager
    @EnvironmentObject private var navigation: MainWindowNavigation

    var body: some View {
        Form {
            meetHaloSection
            instructionSection
            alternativesSection
            destinationSection
            timeShiftSection
            safetySection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var meetHaloSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(AppTheme.Accent.primary)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(recorderUIManager.recorderPanelStyle == .halo ? "Halo is ready" : "Meet Halo")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Halo appears for Paste Modes. Respond and Custom Command Modes continue using Mini.")
                            .settingsDescription()
                    }
                }

                HStack(spacing: 10) {
                    if recorderUIManager.recorderPanelStyle != .halo {
                        Button("Use Halo") {
                            recorderUIManager.recorderPanelStyle = .halo
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button("Manage Modes") {
                        navigation.navigate(to: ViewType.modes.rawValue)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var instructionSection: some View {
        Section("Tell Halo what you want") {
            Toggle("Spoken refinements", isOn: $capabilities.spokenRefinementEnabled)
            Toggle("Typed refinements", isOn: $capabilities.typedRefinementEnabled)
            Toggle("Exact voice review commands", isOn: $capabilities.voiceCommandsEnabled)

            Text("Spoken refinements are always shown for confirmation before Halo sends a model request. Exact commands begin with “Halo”.")
                .settingsDescription()
        }
    }

    private var alternativesSection: some View {
        Section("Explore alternatives") {
            Toggle("Another Take", isOn: $capabilities.anotherTakeEnabled)

            Toggle(isOn: $capabilities.parallelComparisonEnabled) {
                HStack(spacing: 5) {
                    Text("Compare Precise & Natural")
                    Text("2 requests")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.Accent.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppTheme.Accent.primary.opacity(0.12), in: Capsule())
                }
            }

            Text("Alternatives always reuse the active Mode’s provider, connection, model, requirements, vocabulary, and frozen context.")
                .settingsDescription()
        }
    }

    private var destinationSection: some View {
        Section("Stay connected to your field") {
            Toggle("Guide me back to the original app", isOn: $capabilities.guidedRecoveryEnabled)

            Picker("Halo position", selection: $capabilities.positionBehavior) {
                ForEach(HaloPositionBehavior.allCases) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }
            .pickerStyle(.menu)

            Text("Following the caret moves only Halo’s visual anchor. The captured paste destination never changes.")
                .settingsDescription()
        }
    }

    private var timeShiftSection: some View {
        Section("Capture what you just missed") {
            Toggle("Time-Shift Capture", isOn: $capabilities.timeShiftEnabled)

            if capabilities.timeShiftEnabled {
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(engine.timeShiftPresentation.statusLabel)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(timeShiftStatusColor)
                        Text(engine.timeShiftPresentation.detailLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label("Status", systemImage: engine.timeShiftPresentation.systemImage)
                }

                HStack(spacing: 8) {
                    Button(timeShiftArmActionLabel) {
                        Task { @MainActor in
                            await engine.toggleTimeShiftArming()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canToggleTimeShift)

                    Button("Capture Last 15 Seconds") {
                        Task { @MainActor in
                            await engine.captureTimeShift()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.timeShiftPresentation.kind != .armed)
                }

                LabeledContent("Arm or Disarm") {
                    ShortcutRecorder(action: .toggleTimeShift)
                        .controlSize(.small)
                }

                LabeledContent("Capture Last 15 Seconds") {
                    ShortcutRecorder(action: .captureTimeShift)
                        .controlSize(.small)
                }
            }

            Text("Time-Shift is one-shot and starts disarmed. While armed, it keeps at most 15 seconds in memory, writes no audio file, and uploads nothing until you choose Capture.")
                .settingsDescription()
        }
    }

    private var timeShiftArmActionLabel: String {
        switch engine.timeShiftPresentation.kind {
        case .arming, .armed:
            return String(localized: "Disarm")
        case .disabled, .unavailable, .ready, .capturing, .processing:
            return String(localized: "Arm")
        }
    }

    private var canToggleTimeShift: Bool {
        switch engine.timeShiftPresentation.kind {
        case .ready, .arming, .armed:
            return true
        case .disabled, .unavailable, .capturing, .processing:
            return false
        }
    }

    private var timeShiftStatusColor: Color {
        switch engine.timeShiftPresentation.tone {
        case .muted:
            return .secondary
        case .accent:
            return AppTheme.Accent.primary
        case .warning:
            return AppTheme.Status.warningStrong
        }
    }

    private var safetySection: some View {
        Section("Safety you can rely on") {
            safetyRow("Paste only after destination validation", icon: "scope")
            safetyRow("Deliver each approved result at most once", icon: "checkmark.shield")
            safetyRow("Keep the selected provider, connection, and model", icon: "link")
            safetyRow("Show a visible indicator whenever Time-Shift is armed", icon: "eye")
            safetyRow("Clear Time-Shift memory on every exit path", icon: "memorychip")
        }
    }

    private func safetyRow(_ title: LocalizedStringKey, icon: String) -> some View {
        Label {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.Accent.primary)
        }
    }
}
