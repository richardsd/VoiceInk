import Foundation

enum HaloVariantDeckPolicy {
    static let requestCount = HaloVariantProfile.allCases.count

    static var compareActionTitle: String {
        String(
            format: String(localized: "Compare · %d requests"),
            requestCount
        )
    }

    static var compareActionHint: String {
        String(
            localized: "Creates two alternatives concurrently using this review’s current provider, connection, and model."
        )
    }
}

enum HaloVariantDeckViewportPhase: Hashable, Sendable {
    case loading
    case success
    case failure
}

struct HaloVariantDeckViewportIdentity: Equatable, Hashable, Sendable {
    let comparisonID: UUID
    let requestID: UUID
    let profile: HaloVariantProfile
    let phase: HaloVariantDeckViewportPhase
}

enum HaloVariantDeckCandidatePhase: Equatable, Sendable {
    case loading
    case success(text: String)
    case failure(HaloVariantFailure)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var shortStatus: String {
        switch self {
        case .loading:
            return String(localized: "Generating")
        case .success:
            return String(localized: "Ready")
        case .failure:
            return String(localized: "Unavailable")
        }
    }

    var detail: String {
        switch self {
        case .loading:
            return String(localized: "Creating this alternative…")
        case .success(let text):
            return text
        case .failure(let failure):
            return failure.sanitizedVariantDeckMessage
        }
    }
}

struct HaloVariantDeckCandidatePresentation: Identifiable, Equatable, Sendable {
    var id: HaloVariantProfile { profile }

    let comparisonID: UUID
    let requestID: UUID
    let slot: HaloVariantSlot
    let profile: HaloVariantProfile
    let title: String
    let phase: HaloVariantDeckCandidatePhase
    let isSelected: Bool

    var viewportIdentity: HaloVariantDeckViewportIdentity {
        let viewportPhase: HaloVariantDeckViewportPhase
        switch phase {
        case .loading: viewportPhase = .loading
        case .success: viewportPhase = .success
        case .failure: viewportPhase = .failure
        }
        return HaloVariantDeckViewportIdentity(
            comparisonID: comparisonID,
            requestID: requestID,
            profile: profile,
            phase: viewportPhase
        )
    }

    var accessibilityLabel: String {
        String(
            format: String(localized: "Variant %@, %@"),
            slot.rawValue.uppercased(),
            title
        )
    }

    var accessibilityValue: String {
        isSelected
            ? String(
                format: String(localized: "Selected, %@"),
                phase.shortStatus
            )
            : phase.shortStatus
    }

    var accessibilityHint: String {
        String(
            format: String(localized: "Shows the %@ transcript alternative."),
            title
        )
    }
}

struct HaloVariantDeckPresentation: Equatable, Sendable {
    let comparisonID: UUID
    let candidates: [HaloVariantDeckCandidatePresentation]
    let selectedProfile: HaloVariantProfile
    let isSettled: Bool
    let isCancelling: Bool
    let statusText: String

    var selectedCandidate: HaloVariantDeckCandidatePresentation? {
        candidates.first { $0.profile == selectedProfile }
    }

    var interactionsAreEnabled: Bool { !isCancelling }

    var canChooseSelectedCandidate: Bool {
        interactionsAreEnabled
            && isSettled
            && selectedCandidate?.phase.isSuccess == true
    }

    var headerTitle: String {
        guard isSettled else {
            return String(localized: "Comparing alternatives…")
        }
        if candidates.contains(where: { $0.phase.isSuccess }) {
            return String(localized: "Choose an alternative")
        }
        return String(localized: "Alternatives unavailable")
    }
}

enum HaloVariantDeckProjection {
    static func make(
        from state: HaloVariantComparisonState,
        selectedProfile requestedProfile: HaloVariantProfile = .precise,
        isCancelling: Bool = false
    ) -> HaloVariantDeckPresentation? {
        guard let comparisonID = state.comparisonID else { return nil }
        guard state.status != .idle,
            state.status != .cancelled,
            state.status != .materialized
        else {
            return nil
        }

        let phasePairs: [(HaloVariantProfile, UUID, HaloVariantDeckCandidatePhase)] =
            HaloVariantProfile.allCases.compactMap { profile
                -> (HaloVariantProfile, UUID, HaloVariantDeckCandidatePhase)? in
                guard let slot = state.slotState(for: profile) else { return nil }
                let requestID: UUID
                let phase: HaloVariantDeckCandidatePhase
                switch slot {
                case .pending(let request):
                    requestID = request.id
                    phase = .loading
                case .candidate(let candidate):
                    requestID = candidate.requestID
                    phase = .success(text: candidate.replacementText)
                case .failed(let failure):
                    requestID = failure.requestID
                    phase = .failure(failure.reason)
                }
                return (profile, requestID, phase)
            }
        let phases: [HaloVariantProfile: HaloVariantDeckCandidatePhase] = Dictionary(
            uniqueKeysWithValues: phasePairs.map { ($0.0, $0.2) }
        )
        let requestIDs: [HaloVariantProfile: UUID] = Dictionary(
            uniqueKeysWithValues: phasePairs.map { ($0.0, $0.1) }
        )
        guard !phases.isEmpty else { return nil }

        let isSettled = state.pendingRequests.isEmpty
        let selectedProfile = resolvedSelection(
            requestedProfile,
            phases: phases,
            isSettled: isSettled
        )
        let candidates: [HaloVariantDeckCandidatePresentation] =
            HaloVariantProfile.allCases.compactMap { profile
                -> HaloVariantDeckCandidatePresentation? in
            guard let phase = phases[profile], let requestID = requestIDs[profile] else {
                return nil
            }
            return HaloVariantDeckCandidatePresentation(
                comparisonID: comparisonID,
                requestID: requestID,
                slot: profile.slot,
                profile: profile,
                title: profile.variantDeckTitle,
                phase: phase,
                isSelected: profile == selectedProfile
            )
        }

        return HaloVariantDeckPresentation(
            comparisonID: comparisonID,
            candidates: candidates,
            selectedProfile: selectedProfile,
            isSettled: isSettled,
            isCancelling: isCancelling,
            statusText: statusText(
                for: state.status,
                isSettled: isSettled,
                isCancelling: isCancelling
            )
        )
    }

    private static func resolvedSelection(
        _ requestedProfile: HaloVariantProfile,
        phases: [HaloVariantProfile: HaloVariantDeckCandidatePhase],
        isSettled: Bool
    ) -> HaloVariantProfile {
        guard isSettled,
            phases[requestedProfile]?.isSuccess != true,
            let onlySuccess = HaloVariantProfile.allCases.first(where: {
                phases[$0]?.isSuccess == true
            })
        else {
            return phases[requestedProfile] == nil
                ? (HaloVariantProfile.allCases.first(where: { phases[$0] != nil }) ?? .precise)
                : requestedProfile
        }
        return onlySuccess
    }

    private static func statusText(
        for status: HaloVariantComparisonStatus,
        isSettled: Bool,
        isCancelling: Bool
    ) -> String {
        if isCancelling {
            return String(localized: "Cancelling comparison…")
        }
        switch status {
        case .comparing:
            return String(localized: "Creating two alternatives…")
        case .partialFailure:
            return isSettled
                ? String(localized: "One alternative is ready")
                : String(localized: "Waiting for the remaining alternative…")
        case .ready:
            return String(localized: "Choose the version you prefer")
        case .totalFailure:
            return String(localized: "Alternatives could not be created")
        case .idle, .cancelled, .materialized:
            return ""
        }
    }
}

private extension HaloVariantProfile {
    var variantDeckTitle: String {
        switch self {
        case .precise: return String(localized: "Precise")
        case .natural: return String(localized: "Natural")
        }
    }
}

private extension HaloVariantFailure {
    var sanitizedVariantDeckMessage: String {
        switch self {
        case .unavailable:
            return String(localized: "This alternative is not available.")
        case .authenticationExpired:
            return String(localized: "The refinement connection expired.")
        case .rateLimited:
            return String(localized: "The refinement service is busy.")
        case .timedOut:
            return String(localized: "This alternative timed out.")
        case .networkUnavailable:
            return String(localized: "The network is unavailable.")
        case .serverUnavailable:
            return String(localized: "The refinement service is temporarily unavailable.")
        case .malformedResponse:
            return String(localized: "This alternative returned an invalid response.")
        case .cancelled:
            return String(localized: "This alternative was cancelled.")
        case .failed:
            return String(localized: "This alternative could not be created.")
        case .emptyResult:
            return String(localized: "This alternative returned no usable text.")
        case .unchangedResult:
            return String(localized: "This alternative did not meaningfully change the text.")
        }
    }
}
