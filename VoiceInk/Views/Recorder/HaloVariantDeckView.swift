import SwiftUI

/// Compact A/B transcript comparison. The view emits intent only; the owner is
/// responsible for selecting a winner through `HaloVariantComparisonState` and
/// materializing the resulting revision.
struct HaloVariantDeckView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let presentation: HaloVariantDeckPresentation
    let onSelectProfile: (HaloVariantProfile) -> Void
    let onChooseWinner: (HaloVariantProfile) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            variantSelector
            selectedCandidateBody
            footer
        }
        .padding(9)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Transcript alternatives, Precise and Natural"))
        .accessibilityHint(
            Text("Compare one alternative at a time, then choose a winner after both finish.")
        )
    }

    private var variantSelector: some View {
        HStack(spacing: 3) {
            ForEach(presentation.candidates) { candidate in
                Button {
                    onSelectProfile(candidate.profile)
                } label: {
                    HStack(spacing: 5) {
                        Text(candidate.slot.rawValue.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                candidate.isSelected
                                    ? Color.white.opacity(0.82)
                                    : Color.white.opacity(0.38)
                            )

                        Text(candidate.title)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .lineLimit(1)

                        candidateStatusIcon(candidate.phase)
                    }
                    .foregroundStyle(
                        candidate.isSelected
                            ? Color.white.opacity(0.94)
                            : Color.white.opacity(0.54)
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .background(
                        candidate.isSelected
                            ? HaloVariantDeckPalette.selectionFill
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!presentation.interactionsAreEnabled)
                .opacity(presentation.interactionsAreEnabled ? 1 : 0.48)
                .accessibilityLabel(Text(candidate.accessibilityLabel))
                .accessibilityValue(Text(candidate.accessibilityValue))
                .accessibilityHint(Text(candidate.accessibilityHint))
                .accessibilityAddTraits(candidate.isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private var selectedCandidateBody: some View {
        if let candidate = presentation.selectedCandidate {
            Group {
                switch candidate.phase {
                case .loading:
                    HStack(spacing: 8) {
                        variantProgressIndicator(compact: false)
                        Text(candidate.phase.detail)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.58))
                        Spacer(minLength: 0)
                    }

                case .success(let text):
                    candidateViewport(text: text, candidate: candidate)

                case .failure:
                    Label(candidate.phase.detail, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(HaloVariantDeckPalette.warning)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 88, alignment: .topLeading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .allowsHitTesting(presentation.interactionsAreEnabled)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(candidate.accessibilityLabel))
        }
    }

    private func candidateViewport(
        text: String,
        candidate: HaloVariantDeckCandidatePresentation
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id(candidate.viewportIdentity)
                        .accessibilityHidden(true)
                    Text(text)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .textSelection(.enabled)
                        .accessibilityLabel(
                            Text("\(candidate.title) transcript alternative")
                        )
                }
            }
            .onAppear {
                scrollCandidateToStart(proxy, identity: candidate.viewportIdentity)
            }
            .onChange(of: candidate.viewportIdentity) {
                scrollCandidateToStart(proxy, identity: candidate.viewportIdentity)
            }
        }
    }

    private func scrollCandidateToStart(
        _ proxy: ScrollViewProxy,
        identity: HaloVariantDeckViewportIdentity
    ) {
        DispatchQueue.main.async {
            proxy.scrollTo(identity, anchor: .top)
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Text(presentation.statusText)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button(action: onCancel) {
                Text(presentation.isCancelling ? "Cancelling…" : "Cancel")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!presentation.interactionsAreEnabled)
            .accessibilityLabel(Text("Cancel comparison"))
            .accessibilityHint(Text("Keeps the current transcript version unchanged."))

            if let selectedCandidate = presentation.selectedCandidate {
                Button {
                    onChooseWinner(selectedCandidate.profile)
                } label: {
                    Text("Use \(selectedCandidate.title)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(HaloVariantDeckPalette.selectionFill)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!presentation.canChooseSelectedCandidate)
                .opacity(presentation.canChooseSelectedCandidate ? 1 : 0.4)
                .accessibilityLabel(Text("Use \(selectedCandidate.title) variant"))
                .accessibilityHint(
                    Text("Selects this result and discards the other provisional alternative.")
                )
            }
        }
    }
}

private enum HaloVariantDeckPalette {
    static let activity = Color(red: 0.37, green: 0.70, blue: 1.0)
    static let selectionFill = activity.opacity(0.22)
    static let warning = Color(red: 0.96, green: 0.58, blue: 0.34).opacity(0.92)
}

private extension HaloVariantDeckView {
    @ViewBuilder
    func candidateStatusIcon(_ phase: HaloVariantDeckCandidatePhase) -> some View {
        switch phase {
        case .loading:
            variantProgressIndicator(compact: true)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(HaloVariantDeckPalette.activity)
                .accessibilityHidden(true)
        case .failure:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(HaloVariantDeckPalette.warning)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    func variantProgressIndicator(compact: Bool) -> some View {
        if reduceMotion {
            HStack(spacing: compact ? 1 : 2) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(HaloVariantDeckPalette.activity.opacity(0.72))
                        .frame(width: compact ? 2 : 3, height: compact ? 2 : 3)
                }
            }
            .frame(width: compact ? 10 : nil, height: compact ? 10 : nil)
            .accessibilityHidden(true)
        } else {
            ProgressView()
                .controlSize(compact ? .mini : .small)
                .tint(HaloVariantDeckPalette.activity)
                .frame(width: compact ? 10 : nil, height: compact ? 10 : nil)
                .accessibilityHidden(true)
        }
    }
}
