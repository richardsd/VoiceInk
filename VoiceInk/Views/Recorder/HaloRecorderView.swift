import SwiftUI

enum HaloRefinementOrbitPolicy {
    static let actionSpacing: CGFloat = 5
    static let rowHeight: CGFloat = 28

    static let actions: [HaloRefinementAction] = [
        .shorter,
        .clearer,
        .friendlier,
        .formal,
        .fixTerms,
    ]

    static func actionsAreEnabled(
        canRefine: Bool,
        isRefining: Bool,
        isDelivering: Bool
    ) -> Bool {
        canRefine && !isRefining && !isDelivering
    }

    static func contentWidth(for actionWidths: [CGFloat]) -> CGFloat {
        guard !actionWidths.isEmpty else { return 0 }
        return actionWidths.reduce(0, +)
            + CGFloat(actionWidths.count - 1) * actionSpacing
    }

    static func requiresHorizontalScrolling(
        actionWidths: [CGFloat],
        availableWidth: CGFloat
    ) -> Bool {
        contentWidth(for: actionWidths) > max(0, availableWidth)
    }
}

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
    let onSelectReviewLens: (HaloReviewLens) -> Void
    let onMoveReviewRevision: (Int) -> Void
    let onRefine: (HaloRefinementAction) -> Void
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
        onSelectReviewLens: @escaping (HaloReviewLens) -> Void,
        onMoveReviewRevision: @escaping (Int) -> Void,
        onRefine: @escaping (HaloRefinementAction) -> Void,
        onReviewInteractiveRegionsChange: @escaping ([CGRect]) -> Void
    ) {
        self.stateProvider = stateProvider
        self.recorder = recorder
        self.presentation = presentation
        self.onApply = onApply
        self.onCancel = onCancel
        self.onCopy = onCopy
        self.onRetry = onRetry
        self.onSelectReviewLens = onSelectReviewLens
        self.onMoveReviewRevision = onMoveReviewRevision
        self.onRefine = onRefine
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
                reviewNavigation
                reviewTextViewport(review)
                refinementOrbit

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
                    isDisabled: presentation.isReviewDelivering || presentation.isRefining,
                    action: showsRetry ? onRetry : onApply
                )
                HaloReviewActionButton(
                    key: presentation.isRefining ? nil : "Esc",
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
                    isDisabled: presentation.isReviewDelivering || presentation.isRefining,
                    action: onCopy
                )
                Spacer(minLength: 0)
                Text("Saved to History")
                    .font(HaloTypography.tertiary)
                    .foregroundStyle(Color.white.opacity(0.38))
            }
        }
    }

    private var reviewNavigation: some View {
        HStack(spacing: 8) {
            HaloReviewLensSelector(
                selection: presentation.reviewLens,
                onSelect: onSelectReviewLens
            )

            Spacer(minLength: 4)

            if presentation.revisionCount > 0 {
                HaloReviewRevisionNavigator(
                    index: presentation.selectedRevisionIndex,
                    count: presentation.revisionCount,
                    canMovePrevious: presentation.canMovePrevious,
                    canMoveNext: presentation.canMoveNext,
                    isDisabled: presentation.isReviewDelivering || presentation.isRefining,
                    onMove: onMoveReviewRevision
                )
            }
        }
    }

    private var refinementOrbit: some View {
        HaloRefinementOrbit(
            actions: HaloRefinementOrbitPolicy.actions,
            activeAction: presentation.activeRefinementAction,
            actionsAreEnabled: HaloRefinementOrbitPolicy.actionsAreEnabled(
                canRefine: presentation.canRefine,
                isRefining: presentation.isRefining,
                isDelivering: presentation.isReviewDelivering
            ),
            hasReachedRevisionLimit: presentation.hasReachedRevisionLimit,
            onSelect: onRefine
        )
    }

    @ViewBuilder
    private var reviewStatusRows: some View {
        if presentation.isRefining, let activeAction = presentation.activeRefinementAction {
            HaloRefinementProgressStatus(action: activeAction)
        } else {
            if let notice = presentation.reviewNoticeMessage {
                Label(notice, systemImage: reviewNoticeIcon)
                    .font(HaloTypography.warning)
                    .foregroundStyle(reviewNoticeColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let feedback = presentation.reviewFeedback {
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
    }

    private func reviewTextViewport(_ review: HaloReviewPresentation) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                reviewLensContent(review)
                    .id(HaloReviewScrollAnchor.viewportStart)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .onAppear {
                scrollReviewToStart(proxy)
            }
            .onChange(of: presentation.reviewViewportIdentity) {
                scrollReviewToStart(proxy)
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
    private func reviewLensContent(_ review: HaloReviewPresentation) -> some View {
        switch presentation.reviewLens {
        case .final:
            Text(selectedRevisionText(fallback: review))
                .font(HaloTypography.reviewFinal)
                .foregroundStyle(Color.white.opacity(0.94))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityLabel(Text("Final transcript"))
                .accessibilityValue(Text(selectedRevisionText(fallback: review)))

        case .changes:
            if presentation.isComputingDiff {
                HaloReviewDiffProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else if let result = presentation.diffResult {
                HaloReviewRedlineView(result: result)
            } else {
                Text("No changes to show")
                    .font(HaloTypography.reviewRaw)
                    .foregroundStyle(Color.white.opacity(0.54))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

        case .original:
            Text(originalText(fallback: review))
                .font(HaloTypography.reviewRaw)
                .foregroundStyle(Color.white.opacity(0.72))
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityLabel(Text("Original transcript"))
                .accessibilityValue(Text(originalText(fallback: review)))
        }
    }

    private func scrollReviewToStart(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(HaloReviewScrollAnchor.viewportStart, anchor: .top)
        }
    }

    private func selectedRevisionText(fallback review: HaloReviewPresentation) -> String {
        presentation.revisionCount > 0 ? presentation.selectedRevisionText : review.finalText
    }

    private func originalText(fallback review: HaloReviewPresentation) -> String {
        presentation.originalText.isEmpty ? review.rawText : presentation.originalText
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

    private var reviewNoticeIcon: String {
        presentation.reviewNoticeTone == .warning
            ? "exclamationmark.triangle.fill"
            : "info.circle.fill"
    }

    private var reviewNoticeColor: Color {
        presentation.reviewNoticeTone == .warning
            ? AppTheme.Status.warningStrong.opacity(0.95)
            : AppTheme.Accent.strong.opacity(0.92)
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
        .haloReviewInteractiveRegion(enabled: !isDisabled)
        .accessibilityLabel(Text(title))
        .accessibilityHint(key.map { Text("Keyboard shortcut: \($0)") } ?? Text(""))
    }
}

private struct HaloRefinementOrbit: View {
    let actions: [HaloRefinementAction]
    let activeAction: HaloRefinementAction?
    let actionsAreEnabled: Bool
    let hasReachedRevisionLimit: Bool
    let onSelect: (HaloRefinementAction) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HaloRefinementOrbitPolicy.actionSpacing) {
                ForEach(actions) { action in
                    HaloRefinementActionButton(
                        action: action,
                        isActive: action == activeAction,
                        isDisabled: !actionsAreEnabled,
                        hasReachedRevisionLimit: hasReachedRevisionLimit,
                        onSelect: onSelect
                    )
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(height: HaloRefinementOrbitPolicy.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Refinement actions"))
    }
}

private struct HaloRefinementActionButton: View {
    let action: HaloRefinementAction
    let isActive: Bool
    let isDisabled: Bool
    let hasReachedRevisionLimit: Bool
    let onSelect: (HaloRefinementAction) -> Void

    var body: some View {
        Button {
            onSelect(action)
        } label: {
            HStack(spacing: 4) {
                if isActive {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppTheme.Accent.strong)
                        .scaleEffect(0.7)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 8, weight: .semibold))
                }

                Text(action.displayName)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(HaloTypography.refinementAction)
            .foregroundStyle(
                isActive
                    ? AppTheme.Accent.strong
                    : Color.white.opacity(0.68)
            )
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                isActive
                    ? AppTheme.Accent.fillStrong
                    : Color.white.opacity(0.055)
            )
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(
                        isActive
                            ? AppTheme.Accent.border.opacity(0.8)
                            : Color.white.opacity(0.07),
                        lineWidth: 0.5
                    )
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled && !isActive ? 0.43 : 1)
        .haloReviewInteractiveRegion(enabled: !isDisabled)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(accessibilityHint))
    }

    private var accessibilityLabel: String {
        let format = isActive
            ? String(localized: "Refinement in progress: %@")
            : String(localized: "Refine transcript: %@")
        return String(format: format, action.displayName)
    }

    private var accessibilityHint: String {
        if hasReachedRevisionLimit {
            return String(localized: "This review already has six versions.")
        }
        if isActive {
            return String(localized: "Press Escape to stop refinement.")
        }
        return String(localized: "Creates a complete replacement version")
    }
}

private struct HaloRefinementProgressStatus: View {
    let action: HaloRefinementAction

    var body: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .tint(AppTheme.Accent.strong)

            Text(
                String(
                    format: String(localized: "Refining: %@"),
                    action.displayName
                )
            )
            .font(HaloTypography.warning)
            .foregroundStyle(AppTheme.Accent.strong.opacity(0.95))

            Spacer(minLength: 8)

            Text("Press Escape to stop refinement.")
                .font(HaloTypography.tertiary)
                .foregroundStyle(Color.white.opacity(0.48))
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                String(
                    format: String(localized: "Refinement in progress: %@"),
                    action.displayName
                )
            )
        )
        .accessibilityHint(Text("Press Escape to stop refinement."))
    }
}

private struct HaloReviewLensSelector: View {
    let selection: HaloReviewLens
    let onSelect: (HaloReviewLens) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HaloReviewLens.allCases) { lens in
                let isSelected = lens == selection

                Button {
                    onSelect(lens)
                } label: {
                    HStack(spacing: 5) {
                        Text(lens.displayName)
                            .font(HaloTypography.action)
                        Text(shortcut(for: lens))
                            .font(HaloTypography.tertiary)
                            .foregroundStyle(
                                isSelected
                                    ? Color.white.opacity(0.62)
                                    : Color.white.opacity(0.34)
                            )
                    }
                    .foregroundStyle(
                        isSelected
                            ? Color.white.opacity(0.94)
                            : Color.white.opacity(0.54)
                    )
                    .frame(minWidth: 70)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(isSelected ? AppTheme.Accent.fillStrong : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(lens.displayName))
                .accessibilityValue(Text(isSelected ? "Selected" : ""))
                .accessibilityHint(Text("Keyboard shortcut: \(shortcut(for: lens))"))
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.065), lineWidth: 0.5)
        }
        .haloReviewInteractiveRegion()
    }

    private func shortcut(for lens: HaloReviewLens) -> String {
        switch lens {
        case .final:
            return "⌘1"
        case .changes:
            return "⌘2"
        case .original:
            return "⌘3"
        }
    }
}

private struct HaloReviewRevisionNavigator: View {
    let index: Int
    let count: Int
    let canMovePrevious: Bool
    let canMoveNext: Bool
    let isDisabled: Bool
    let onMove: (Int) -> Void

    var body: some View {
        HStack(spacing: 5) {
            navigationButton(
                systemImage: "chevron.left",
                shortcut: "⌘[",
                direction: -1,
                isAvailable: canMovePrevious
            )

            Text("\(index + 1) of \(count)")
                .font(HaloTypography.tertiary)
                .foregroundStyle(Color.white.opacity(0.48))
                .monospacedDigit()
                .frame(minWidth: 40)
                .accessibilityLabel(Text("Version \(index + 1) of \(count)"))

            navigationButton(
                systemImage: "chevron.right",
                shortcut: "⌘]",
                direction: 1,
                isAvailable: canMoveNext
            )
        }
        .haloReviewInteractiveRegion(
            enabled: !isDisabled && (canMovePrevious || canMoveNext)
        )
    }

    private func navigationButton(
        systemImage: String,
        shortcut: String,
        direction: Int,
        isAvailable: Bool
    ) -> some View {
        Button {
            onMove(direction)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.62))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.065))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || !isAvailable)
        .opacity(isDisabled || !isAvailable ? 0.35 : 1)
        .accessibilityLabel(Text(direction < 0 ? "Previous version" : "Next version"))
        .accessibilityHint(Text("Keyboard shortcut: \(shortcut)"))
    }
}

private struct HaloReviewDiffProgressView: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(AppTheme.Accent.strong)
            Text("Comparing changes")
                .font(HaloTypography.reviewDestination)
                .foregroundStyle(Color.white.opacity(0.54))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Comparing transcript changes"))
    }
}

private struct HaloReviewRedlineView: View {
    let result: HaloReviewDiffResult

    var body: some View {
        Text(attributedText)
            .font(HaloTypography.reviewFinal)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilityDescription))
            .accessibilityValue(Text(result.revisedText))
    }

    private var attributedText: AttributedString {
        var output = AttributedString()

        for group in result.groups {
            for segment in group.segments {
                var run = AttributedString(segment.text)

                switch segment.operation {
                case .unchanged:
                    run.foregroundColor = Color.white.opacity(0.90)
                case .addition:
                    run.foregroundColor = Color(red: 0.37, green: 0.70, blue: 1.0)
                    run.backgroundColor = AppTheme.Accent.fill.opacity(0.34)
                case .removal:
                    let removalColor = Color(red: 0.96, green: 0.42, blue: 0.37)
                    run.foregroundColor = removalColor.opacity(0.76)
                    run.backgroundColor = removalColor.opacity(0.075)
                    run.strikethroughStyle = .single
                }

                output.append(run)
            }
        }

        return output
    }

    private var accessibilityDescription: String {
        let descriptions = result.groups
            .map(\.accessibilityLabel)
            .filter { !$0.isEmpty }
        return descriptions.isEmpty
            ? String(localized: "No changes")
            : descriptions.joined(separator: ". ")
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
    static let viewportStart = "halo-review-viewport-start"
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
    static let refinementAction = Font.system(size: 9.5, weight: .semibold, design: .rounded)
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
    func haloReviewInteractiveRegion(enabled: Bool = true) -> some View {
        background {
            if enabled {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: HaloReviewInteractiveRegionsKey.self,
                        value: [proxy.frame(in: .named(HaloReviewCoordinateSpace.name))]
                    )
                }
            }
        }
    }
}
