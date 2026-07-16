import SwiftUI

struct HaloRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    @ObservedObject var presentation: HaloPresentationModel
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onApply: () -> Void
    let onCancel: () -> Void
    let onCopy: () -> Void
    let onRetry: () -> Void
    let onReviewInteractiveRegionsChange: ([CGRect]) -> Void

    private let coral = Color(red: 0.96, green: 0.34, blue: 0.29)
    private let charcoal = Color(red: 0.075, green: 0.078, blue: 0.085)

    init(
        stateProvider: S,
        recorder: Recorder,
        presentation: HaloPresentationModel,
        onApply: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onReviewInteractiveRegionsChange: @escaping ([CGRect]) -> Void
    ) {
        self.stateProvider = stateProvider
        self.recorder = recorder
        self.presentation = presentation
        self.onApply = onApply
        self.onCancel = onCancel
        self.onCopy = onCopy
        self.onRetry = onRetry
        self.onReviewInteractiveRegionsChange = onReviewInteractiveRegionsChange
    }

    private var visiblePartialTranscript: String? {
        guard showLiveTranscript,
            presentation.phase == .listening
        else {
            return nil
        }

        let partial = stateProvider.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        return partial.isEmpty ? nil : partial
    }

    var body: some View {
        ZStack {
            haloGlow
            phaseContent
                .padding(horizontalPadding)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(charcoal.opacity(0.985))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 0.8)
                }
                .shadow(color: Color.black.opacity(0.42), radius: 15, y: 6)
        }
        .padding(3)
        .coordinateSpace(name: HaloReviewCoordinateSpace.name)
        .onPreferenceChange(HaloReviewInteractiveRegionsKey.self) { regions in
            onReviewInteractiveRegionsChange(presentation.phase == .reviewing ? regions : [])
        }
        .animation(contentAnimation, value: presentation.phase)
        .animation(contentAnimation, value: visiblePartialTranscript != nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch presentation.phase {
        case .listening:
            listeningContent
                .transition(phaseTransition)
        case .transcribing:
            progressContent(
                icon: "text.bubble",
                title: String(localized: "Transcribing"),
                subtitle: String(localized: "Preparing your words")
            )
            .transition(phaseTransition)
        case .enhancing:
            enhancingContent
                .transition(phaseTransition)
        case .reviewing:
            reviewingContent
                .transition(phaseTransition)
        case .confirmed:
            confirmationContent
                .transition(phaseTransition)
        }
    }

    private var listeningContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(coral.opacity(0.14))
                    Circle()
                        .stroke(coral.opacity(0.42), lineWidth: 0.7)
                    Circle()
                        .fill(coral)
                        .frame(width: 6, height: 6)
                }
                .frame(width: 22, height: 22)

                AudioVisualizer(
                    audioMeter: recorder.audioMeter,
                    color: coral,
                    isActive: true
                )
                .scaleEffect(x: 0.76, y: 0.70)
                .frame(width: 62, height: 24)

                Spacer(minLength: 4)

                if overrideStatusLabel != nil {
                    overrideStatusChip
                } else {
                    destinationLabel
                }
            }

            if let visiblePartialTranscript {
                HaloLiveTranscriptView(text: visiblePartialTranscript)
                    .transition(liveTranscriptTransition)
            }
        }
    }

    private func progressContent(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(AppTheme.Accent.fill)
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.Accent.strong)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(HaloTypography.statusTitle)
                    .foregroundStyle(Color.white.opacity(0.92))
                Text(subtitle)
                    .font(HaloTypography.statusDetail)
                    .foregroundStyle(Color.white.opacity(0.52))
            }

            Spacer(minLength: 6)
            if overrideStatusLabel != nil {
                overrideStatusChip
            } else {
                progressIndicator(speed: 0.2)
            }
        }
    }

    private var enhancingContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Accent.strong)

                Text("Enhancing")
                    .font(HaloTypography.statusTitle)
                    .foregroundStyle(Color.white.opacity(0.92))

                Spacer(minLength: 6)
                progressIndicator(speed: 0.22)
            }

            HStack(spacing: 5) {
                if overrideStatusLabel != nil {
                    overrideStatusChip
                }
                chipRow
            }
        }
    }

    private var confirmationContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.Status.positive)
            Text("Pasted")
                .font(HaloTypography.statusTitle)
                .foregroundStyle(Color.white.opacity(0.94))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var reviewingContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(AppTheme.Accent.fillStrong)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.92))
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Ready to apply")
                        .font(HaloTypography.reviewTitle)
                        .foregroundStyle(Color.white.opacity(0.94))
                    Text(reviewDestinationDescription)
                        .font(HaloTypography.reviewDestination)
                        .foregroundStyle(Color.white.opacity(0.52))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            metadataRow

            if let review = presentation.review {
                reviewTextViewport(review)

                if let warning = sanitized(review.enhancementWarning), !warning.isEmpty {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(HaloTypography.warning)
                        .foregroundStyle(AppTheme.Status.warningStrong.opacity(0.9))
                        .lineLimit(2)
                }

                reviewStatusRows
            } else {
                Text("Your transcript is ready.")
                    .font(HaloTypography.reviewFinal)
                    .foregroundStyle(Color.white.opacity(0.72))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            HStack(spacing: 8) {
                let showsRetry = presentation.reviewFeedback?.allowsRetry == true
                HaloReviewActionButton(
                    key: "↩",
                    title: showsRetry ? String(localized: "Retry") : String(localized: "Apply"),
                    systemImage: nil,
                    emphasized: true,
                    isDisabled: presentation.isReviewDelivering,
                    action: showsRetry ? onRetry : onApply
                )
                HaloReviewActionButton(
                    key: "Esc",
                    title: String(localized: "Cancel"),
                    systemImage: nil,
                    emphasized: false,
                    isDisabled: presentation.isReviewDelivering,
                    action: onCancel
                )
                HaloReviewActionButton(
                    key: nil,
                    title: String(localized: "Copy"),
                    systemImage: "doc.on.doc",
                    emphasized: false,
                    isDisabled: presentation.isReviewDelivering,
                    action: onCopy
                )
                Spacer(minLength: 0)
                Text("Saved to History")
                    .font(HaloTypography.tertiary)
                    .foregroundStyle(Color.white.opacity(0.38))
            }
        }
    }

    @ViewBuilder
    private var reviewStatusRows: some View {
        if let feedback = presentation.reviewFeedback {
            Label(feedback.message, systemImage: feedbackIcon(feedback))
                .font(HaloTypography.warning)
                .foregroundStyle(feedbackColor(feedback))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let secondsRemaining = presentation.reviewSecondsRemaining,
            PasteReviewExpiration.isInWarningWindow(secondsRemaining: secondsRemaining)
        {
            Label(
                String(
                    format: String(localized: "Review expires in %d seconds"),
                    secondsRemaining
                ),
                systemImage: "clock.badge.exclamationmark"
            )
            .font(HaloTypography.warning)
            .foregroundStyle(AppTheme.Status.warningStrong.opacity(0.9))
            .lineLimit(1)
        }
    }

    private func reviewTextViewport(_ review: HaloReviewPresentation) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 9) {
                    if review.showsRawText {
                        Text(review.rawText)
                            .font(HaloTypography.reviewRaw)
                            .foregroundStyle(Color.white.opacity(0.52))
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Rectangle()
                            .fill(Color.white.opacity(0.10))
                            .frame(height: 1)
                    }

                    Text(review.finalText)
                        .font(HaloTypography.reviewFinal)
                        .foregroundStyle(Color.white.opacity(0.94))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(HaloReviewScrollAnchor.enhancedTextStart)
                }
                .textSelection(.enabled)
                .padding(12)
            }
            .onAppear {
                // The enhanced result is the review's primary content. Start at
                // its first line while leaving the raw transcript available above.
                DispatchQueue.main.async {
                    proxy.scrollTo(HaloReviewScrollAnchor.enhancedTextStart, anchor: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        }
        .haloReviewInteractiveRegion()
    }

    @ViewBuilder
    private var metadataRow: some View {
        if !metadataChips.isEmpty {
            chipRow
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .frame(height: 21)
        }
    }

    private var chipRow: some View {
        HStack(spacing: 4) {
            ForEach(metadataChips, id: \.self) { label in
                HaloReadOnlyChip(label: label)
            }
        }
        .lineLimit(1)
    }

    private var metadataChips: [String] {
        [
            presentation.metadata.providerLabel,
            presentation.metadata.connectionLabel,
            presentation.metadata.modelLabel,
        ]
        .compactMap(sanitized)
        .filter { !$0.isEmpty }
    }

    private var overrideStatusLabel: String? {
        switch presentation.deliveryOverride {
        case .forceDirect:
            return String(localized: "Quick Apply armed")
        case .forceReview:
            return String(localized: "Review this result")
        case nil:
            return nil
        }
    }

    @ViewBuilder
    private var overrideStatusChip: some View {
        if let overrideStatusLabel {
            HaloOverrideChip(label: overrideStatusLabel)
        }
    }

    @ViewBuilder
    private var destinationLabel: some View {
        let appName = sanitized(presentation.metadata.applicationName)
        let modeName = sanitized(presentation.metadata.modeName)

        VStack(alignment: .trailing, spacing: 1) {
            Text(appName ?? String(localized: "Listening"))
                .font(HaloTypography.destinationTitle)
                .foregroundStyle(Color.white.opacity(0.78))
                .lineLimit(1)
            if let modeName, !modeName.isEmpty {
                Text(modeName)
                    .font(HaloTypography.tertiary)
                    .foregroundStyle(Color.white.opacity(0.44))
                    .lineLimit(1)
            }
        }
    }

    private var reviewDestinationDescription: String {
        let parts = [presentation.metadata.modeName, presentation.metadata.applicationName]
            .compactMap(sanitized)
            .filter { !$0.isEmpty }
        return parts.isEmpty ? String(localized: "Paste Mode") : parts.joined(separator: " · ")
    }

    private var horizontalPadding: CGFloat {
        presentation.phase == .reviewing ? 13 : 12
    }

    private var verticalPadding: CGFloat {
        presentation.phase == .reviewing ? 12 : 8
    }

    private var cornerRadius: CGFloat {
        presentation.phase == .reviewing ? 16 : 20
    }

    private var borderColor: Color {
        presentation.phase == .reviewing
            ? AppTheme.Accent.border.opacity(0.7)
            : Color.white.opacity(0.12)
    }

    private var haloGlow: some View {
        RoundedRectangle(cornerRadius: cornerRadius + 4, style: .continuous)
            .fill(
                RadialGradient(
                    colors: [AppTheme.Accent.primary.opacity(0.20), coral.opacity(0.06), .clear],
                    center: .center,
                    startRadius: 3,
                    endRadius: 170
                )
            )
            .blur(radius: 7)
    }

    private var contentAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.21)
    }

    private var phaseTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98))
    }

    private var liveTranscriptTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    @ViewBuilder
    private func progressIndicator(speed: Double) -> some View {
        if reduceMotion {
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { _ in
                    Circle()
                        .fill(AppTheme.Accent.strong.opacity(0.58))
                        .frame(width: 3, height: 3)
                }
            }
            .accessibilityHidden(true)
        } else {
            ProgressAnimation(color: AppTheme.Accent.strong, animationSpeed: speed)
        }
    }

    private var accessibilityLabel: String {
        switch presentation.phase {
        case .listening:
            return String(localized: "VoiceInk is listening")
        case .transcribing:
            return String(localized: "VoiceInk is transcribing")
        case .enhancing:
            return String(localized: "VoiceInk is enhancing the transcription")
        case .reviewing:
            return String(localized: "Transcript ready. Press Return to apply or Escape to cancel.")
        case .confirmed:
            return String(localized: "Transcript pasted")
        }
    }

    private func feedbackIcon(_ feedback: PasteReviewFeedback) -> String {
        switch feedback {
        case .copied:
            return "checkmark.circle.fill"
        case .copyFailed, .destinationChanged, .pasteFailed, .deliveryUnavailable:
            return "exclamationmark.triangle.fill"
        }
    }

    private func feedbackColor(_ feedback: PasteReviewFeedback) -> Color {
        switch feedback {
        case .copied:
            return AppTheme.Status.positive.opacity(0.95)
        case .copyFailed, .destinationChanged, .pasteFailed, .deliveryUnavailable:
            return AppTheme.Status.warningStrong.opacity(0.95)
        }
    }

    private func sanitized(_ value: String?) -> String? {
        guard let value else { return nil }
        let singleLine = value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        let printable = String(
            singleLine.unicodeScalars.filter { scalar in
                scalar.properties.generalCategory != .control
            }
        )
        let trimmed = printable
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(36))
    }
}

private struct HaloOverrideChip: View {
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "command")
                .font(.system(size: 8, weight: .bold))
            Text(label)
                .lineLimit(1)
        }
        .font(HaloTypography.chip)
        .foregroundStyle(AppTheme.Accent.strong)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(AppTheme.Accent.fill)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .strokeBorder(AppTheme.Accent.border.opacity(0.7), lineWidth: 0.5)
        }
        .accessibilityLabel(Text(label))
    }
}

private struct HaloReadOnlyChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(HaloTypography.chip)
            .foregroundStyle(Color.white.opacity(0.64))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.065))
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
            }
    }
}

private struct HaloReviewActionButton: View {
    let key: String?
    let title: String
    let systemImage: String?
    let emphasized: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let key {
                    Text(key)
                        .font(HaloTypography.key)
                        .foregroundStyle(emphasized ? Color.white.opacity(0.96) : Color.white.opacity(0.62))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(emphasized ? AppTheme.Accent.fillStrong : Color.white.opacity(0.09))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }

                Text(title)
                    .font(HaloTypography.action)
            }
            .foregroundStyle(emphasized ? Color.white.opacity(0.88) : Color.white.opacity(0.62))
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.48 : 1)
        .haloReviewInteractiveRegion()
        .accessibilityLabel(Text(title))
        .accessibilityHint(key.map { Text("Keyboard shortcut: \($0)") } ?? Text(""))
    }
}

private struct HaloLiveTranscriptView: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(text)
                    .font(HaloTypography.liveTranscript)
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .id(HaloLiveTranscriptAnchor.bottom)
            }
            .onAppear {
                proxy.scrollTo(HaloLiveTranscriptAnchor.bottom, anchor: .bottom)
            }
            .onChange(of: text) {
                proxy.scrollTo(HaloLiveTranscriptAnchor.bottom, anchor: .bottom)
            }
        }
        .frame(height: 62)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.055), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .transaction { $0.disablesAnimations = true }
        .accessibilityLabel(Text("Live transcription"))
        .accessibilityValue(Text(text))
    }
}

private enum HaloLiveTranscriptAnchor {
    static let bottom = "halo-live-transcript-bottom"
}

private enum HaloReviewScrollAnchor {
    static let enhancedTextStart = "halo-review-enhanced-text-start"
}

private enum HaloTypography {
    static let liveTranscript = Font.system(size: 13.5, weight: .medium)
    static let statusTitle = Font.system(size: 12, weight: .semibold, design: .rounded)
    static let statusDetail = Font.system(size: 10.5, weight: .medium)
    static let reviewTitle = Font.system(size: 12.5, weight: .semibold, design: .rounded)
    static let reviewDestination = Font.system(size: 10.5, weight: .medium)
    static let reviewRaw = Font.system(size: 11.5, weight: .regular)
    static let reviewFinal = Font.system(size: 14, weight: .medium)
    static let warning = Font.system(size: 10.5, weight: .medium)
    static let destinationTitle = Font.system(size: 10.5, weight: .semibold, design: .rounded)
    static let tertiary = Font.system(size: 9.5, weight: .medium)
    static let chip = Font.system(size: 9.5, weight: .semibold, design: .rounded)
    static let key = Font.system(size: 10, weight: .bold, design: .rounded)
    static let action = Font.system(size: 10.5, weight: .semibold)
}

private enum HaloReviewCoordinateSpace {
    static let name = "halo-review-interaction"
}

private struct HaloReviewInteractiveRegionsKey: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func haloReviewInteractiveRegion() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: HaloReviewInteractiveRegionsKey.self,
                    value: [proxy.frame(in: .named(HaloReviewCoordinateSpace.name))]
                )
            }
        }
    }
}
