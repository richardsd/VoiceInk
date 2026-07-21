import Foundation
import Testing
@testable import VoiceInk

struct HaloVariantComparisonTests {
    @Test func profilesHaveFixedDistinctFactPreservingDescriptorsAndABSlots() {
        #expect(HaloVariantProfile.allCases == [.precise, .natural])
        #expect(HaloVariantProfile.precise.slot == .a)
        #expect(HaloVariantProfile.natural.slot == .b)
        #expect(HaloVariantProfile.precise.promptDescriptor.title == "Precise")
        #expect(HaloVariantProfile.natural.promptDescriptor.title == "Natural")
        #expect(
            HaloVariantProfile.precise.promptDescriptor.instruction
                .contains("Preserve every fact")
        )
        #expect(
            HaloVariantProfile.natural.promptDescriptor.instruction
                .contains("preserving every fact")
        )
        #expect(
            HaloVariantProfile.precise.promptDescriptor
                != HaloVariantProfile.natural.promptDescriptor
        )
    }

    @Test func launchCreatesOnlyTwoRequestsOnOneFrozenRoute() throws {
        let route = HaloVariantFrozenRouteToken()
        let baseRevisionID = UUID()
        var state = HaloVariantComparisonState()

        let launch = try startedLaunch(
            state.begin(
                baseRevisionID: baseRevisionID,
                baseText: "Base",
                routeToken: route,
                remainingRevisionSlots: 1
            )
        )

        #expect(launch.requests.count == 2)
        #expect(Set(launch.requests.map(\.profile)) == Set(HaloVariantProfile.allCases))
        #expect(launch.requests.allSatisfy { $0.routeToken == route })
        #expect(launch.requests.allSatisfy { $0.baseRevisionID == baseRevisionID })
        #expect(state.pendingRequests.count == 2)
        #expect(state.status == .comparing)
    }

    @Test func comparisonRequiresOneRevisionSlot() {
        var state = HaloVariantComparisonState()

        let result = state.begin(
            baseRevisionID: UUID(),
            baseText: "Base",
            routeToken: HaloVariantFrozenRouteToken(),
            remainingRevisionSlots: 0
        )

        #expect(result == .failed(.revisionSlotUnavailable))
        #expect(state.status == .idle)
        #expect(state.pendingRequests.isEmpty)
    }

    @Test func successfulResponsesRemainProvisionalUntilWinnerSelection() throws {
        var state = HaloVariantComparisonState()
        let launch = try beginComparison(state: &state)
        let precise = try request(.precise, in: launch)
        let natural = try request(.natural, in: launch)

        #expect(
            state.receive(response(for: precise, text: "Precise replacement"))
                == .candidateAccepted(.precise)
        )
        #expect(state.status == .comparing)
        #expect(state.materializedWinner == nil)
        #expect(
            state.receive(response(for: natural, text: "Natural replacement"))
                == .candidateAccepted(.natural)
        )

        #expect(state.status == .ready)
        #expect(state.provisionalCandidates.count == 2)
        #expect(state.materializedWinner == nil)
    }

    @Test func partialFailureStillAllowsOneWinnerAndDiscardsOtherSlot() throws {
        var state = HaloVariantComparisonState()
        let launch = try beginComparison(state: &state)
        let precise = try request(.precise, in: launch)
        let natural = try request(.natural, in: launch)

        #expect(
            state.receiveFailure(
                comparisonID: launch.comparisonID,
                requestID: precise.id,
                baseRevisionID: launch.baseRevisionID,
                routeToken: launch.routeToken,
                failure: .timedOut
            ) == .failureAccepted(.precise)
        )
        #expect(state.status == .partialFailure)
        #expect(
            state.receive(response(for: natural, text: "Natural replacement"))
                == .candidateAccepted(.natural)
        )

        let selection = state.selectWinner(
            profile: .natural,
            comparisonID: launch.comparisonID
        )
        guard case .materialized(let winner) = selection else {
            Issue.record("The surviving candidate should materialize")
            return
        }

        #expect(winner.profile == .natural)
        #expect(winner.replacementText == "Natural replacement")
        #expect(state.status == .materialized)
        #expect(state.provisionalCandidates.isEmpty)
        #expect(state.failures.isEmpty)
        #expect(
            state.selectWinner(profile: .precise, comparisonID: launch.comparisonID)
                == .candidateUnavailable
        )
    }

    @Test func twoFailuresProduceTotalFailureWithoutMaterialization() throws {
        var state = HaloVariantComparisonState()
        let launch = try beginComparison(state: &state)

        for request in launch.requests {
            _ = state.receiveFailure(
                comparisonID: launch.comparisonID,
                requestID: request.id,
                baseRevisionID: launch.baseRevisionID,
                routeToken: launch.routeToken,
                failure: .networkUnavailable
            )
        }

        #expect(state.status == .totalFailure)
        #expect(state.failures.count == 2)
        #expect(state.provisionalCandidates.isEmpty)
        #expect(state.materializedWinner == nil)
    }

    @Test func cancellationReturnsPendingIDsAndRejectsLateResponses() throws {
        var state = HaloVariantComparisonState()
        let launch = try beginComparison(state: &state)
        let request = try request(.precise, in: launch)

        let cancellation = state.cancel(comparisonID: launch.comparisonID)
        guard case .cancelled(let pendingRequestIDs) = cancellation else {
            Issue.record("Active comparison should cancel")
            return
        }

        #expect(Set(pendingRequestIDs) == Set(launch.requests.map(\.id)))
        #expect(state.status == .cancelled)
        #expect(state.pendingRequests.isEmpty)
        #expect(state.receive(response(for: request, text: "Late")) == .stale)
    }

    @Test func wrongComparisonRequestBaseOrRouteIsStale() throws {
        var state = HaloVariantComparisonState()
        let launch = try beginComparison(state: &state)
        let request = try request(.precise, in: launch)

        #expect(
            state.receive(
                HaloVariantResponse(
                    comparisonID: UUID(),
                    requestID: request.id,
                    baseRevisionID: request.baseRevisionID,
                    routeToken: request.routeToken,
                    replacementText: "Result"
                )
            ) == .stale
        )
        #expect(
            state.receive(
                HaloVariantResponse(
                    comparisonID: request.comparisonID,
                    requestID: UUID(),
                    baseRevisionID: request.baseRevisionID,
                    routeToken: request.routeToken,
                    replacementText: "Result"
                )
            ) == .stale
        )
        #expect(
            state.receive(
                HaloVariantResponse(
                    comparisonID: request.comparisonID,
                    requestID: request.id,
                    baseRevisionID: UUID(),
                    routeToken: request.routeToken,
                    replacementText: "Result"
                )
            ) == .stale
        )
        #expect(
            state.receive(
                HaloVariantResponse(
                    comparisonID: request.comparisonID,
                    requestID: request.id,
                    baseRevisionID: request.baseRevisionID,
                    routeToken: HaloVariantFrozenRouteToken(),
                    replacementText: "Result"
                )
            ) == .stale
        )
        #expect(state.pendingRequests.count == 2)
    }

    @Test func emptyAndUnchangedResultsAreInvalidFailures() throws {
        var state = HaloVariantComparisonState()
        let launch = try beginComparison(state: &state, baseText: "Same text")
        let precise = try request(.precise, in: launch)
        let natural = try request(.natural, in: launch)

        #expect(
            state.receive(response(for: precise, text: " \n "))
                == .invalidResult(.emptyResult)
        )
        #expect(
            state.receive(response(for: natural, text: "  Same text\n"))
                == .invalidResult(.unchangedResult)
        )
        #expect(state.status == .totalFailure)
        #expect(Set(state.failures.map(\.reason)) == [.emptyResult, .unchangedResult])
        #expect(state.provisionalCandidates.isEmpty)
    }

    @Test func winnerCanMaterializeOnlyOnceAndUnselectedCandidateIsDiscarded() throws {
        var state = HaloVariantComparisonState()
        let launch = try beginComparison(state: &state)

        for request in launch.requests {
            _ = state.receive(
                response(for: request, text: "\(request.profile.rawValue) replacement")
            )
        }

        let first = state.selectWinner(
            profile: .precise,
            comparisonID: launch.comparisonID
        )
        let second = state.selectWinner(
            profile: .natural,
            comparisonID: launch.comparisonID
        )

        guard case .materialized(let winner) = first else {
            Issue.record("First selection should materialize")
            return
        }
        #expect(winner.profile == .precise)
        #expect(state.materializedWinner == winner)
        #expect(state.provisionalCandidates.isEmpty)
        #expect(second == .candidateUnavailable)
    }

    private func beginComparison(
        state: inout HaloVariantComparisonState,
        baseText: String = "Base"
    ) throws -> HaloVariantComparisonLaunch {
        try startedLaunch(
            state.begin(
                baseRevisionID: UUID(),
                baseText: baseText,
                routeToken: HaloVariantFrozenRouteToken(),
                remainingRevisionSlots: 1
            )
        )
    }

    private func startedLaunch(
        _ result: HaloVariantComparisonStartResult
    ) throws -> HaloVariantComparisonLaunch {
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
            Issue.record("Missing \(profile.rawValue) request")
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
