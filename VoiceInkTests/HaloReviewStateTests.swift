import Foundation
import Testing
@testable import VoiceInk

struct HaloReviewStateTests {
    @Test func initialRevisionOpensOnFinalAndComparesAgainstRawText() {
        let state = makeState(raw: "Raw words", final: "Polished words")

        #expect(state.lens == .final)
        #expect(state.revisions.count == 1)
        #expect(state.selectedRevision?.text == "Polished words")
        #expect(state.comparisonBaseText == "Raw words")
    }

    @Test func successfulRefinementAppendsSelectsAndComparesWithItsParent() throws {
        var state = makeState(raw: "Raw", final: "Initial")
        let parent = try #require(state.selectedRevision)
        let requestID = UUID()

        let begin = HaloReviewReducer.reduce(
            state: &state,
            action: .beginRefinement(.clearer, requestID: requestID, at: Date(timeIntervalSince1970: 10))
        )
        let revision = makeRevision(text: "Clear revision", parentID: parent.id, action: .refinement(.clearer))
        let complete = HaloReviewReducer.reduce(
            state: &state,
            action: .completeRefinement(
                requestID: requestID,
                revision: revision,
                at: Date(timeIntervalSince1970: 20)
            )
        )

        #expect(begin == .refinementStarted(HaloReviewRefinementRequest(
            id: requestID,
            action: .clearer,
            baseRevisionID: parent.id
        )))
        #expect(complete == .revisionAppended(revision.id))
        #expect(state.selectedRevisionID == revision.id)
        #expect(state.lens == .changes)
        #expect(state.comparisonBaseText == "Initial")
    }

    @Test func emptyUnchangedAndStaleResultsNeverCreateRevisions() throws {
        var state = makeState(raw: "Raw", final: "Initial")
        let parent = try #require(state.selectedRevision)
        let requestID = UUID()
        _ = state.beginRefinement(action: .shorter, requestID: requestID)

        let stale = state.completeRefinement(
            requestID: UUID(),
            revision: makeRevision(text: "Stale", parentID: parent.id, action: .refinement(.shorter))
        )
        #expect(stale == .stale)
        #expect(state.revisions.count == 1)

        let unchanged = state.completeRefinement(
            requestID: requestID,
            revision: makeRevision(text: "Initial", parentID: parent.id, action: .refinement(.shorter))
        )
        #expect(unchanged == .unchanged)
        #expect(state.revisions.count == 1)

        let possibleEmptyRequest = state.beginRefinement(action: .clearer)
        let emptyRequest = try #require(possibleEmptyRequest)
        let empty = state.completeRefinement(
            requestID: emptyRequest.id,
            revision: makeRevision(text: "  \n", parentID: parent.id, action: .refinement(.clearer))
        )
        #expect(empty == .empty)
        #expect(state.revisions.count == 1)
    }

    @Test func reviewKeepsAtMostSixRevisionsWithoutEviction() throws {
        var state = makeState(raw: "Raw", final: "Version 1")

        for version in 2...6 {
            let parent = try #require(state.selectedRevision)
            let possibleRequest = state.beginRefinement(action: .clearer)
            let request = try #require(possibleRequest)
            let result = state.completeRefinement(
                requestID: request.id,
                revision: makeRevision(
                    text: "Version \(version)",
                    parentID: parent.id,
                    action: .refinement(.clearer)
                )
            )
            #expect(result == .appended)
        }

        let retainedIDs = state.revisions.map(\.id)
        #expect(state.revisions.count == 6)
        #expect(!state.canRefine)
        let rejectedRefinement = state.beginRefinement(action: .formal)
        #expect(rejectedRefinement == nil)
        #expect(state.revisions.map(\.id) == retainedIDs)
        #expect(state.notice == .revisionLimitReached)
    }

    @Test func inactivityResetsOnInteractionAndPausesDuringRefinement() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var state = makeState(raw: "Raw", final: "Final", now: start)

        _ = HaloReviewReducer.reduce(
            state: &state,
            action: .selectLens(.original, at: start.addingTimeInterval(60))
        )
        #expect(state.secondsRemaining(at: start.addingTimeInterval(179)) == 1)

        let requestID = UUID()
        _ = HaloReviewReducer.reduce(
            state: &state,
            action: .beginRefinement(
                .formal,
                requestID: requestID,
                at: start.addingTimeInterval(179)
            )
        )
        #expect(
            HaloReviewReducer.reduce(
                state: &state,
                action: .timeout(at: start.addingTimeInterval(1_000))
            ) == .ignored
        )
        #expect(!state.isExpired)

        _ = HaloReviewReducer.reduce(
            state: &state,
            action: .failRefinement(
                requestID: requestID,
                notice: .refinementFailed("Try again"),
                at: start.addingTimeInterval(1_000)
            )
        )
        #expect(state.secondsRemaining(at: start.addingTimeInterval(1_119)) == 1)
        #expect(
            HaloReviewReducer.reduce(
                state: &state,
                action: .timeout(at: start.addingTimeInterval(1_120))
            ) == .expired
        )
    }

    @Test func revisionNavigationOnlyResetsInactivityWhenMovementIsAccepted() throws {
        let start = Date(timeIntervalSince1970: 2_000)
        var state = makeState(raw: "Raw", final: "Initial", now: start)
        let parent = try #require(state.selectedRevision)
        let possibleRequest = state.beginRefinement(
            action: .clearer,
            at: start.addingTimeInterval(1)
        )
        let request = try #require(possibleRequest)
        _ = state.completeRefinement(
            requestID: request.id,
            revision: makeRevision(
                text: "Second",
                parentID: parent.id,
                action: .refinement(.clearer)
            ),
            at: start.addingTimeInterval(2)
        )

        let expirationBeforeRejectedMovement = state.expiresAt
        let rejected = HaloReviewReducer.reduce(
            state: &state,
            action: .moveRevision(1, at: start.addingTimeInterval(40))
        )
        #expect(rejected == .ignored)
        #expect(state.expiresAt == expirationBeforeRejectedMovement)

        let accepted = HaloReviewReducer.reduce(
            state: &state,
            action: .moveRevision(-1, at: start.addingTimeInterval(60))
        )
        #expect(accepted == .none)
        #expect(state.selectedRevisionID == parent.id)
        #expect(
            state.expiresAt
                == start.addingTimeInterval(60 + HaloReviewState.inactivityLifetime)
        )
    }

    private func makeState(
        raw: String,
        final: String,
        now: Date = Date()
    ) -> HaloReviewState {
        let metadata = HaloReviewModelMetadata(
            modeName: "Dictation",
            modeEmoji: "mic.fill",
            providerLabel: "OpenAI",
            connectionLabel: "OAuth",
            modelLabel: "gpt-5.6-luna"
        )
        let output = OutputRuntimeConfiguration(
            mode: nil,
            outputMode: .paste,
            haloDeliveryPolicy: .alwaysReview,
            autoSendKey: .none,
            customCommand: nil
        )
        let session = HaloReviewSession(
            transcriptionID: UUID(),
            rawText: raw,
            initialEnhancement: final,
            destination: nil,
            metadata: metadata,
            enhancementWarning: nil,
            output: output,
            enhancementConfiguration: nil,
            frozenContext: nil,
            createdAt: now
        )
        return HaloReviewState(
            session: session,
            initialRevision: makeRevision(text: final, parentID: nil, action: .initial),
            now: now
        )
    }

    private func makeRevision(
        text: String,
        parentID: UUID?,
        action: HaloReviewRevisionAction
    ) -> HaloReviewRevision {
        HaloReviewRevision(
            parentID: parentID,
            action: action,
            text: text,
            metadata: HaloReviewModelMetadata(
                modeName: "Dictation",
                modeEmoji: nil,
                providerLabel: "OpenAI",
                connectionLabel: "OAuth",
                modelLabel: "gpt-5.6-luna"
            ),
            payload: PreparedPastePayload(
                displayText: text,
                pastedText: text,
                autoSendKey: .none
            )
        )
    }
}
