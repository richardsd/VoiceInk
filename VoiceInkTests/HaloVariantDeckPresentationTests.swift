import Foundation
import Testing
@testable import VoiceInk

struct HaloVariantDeckPresentationTests {
    @Test func runningComparisonProjectsTwoLoadingABTabsWithoutWinner() throws {
        var state = HaloVariantComparisonState()
        _ = try beginComparison(state: &state)

        let presentation = try requirePresentation(state)

        #expect(presentation.candidates.count == 2)
        #expect(presentation.candidates.map(\.slot) == [.a, .b])
        #expect(presentation.candidates.map(\.title) == ["Precise", "Natural"])
        #expect(presentation.candidates.allSatisfy { $0.phase == .loading })
        #expect(presentation.selectedProfile == .precise)
        #expect(!presentation.isSettled)
        #expect(!presentation.canChooseSelectedCandidate)
        #expect(presentation.headerTitle == "Comparing alternatives…")
    }

    @Test func oneEarlySuccessRemainsUnselectableUntilOtherRequestSettles() throws {
        var state = HaloVariantComparisonState()
        let launch = try beginComparison(state: &state)
        let precise = try request(.precise, in: launch)
        _ = state.receive(response(for: precise, text: "Precise result"))

        let presentation = try requirePresentation(state)

        #expect(presentation.selectedCandidate?.phase == .success(text: "Precise result"))
        #expect(!presentation.isSettled)
        #expect(!presentation.canChooseSelectedCandidate)
    }

    @Test func settledPartialFailureSelectsTheSurvivingCandidate() throws {
        var state = HaloVariantComparisonState()
        let launch = try beginComparison(state: &state)
        let precise = try request(.precise, in: launch)
        let natural = try request(.natural, in: launch)
        _ = state.receiveFailure(
            comparisonID: launch.comparisonID,
            requestID: precise.id,
            baseRevisionID: launch.baseRevisionID,
            routeToken: launch.routeToken,
            failure: .timedOut
        )
        _ = state.receive(response(for: natural, text: "Natural result"))

        let presentation = try requirePresentation(
            state,
            selectedProfile: .precise
        )

        #expect(presentation.isSettled)
        #expect(presentation.selectedProfile == .natural)
        #expect(presentation.canChooseSelectedCandidate)
        #expect(presentation.headerTitle == "Choose an alternative")
        #expect(
            presentation.candidates.first(where: { $0.profile == .precise })?.phase
                == .failure(.timedOut)
        )
        #expect(
            presentation.candidates.first(where: { $0.profile == .natural })?.phase
                == .success(text: "Natural result")
        )
    }

    @Test func bothSuccessfulCandidatesRespectTheRequestedTab() throws {
        var state = HaloVariantComparisonState()
        let launch = try beginComparison(state: &state)
        for request in launch.requests {
            _ = state.receive(
                response(for: request, text: "\(request.profile.rawValue) result")
            )
        }

        let presentation = try requirePresentation(
            state,
            selectedProfile: .natural
        )

        #expect(presentation.selectedProfile == .natural)
        #expect(presentation.selectedCandidate?.phase == .success(text: "natural result"))
        #expect(presentation.canChooseSelectedCandidate)
    }

    @Test func totalFailureKeepsBothSanitizedStatusesAndNoWinner() throws {
        var state = HaloVariantComparisonState()
        let launch = try beginComparison(state: &state)
        for request in launch.requests {
            _ = state.receiveFailure(
                comparisonID: launch.comparisonID,
                requestID: request.id,
                baseRevisionID: launch.baseRevisionID,
                routeToken: launch.routeToken,
                failure: request.profile == .precise ? .authenticationExpired : .rateLimited
            )
        }

        let presentation = try requirePresentation(state)

        #expect(presentation.isSettled)
        #expect(!presentation.canChooseSelectedCandidate)
        #expect(presentation.headerTitle == "Alternatives unavailable")
        #expect(presentation.candidates.count == 2)
        #expect(presentation.candidates.allSatisfy {
            if case .failure = $0.phase { return true }
            return false
        })
        #expect(!presentation.candidates[0].phase.detail.contains("token"))
        #expect(!presentation.candidates[1].phase.detail.contains("429"))
    }

    @Test func cancellationProjectionDisablesEveryInteraction() throws {
        var state = HaloVariantComparisonState()
        let launch = try beginComparison(state: &state)
        for request in launch.requests {
            _ = state.receive(
                response(for: request, text: "\(request.profile.rawValue) result")
            )
        }

        let presentation = try requirePresentation(
            state,
            isCancelling: true
        )

        #expect(presentation.isCancelling)
        #expect(!presentation.interactionsAreEnabled)
        #expect(!presentation.canChooseSelectedCandidate)
    }

    @Test func projectionNeverMutatesOrMaterializesComparisonState() throws {
        var state = HaloVariantComparisonState()
        let launch = try beginComparison(state: &state)
        for request in launch.requests {
            _ = state.receive(
                response(for: request, text: "\(request.profile.rawValue) result")
            )
        }
        let beforeProjection = state

        _ = HaloVariantDeckProjection.make(from: state)

        #expect(state == beforeProjection)
        #expect(state.status == .ready)
        #expect(state.materializedWinner == nil)
    }

    @Test func terminalHiddenStatesDoNotProjectADeck() throws {
        let idle = HaloVariantComparisonState()
        #expect(HaloVariantDeckProjection.make(from: idle) == nil)

        var cancelled = HaloVariantComparisonState()
        let cancelledLaunch = try beginComparison(state: &cancelled)
        _ = cancelled.cancel(comparisonID: cancelledLaunch.comparisonID)
        #expect(HaloVariantDeckProjection.make(from: cancelled) == nil)

        var materialized = HaloVariantComparisonState()
        let materializedLaunch = try beginComparison(state: &materialized)
        for request in materializedLaunch.requests {
            _ = materialized.receive(
                response(for: request, text: "\(request.profile.rawValue) result")
            )
        }
        _ = materialized.selectWinner(
            profile: .precise,
            comparisonID: materializedLaunch.comparisonID
        )
        #expect(HaloVariantDeckProjection.make(from: materialized) == nil)
    }

    @Test func candidateAccessibilityDescribesSlotProfileSelectionAndState() throws {
        var state = HaloVariantComparisonState()
        _ = try beginComparison(state: &state)

        let candidate = try #require(requirePresentation(state).selectedCandidate)

        #expect(candidate.accessibilityLabel.contains("A"))
        #expect(candidate.accessibilityLabel.contains("Precise"))
        #expect(candidate.accessibilityValue.contains("Selected"))
        #expect(!candidate.accessibilityHint.isEmpty)
    }

    @Test func reviewActionDisclosesTheExactConcurrentRequestCount() {
        #expect(HaloVariantDeckPolicy.requestCount == 2)
        #expect(HaloVariantDeckPolicy.compareActionTitle.contains("2"))
        #expect(HaloVariantDeckPolicy.compareActionHint.contains("two"))
        #expect(HaloVariantDeckPolicy.compareActionHint.contains("provider"))
        #expect(HaloVariantDeckPolicy.compareActionHint.contains("model"))
    }

    @Test func candidateViewportIdentityChangesForProfileResultAndComparison() throws {
        var state = HaloVariantComparisonState()
        let launch = try beginComparison(state: &state)
        let loading = try #require(requirePresentation(state).selectedCandidate)

        let precise = try request(.precise, in: launch)
        _ = state.receive(response(for: precise, text: "Precise result"))
        let preciseResult = try #require(requirePresentation(state).selectedCandidate)
        let naturalLoading = try #require(
            requirePresentation(state, selectedProfile: .natural).selectedCandidate
        )

        #expect(loading.viewportIdentity != preciseResult.viewportIdentity)
        #expect(preciseResult.viewportIdentity != naturalLoading.viewportIdentity)

        var nextState = HaloVariantComparisonState()
        _ = try beginComparison(state: &nextState)
        let nextComparison = try #require(requirePresentation(nextState).selectedCandidate)
        #expect(nextComparison.viewportIdentity != loading.viewportIdentity)
    }

    private func requirePresentation(
        _ state: HaloVariantComparisonState,
        selectedProfile: HaloVariantProfile = .precise,
        isCancelling: Bool = false
    ) throws -> HaloVariantDeckPresentation {
        try #require(
            HaloVariantDeckProjection.make(
                from: state,
                selectedProfile: selectedProfile,
                isCancelling: isCancelling
            )
        )
    }

    private func beginComparison(
        state: inout HaloVariantComparisonState
    ) throws -> HaloVariantComparisonLaunch {
        let result = state.begin(
            baseRevisionID: UUID(),
            baseText: "Base",
            routeToken: HaloVariantFrozenRouteToken(),
            remainingRevisionSlots: 1
        )
        guard case .started(let launch) = result else {
            Issue.record("Comparison should start")
            throw TestFailure.unexpectedStartResult
        }
        return launch
    }

    private func request(
        _ profile: HaloVariantProfile,
        in launch: HaloVariantComparisonLaunch
    ) throws -> HaloVariantRequest {
        guard let request = launch.requests.first(where: { $0.profile == profile }) else {
            Issue.record("Missing request")
            throw TestFailure.missingRequest
        }
        return request
    }

    private func response(
        for request: HaloVariantRequest,
        text: String
    ) -> HaloVariantResponse {
        HaloVariantResponse(
            comparisonID: request.comparisonID,
            requestID: request.id,
            baseRevisionID: request.baseRevisionID,
            routeToken: request.routeToken,
            replacementText: text
        )
    }

    private enum TestFailure: Error {
        case unexpectedStartResult
        case missingRequest
    }
}
