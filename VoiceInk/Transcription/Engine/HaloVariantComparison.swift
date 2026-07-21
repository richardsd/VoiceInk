import Foundation

enum HaloVariantSlot: String, CaseIterable, Equatable, Sendable {
    case a
    case b
}

enum HaloVariantProfile: String, CaseIterable, Equatable, Hashable, Sendable {
    case precise
    case natural

    var slot: HaloVariantSlot {
        switch self {
        case .precise: return .a
        case .natural: return .b
        }
    }

    var promptDescriptor: HaloVariantPromptDescriptor {
        switch self {
        case .precise:
            return HaloVariantPromptDescriptor(
                title: "Precise",
                instruction: """
                    Return one complete replacement. Make it concise, exact, structurally clean, and easy to scan. Preserve every fact, name, number, commitment, intent, and original Mode requirement. Do not add commentary, labels, alternatives, or invented information.
                    """
            )
        case .natural:
            return HaloVariantPromptDescriptor(
                title: "Natural",
                instruction: """
                    Return one complete replacement. Make it conversational, fluid, and natural to read while preserving every fact, name, number, commitment, intent, and original Mode requirement. Do not add commentary, labels, alternatives, or invented information.
                    """
            )
        }
    }
}

struct HaloVariantPromptDescriptor: Equatable, Sendable {
    let title: String
    let instruction: String
}

/// Opaque identity for the already-resolved provider, authentication method,
/// model, Mode prompt, vocabulary, and recording context. Both variant requests
/// must carry this exact token; the comparison layer cannot resolve a new route.
struct HaloVariantFrozenRouteToken: Equatable, Hashable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

struct HaloVariantRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let comparisonID: UUID
    let baseRevisionID: UUID
    let profile: HaloVariantProfile
    let routeToken: HaloVariantFrozenRouteToken
    let promptDescriptor: HaloVariantPromptDescriptor
}

struct HaloVariantComparisonLaunch: Equatable, Sendable {
    let comparisonID: UUID
    let baseRevisionID: UUID
    let routeToken: HaloVariantFrozenRouteToken
    let requests: [HaloVariantRequest]
}

enum HaloVariantComparisonStartFailure: Equatable, Sendable {
    case revisionSlotUnavailable
    case comparisonAlreadyActive
}

enum HaloVariantComparisonStartResult: Equatable, Sendable {
    case started(HaloVariantComparisonLaunch)
    case failed(HaloVariantComparisonStartFailure)
}

struct HaloVariantResponse: Equatable, Sendable {
    let comparisonID: UUID
    let requestID: UUID
    let baseRevisionID: UUID
    let routeToken: HaloVariantFrozenRouteToken
    let replacementText: String
}

enum HaloVariantFailure: Equatable, Hashable, Sendable {
    case unavailable
    case authenticationExpired
    case rateLimited
    case timedOut
    case networkUnavailable
    case serverUnavailable
    case malformedResponse
    case cancelled
    case failed
    case emptyResult
    case unchangedResult
}

struct HaloVariantRequestFailure: Equatable, Sendable {
    let requestID: UUID
    let profile: HaloVariantProfile
    let reason: HaloVariantFailure
}

struct HaloVariantCandidate: Identifiable, Equatable, Sendable {
    var id: UUID { requestID }

    let comparisonID: UUID
    let requestID: UUID
    let baseRevisionID: UUID
    let profile: HaloVariantProfile
    let routeToken: HaloVariantFrozenRouteToken
    let replacementText: String
}

enum HaloVariantSlotState: Equatable, Sendable {
    case pending(HaloVariantRequest)
    case candidate(HaloVariantCandidate)
    case failed(HaloVariantRequestFailure)
}

enum HaloVariantComparisonStatus: Equatable, Sendable {
    case idle
    case comparing
    /// At least one profile failed. The other profile may still be pending or
    /// may have produced the only selectable candidate.
    case partialFailure
    case ready
    case totalFailure
    case cancelled
    case materialized
}

enum HaloVariantEventResult: Equatable, Sendable {
    case candidateAccepted(HaloVariantProfile)
    case failureAccepted(HaloVariantProfile)
    case invalidResult(HaloVariantFailure)
    case stale
}

enum HaloVariantCancellationResult: Equatable, Sendable {
    case cancelled(pendingRequestIDs: [UUID])
    case stale
}

struct HaloVariantMaterialization: Equatable, Sendable {
    let comparisonID: UUID
    let baseRevisionID: UUID
    let profile: HaloVariantProfile
    let routeToken: HaloVariantFrozenRouteToken
    let replacementText: String
}

enum HaloVariantWinnerSelectionResult: Equatable, Sendable {
    case materialized(HaloVariantMaterialization)
    case candidateUnavailable
    case stale
}

/// Pure state for a two-profile comparison. Provider tasks live outside this
/// type; callers feed sanitized successes and failures back through request IDs.
struct HaloVariantComparisonState: Equatable, Sendable {
    private(set) var status: HaloVariantComparisonStatus = .idle
    private(set) var comparisonID: UUID?
    private(set) var baseRevisionID: UUID?
    private(set) var routeToken: HaloVariantFrozenRouteToken?
    private(set) var materializedWinner: HaloVariantMaterialization?

    private var baseText: String?
    private var slots: [HaloVariantProfile: HaloVariantSlotState] = [:]

    init() {}

    var provisionalCandidates: [HaloVariantCandidate] {
        HaloVariantProfile.allCases.compactMap { profile in
            guard case .candidate(let candidate) = slots[profile] else { return nil }
            return candidate
        }
    }

    var failures: [HaloVariantRequestFailure] {
        HaloVariantProfile.allCases.compactMap { profile in
            guard case .failed(let failure) = slots[profile] else { return nil }
            return failure
        }
    }

    var pendingRequests: [HaloVariantRequest] {
        HaloVariantProfile.allCases.compactMap { profile in
            guard case .pending(let request) = slots[profile] else { return nil }
            return request
        }
    }

    func slotState(for profile: HaloVariantProfile) -> HaloVariantSlotState? {
        slots[profile]
    }

    @discardableResult
    mutating func begin(
        baseRevisionID: UUID,
        baseText: String,
        routeToken: HaloVariantFrozenRouteToken,
        remainingRevisionSlots: Int,
        comparisonID: UUID = UUID()
    ) -> HaloVariantComparisonStartResult {
        guard remainingRevisionSlots > 0 else {
            return .failed(.revisionSlotUnavailable)
        }
        guard permitsNewComparison else {
            return .failed(.comparisonAlreadyActive)
        }

        let requests = HaloVariantProfile.allCases.map { profile in
            HaloVariantRequest(
                id: UUID(),
                comparisonID: comparisonID,
                baseRevisionID: baseRevisionID,
                profile: profile,
                routeToken: routeToken,
                promptDescriptor: profile.promptDescriptor
            )
        }

        self.comparisonID = comparisonID
        self.baseRevisionID = baseRevisionID
        self.baseText = baseText
        self.routeToken = routeToken
        materializedWinner = nil
        slots = Dictionary(
            uniqueKeysWithValues: requests.map { ($0.profile, .pending($0)) }
        )
        status = .comparing

        return .started(
            HaloVariantComparisonLaunch(
                comparisonID: comparisonID,
                baseRevisionID: baseRevisionID,
                routeToken: routeToken,
                requests: requests
            )
        )
    }

    @discardableResult
    mutating func receive(_ response: HaloVariantResponse) -> HaloVariantEventResult {
        guard let (profile, request) = pendingRequest(
            comparisonID: response.comparisonID,
            requestID: response.requestID,
            baseRevisionID: response.baseRevisionID,
            routeToken: response.routeToken
        ), let baseText else {
            return .stale
        }

        let replacement = response.replacementText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty else {
            setFailure(.emptyResult, for: profile, request: request)
            return .invalidResult(.emptyResult)
        }
        guard replacement != baseText.trimmingCharacters(in: .whitespacesAndNewlines) else {
            setFailure(.unchangedResult, for: profile, request: request)
            return .invalidResult(.unchangedResult)
        }

        slots[profile] = .candidate(
            HaloVariantCandidate(
                comparisonID: request.comparisonID,
                requestID: request.id,
                baseRevisionID: request.baseRevisionID,
                profile: request.profile,
                routeToken: request.routeToken,
                replacementText: replacement
            )
        )
        refreshStatus()
        return .candidateAccepted(profile)
    }

    @discardableResult
    mutating func receiveFailure(
        comparisonID: UUID,
        requestID: UUID,
        baseRevisionID: UUID,
        routeToken: HaloVariantFrozenRouteToken,
        failure: HaloVariantFailure
    ) -> HaloVariantEventResult {
        guard let (profile, request) = pendingRequest(
            comparisonID: comparisonID,
            requestID: requestID,
            baseRevisionID: baseRevisionID,
            routeToken: routeToken
        ) else {
            return .stale
        }

        setFailure(failure, for: profile, request: request)
        return .failureAccepted(profile)
    }

    @discardableResult
    mutating func cancel(comparisonID: UUID) -> HaloVariantCancellationResult {
        guard self.comparisonID == comparisonID,
            status == .comparing || status == .partialFailure || status == .ready
                || status == .totalFailure
        else {
            return .stale
        }

        let pendingRequestIDs = pendingRequests.map(\.id)
        clearProvisionalState()
        status = .cancelled
        return .cancelled(pendingRequestIDs: pendingRequestIDs)
    }

    @discardableResult
    mutating func selectWinner(
        profile: HaloVariantProfile,
        comparisonID: UUID
    ) -> HaloVariantWinnerSelectionResult {
        guard self.comparisonID == comparisonID else { return .stale }
        guard pendingRequests.isEmpty,
            status == .ready || status == .partialFailure
        else {
            return .candidateUnavailable
        }
        guard case .candidate(let winner) = slots[profile] else {
            return .candidateUnavailable
        }

        let materialization = HaloVariantMaterialization(
            comparisonID: winner.comparisonID,
            baseRevisionID: winner.baseRevisionID,
            profile: winner.profile,
            routeToken: winner.routeToken,
            replacementText: winner.replacementText
        )
        clearProvisionalState()
        materializedWinner = materialization
        status = .materialized
        return .materialized(materialization)
    }

    private var permitsNewComparison: Bool {
        switch status {
        case .idle, .cancelled, .totalFailure:
            return true
        case .comparing, .partialFailure, .ready, .materialized:
            return false
        }
    }

    private func pendingRequest(
        comparisonID: UUID,
        requestID: UUID,
        baseRevisionID: UUID,
        routeToken: HaloVariantFrozenRouteToken
    ) -> (HaloVariantProfile, HaloVariantRequest)? {
        guard self.comparisonID == comparisonID,
            self.baseRevisionID == baseRevisionID,
            self.routeToken == routeToken
        else {
            return nil
        }

        for profile in HaloVariantProfile.allCases {
            guard case .pending(let request) = slots[profile],
                request.id == requestID,
                request.comparisonID == comparisonID,
                request.baseRevisionID == baseRevisionID,
                request.routeToken == routeToken
            else {
                continue
            }
            return (profile, request)
        }
        return nil
    }

    private mutating func setFailure(
        _ failure: HaloVariantFailure,
        for profile: HaloVariantProfile,
        request: HaloVariantRequest
    ) {
        slots[profile] = .failed(
            HaloVariantRequestFailure(
                requestID: request.id,
                profile: profile,
                reason: failure
            )
        )
        refreshStatus()
    }

    private mutating func refreshStatus() {
        let pendingCount = pendingRequests.count
        let candidateCount = provisionalCandidates.count
        let failureCount = failures.count

        if pendingCount > 0 {
            status = failureCount > 0 ? .partialFailure : .comparing
        } else if candidateCount == HaloVariantProfile.allCases.count {
            status = .ready
        } else if candidateCount == 1 && failureCount == 1 {
            status = .partialFailure
        } else {
            status = .totalFailure
        }
    }

    private mutating func clearProvisionalState() {
        slots.removeAll(keepingCapacity: false)
        baseText = nil
    }
}
