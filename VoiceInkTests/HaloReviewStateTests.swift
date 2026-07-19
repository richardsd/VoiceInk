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

    @Test func useOriginalCreatesOneImmutableRevisionAndReusesIt() throws {
        var state = makeState(raw: "Raw transcript", final: "Enhanced transcript")
        let enhanced = try #require(state.selectedRevision)
        let original = makeRevision(
            text: "Raw transcript",
            parentID: enhanced.id,
            action: .original
        )

        #expect(
            HaloReviewReducer.reduce(
                state: &state,
                action: .useOriginal(original, at: Date())
            ) == .revisionAppended(original.id)
        )
        #expect(state.revisions.count == 2)
        #expect(state.selectedRevision?.action == .original)
        #expect(state.selectedRevision?.payload.pastedText == "Raw transcript")

        _ = state.selectRevision(id: enhanced.id)
        let duplicate = makeRevision(
            text: "Raw transcript",
            parentID: enhanced.id,
            action: .original
        )
        _ = HaloReviewReducer.reduce(
            state: &state,
            action: .useOriginal(duplicate, at: Date())
        )
        #expect(state.revisions.count == 2)
        #expect(state.selectedRevision?.id == original.id)
    }

    @Test func manualEditCreatesAReplacementRevisionWithoutMutatingItsParent() throws {
        var state = makeState(raw: "Raw", final: "Initial")
        let parent = try #require(state.selectedRevision)

        #expect(
            HaloReviewReducer.reduce(
                state: &state,
                action: .beginManualEdit(at: Date())
            ) == .none
        )
        #expect(state.isEditingManually)
        #expect(state.beginRefinement(action: .clearer) == nil)

        _ = HaloReviewReducer.reduce(
            state: &state,
            action: .updateManualEdit("Edited final", at: Date())
        )
        let edited = makeRevision(
            text: "Edited final",
            parentID: parent.id,
            action: .manualEdit
        )
        #expect(
            HaloReviewReducer.reduce(
                state: &state,
                action: .completeManualEdit(edited, at: Date())
            ) == .revisionAppended(edited.id)
        )
        #expect(state.revisions.count == 2)
        #expect(state.revisions.first?.text == "Initial")
        #expect(state.selectedRevision?.text == "Edited final")
        #expect(state.selectedRevision?.action == .manualEdit)
        #expect(!state.isEditingManually)
    }

    @Test func emptyUnchangedAndCancelledManualEditsCreateNoRevision() {
        var state = makeState(raw: "Raw", final: "Initial")
        _ = state.beginManualEdit()
        let parentID = state.selectedRevisionID
        let unchanged = makeRevision(
            text: "Initial",
            parentID: parentID,
            action: .manualEdit
        )
        let didSaveUnchanged = state.completeManualEdit(revision: unchanged)
        #expect(!didSaveUnchanged)
        #expect(state.notice == .unchangedManualEdit)
        #expect(state.revisions.count == 1)

        _ = state.beginManualEdit()
        _ = state.updateManualEdit("Temporary")
        let didCancel = state.cancelManualEdit()
        #expect(didCancel)
        #expect(state.revisions.count == 1)
        #expect(state.selectedRevisionID == parentID)
    }

    @Test func voiceRefinementAcceptsOnlyOrderedTransitionsAndRejectsStaleResults() throws {
        let start = Date(timeIntervalSince1970: 3_000)
        var state = makeState(raw: "Raw", final: "Initial", now: start)
        let parent = try #require(state.selectedRevision)
        let requestID = UUID()

        let beginEffect = HaloReviewReducer.reduce(
            state: &state,
            action: .beginVoiceRefinement(requestID: requestID, at: start)
        )
        #expect(
            beginEffect == .voiceRefinementStarted(
                HaloVoiceRefinementRequest(id: requestID, baseRevisionID: parent.id)
            )
        )
        #expect(
            state.voiceRefinementPhase
                == .listening(HaloVoiceRefinementRequest(id: requestID, baseRevisionID: parent.id))
        )

        let outOfOrderEffect = HaloReviewReducer.reduce(
            state: &state,
            action: .finishVoiceTranscription(requestID: requestID, at: start)
        )
        #expect(outOfOrderEffect == .ignored)
        let staleCaptureEffect = HaloReviewReducer.reduce(
            state: &state,
            action: .finishVoiceCapture(requestID: UUID(), at: start)
        )
        #expect(staleCaptureEffect == .ignored)

        let captureEffect = HaloReviewReducer.reduce(
            state: &state,
            action: .finishVoiceCapture(requestID: requestID, at: start)
        )
        #expect(
            captureEffect == .voiceRefinementPhaseChanged(
                .transcribing(HaloVoiceRefinementRequest(id: requestID, baseRevisionID: parent.id))
            )
        )
        let transcriptionEffect = HaloReviewReducer.reduce(
            state: &state,
            action: .finishVoiceTranscription(requestID: requestID, at: start)
        )
        #expect(
            transcriptionEffect == .voiceRefinementPhaseChanged(
                .refining(HaloVoiceRefinementRequest(id: requestID, baseRevisionID: parent.id))
            )
        )

        let revision = makeRevision(
            text: "Voice-refined result",
            parentID: parent.id,
            action: .voiceRefinement
        )
        let staleCompletionEffect = HaloReviewReducer.reduce(
            state: &state,
            action: .completeVoiceRefinement(
                requestID: UUID(),
                revision: revision,
                at: start
            )
        )
        #expect(staleCompletionEffect == .ignored)
        #expect(state.revisions.count == 1)

        let completionEffect = HaloReviewReducer.reduce(
            state: &state,
            action: .completeVoiceRefinement(
                requestID: requestID,
                revision: revision,
                at: start
            )
        )
        #expect(completionEffect == .revisionAppended(revision.id))
        #expect(state.selectedRevision?.action == .voiceRefinement)
        #expect(state.selectedRevision?.text == "Voice-refined result")
        #expect(state.comparisonBaseText == "Initial")
        #expect(state.lens == .changes)
        #expect(state.voiceRefinementPhase == .idle)
    }

    @Test func voiceOperationIsMutuallyExclusiveAndEscapeCancelsItBeforeReview() throws {
        let start = Date(timeIntervalSince1970: 4_000)
        var state = makeState(raw: "Raw", final: "Initial", now: start)
        let parent = try #require(state.selectedRevision)
        let requestID = UUID()
        _ = state.beginVoiceRefinement(requestID: requestID, at: start)

        #expect(state.isVoiceRefinementActive)
        #expect(!state.canResolveReview)
        let duplicateVoiceRequest = state.beginVoiceRefinement()
        let presetRequest = state.beginRefinement(action: .shorter)
        #expect(duplicateVoiceRequest == nil)
        #expect(presetRequest == nil)
        let didBeginManualEdit = state.beginManualEdit()
        let didSelectParent = state.selectRevision(id: parent.id)
        #expect(!didBeginManualEdit)
        #expect(!didSelectParent)
        let copyEffect = HaloReviewReducer.reduce(
            state: &state,
            action: .copied(succeeded: true, at: start)
        )
        #expect(copyEffect == .ignored)

        let cancelEffect = HaloReviewReducer.reduce(
            state: &state,
            action: .cancelActiveTransientAction(at: start.addingTimeInterval(5))
        )
        #expect(cancelEffect == .voiceRefinementCancelled(requestID))
        #expect(state.voiceRefinementPhase == .idle)
        #expect(state.notice == .voiceRefinementCancelled)
        #expect(state.selectedRevisionID == parent.id)
        #expect(state.canResolveReview)

        // A second Escape has no transient work to consume, allowing the
        // caller to continue with its existing review-cancel behavior.
        let secondCancelEffect = HaloReviewReducer.reduce(
            state: &state,
            action: .cancelActiveTransientAction(at: start.addingTimeInterval(6))
        )
        #expect(secondCancelEffect == .ignored)
    }

    @Test func voiceFailureIsNonDestructiveAndResetsPausedInactivity() throws {
        let start = Date(timeIntervalSince1970: 5_000)
        var state = makeState(raw: "Raw", final: "Initial", now: start)
        let originalRevision = try #require(state.selectedRevision)
        let requestID = UUID()
        _ = state.beginVoiceRefinement(
            requestID: requestID,
            at: start.addingTimeInterval(119)
        )

        let pausedTimeoutEffect = HaloReviewReducer.reduce(
            state: &state,
            action: .timeout(at: start.addingTimeInterval(500))
        )
        #expect(pausedTimeoutEffect == .ignored)
        #expect(!state.isExpired)

        let failureEffect = HaloReviewReducer.reduce(
            state: &state,
            action: .failVoiceRefinement(
                requestID: requestID,
                failure: .transcriptionFailed,
                at: start.addingTimeInterval(500)
            )
        )
        #expect(failureEffect == .voiceRefinementPhaseChanged(.failed(.transcriptionFailed)))
        #expect(state.selectedRevisionID == originalRevision.id)
        #expect(state.revisions.count == 1)
        #expect(state.notice == .voiceRefinementFailed(.transcriptionFailed))
        #expect(state.secondsRemaining(at: start.addingTimeInterval(619)) == 1)
        let expirationEffect = HaloReviewReducer.reduce(
            state: &state,
            action: .timeout(at: start.addingTimeInterval(620))
        )
        #expect(expirationEffect == .expired)
    }

    @Test func oversizedVoiceDirectiveFailureIsDistinctAndNonDestructive() throws {
        let start = Date(timeIntervalSince1970: 6_000)
        var state = makeState(raw: "Raw", final: "Initial", now: start)
        let originalRevision = try #require(state.selectedRevision)
        let requestID = UUID()
        let beginEffect = HaloReviewReducer.reduce(
            state: &state,
            action: .beginVoiceRefinement(requestID: requestID, at: start)
        )
        #expect(beginEffect != .ignored)

        let failureEffect = HaloReviewReducer.reduce(
            state: &state,
            action: .failVoiceRefinement(
                requestID: requestID,
                failure: .tooLongInstruction,
                at: start.addingTimeInterval(1)
            )
        )

        #expect(failureEffect == .voiceRefinementPhaseChanged(.failed(.tooLongInstruction)))
        #expect(state.selectedRevisionID == originalRevision.id)
        #expect(state.revisions.count == 1)
        #expect(state.notice == .voiceRefinementFailed(.tooLongInstruction))
        #expect(
            HaloVoiceRefinementFailure.tooLongInstruction.message
                == String(localized: "The spoken change is too long. Try a shorter instruction.")
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
