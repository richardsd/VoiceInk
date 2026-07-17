import Foundation
import Testing
@testable import VoiceInk

private actor HaloReviewDiffTestComputer {
    private(set) var invocationCount = 0
    var slowRevision: String?

    init(slowRevision: String? = nil) {
        self.slowRevision = slowRevision
    }

    func compare(original: String, revised: String) async -> HaloReviewDiffResult {
        invocationCount += 1
        let delay: Duration = revised == slowRevision ? .milliseconds(150) : .milliseconds(10)

        // Deliberately ignore task cancellation here. The presentation model's
        // request gate must still prevent an old result from being published.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay.timeInterval) {
                continuation.resume()
            }
        }

        return HaloReviewDiffEngine.compare(original: original, revised: revised)
    }
}

@MainActor
struct HaloPresentationModelTests {
    @Test func reviewStateProjectsOnlyUISafeRevisionValuesAndStartsOnFinal() throws {
        let state = makeState(raw: "Raw words", final: "Polished words")
        let selectedRevision = try #require(state.selectedRevision)
        let model = HaloPresentationModel()

        model.updateReviewState(state)

        #expect(model.phase == .reviewing)
        #expect(model.reviewLens == .final)
        #expect(model.selectedRevisionText == "Polished words")
        #expect(model.originalText == "Raw words")
        #expect(model.comparisonBaseText == "Raw words")
        #expect(model.selectedRevisionIndex == 0)
        #expect(model.revisionCount == 1)
        #expect(!model.canMovePrevious)
        #expect(!model.canMoveNext)
        #expect(model.selectedRevisionAction == .initial)
        #expect(model.canRefine)
        #expect(!model.isRefining)
        #expect(model.activeRefinementAction == nil)
        #expect(!model.hasReachedRevisionLimit)
        #expect(model.reviewNoticeMessage == nil)
        #expect(model.reviewNoticeTone == nil)
        #expect(
            model.reviewViewportIdentity == HaloReviewViewportIdentity(
                sessionID: state.session.id,
                revisionID: selectedRevision.id,
                lens: .final
            )
        )
        #expect(model.diffResult == nil)
        #expect(!model.isComputingDiff)
    }

    @Test func changesLensComputesOnceAndCountdownOnlyUpdatesDoNotRestartIt() async {
        let computer = HaloReviewDiffTestComputer()
        let model = HaloPresentationModel { original, revised in
            await computer.compare(original: original, revised: revised)
        }
        var state = makeState(raw: "Raw sentence.", final: "Clear sentence.")
        state.selectLens(.changes)

        model.updateReviewState(state)
        await waitUntil { model.diffResult != nil }

        #expect(model.diffResult?.originalText == "Raw sentence.")
        #expect(model.diffResult?.revisedText == "Clear sentence.")
        let countAfterFirstDiff = await computer.invocationCount
        #expect(countAfterFirstDiff == 1)

        model.updateReviewStatus(feedback: nil, secondsRemaining: 15, isDelivering: false)
        model.updateReviewState(state)
        try? await Task.sleep(for: .milliseconds(40))

        let countAfterCountdown = await computer.invocationCount
        #expect(countAfterCountdown == 1)
        #expect(model.diffResult?.revisedText == "Clear sentence.")
    }

    @Test func newerRevisionRejectsAStaleBackgroundDiffAndChangesViewportIdentity() async throws {
        let computer = HaloReviewDiffTestComputer(slowRevision: "Initial revision")
        let model = HaloPresentationModel { original, revised in
            await computer.compare(original: original, revised: revised)
        }
        var state = makeState(raw: "Raw", final: "Initial revision")
        state.selectLens(.changes)
        model.updateReviewState(state)
        let initialViewportIdentity = model.reviewViewportIdentity

        await waitUntil { await computer.invocationCount == 1 }

        let parent = try #require(state.selectedRevision)
        let pendingRequest = state.beginRefinement(action: .clearer)
        let request = try #require(pendingRequest)
        let nextRevision = makeRevision(
            text: "Newest revision",
            parentID: parent.id,
            action: .refinement(.clearer)
        )
        let completion = state.completeRefinement(
            requestID: request.id,
            revision: nextRevision
        )
        #expect(completion == .appended)
        model.updateReviewState(state)

        await waitUntil { model.diffResult?.revisedText == "Newest revision" }
        try? await Task.sleep(for: .milliseconds(180))

        #expect(model.diffResult?.originalText == "Initial revision")
        #expect(model.diffResult?.revisedText == "Newest revision")
        #expect(model.selectedRevisionIndex == 1)
        #expect(model.revisionCount == 2)
        #expect(model.canMovePrevious)
        #expect(!model.canMoveNext)
        #expect(model.reviewViewportIdentity != initialViewportIdentity)
        let finalInvocationCount = await computer.invocationCount
        #expect(finalInvocationCount == 2)
    }

    @Test func refinementProgressAndNoticesDoNotChangeViewportOrRestartDiff() async throws {
        let computer = HaloReviewDiffTestComputer()
        let model = HaloPresentationModel { original, revised in
            await computer.compare(original: original, revised: revised)
        }
        var state = makeState(raw: "Raw", final: "Initial revision")
        state.selectLens(.changes)
        model.updateReviewState(state)
        await waitUntil { model.diffResult != nil }

        let viewportIdentity = try #require(model.reviewViewportIdentity)
        let pendingRequest = state.beginRefinement(action: .formal)
        let request = try #require(pendingRequest)
        model.updateReviewState(state)

        #expect(model.isRefining)
        #expect(!model.canRefine)
        #expect(model.activeRefinementAction == .formal)
        #expect(model.reviewViewportIdentity == viewportIdentity)
        #expect(model.reviewNoticeMessage == nil)
        #expect(model.reviewNoticeTone == nil)

        try? await Task.sleep(for: .milliseconds(40))
        let progressInvocationCount = await computer.invocationCount
        #expect(progressInvocationCount == 1)

        let didFinishWithFailure = state.finishRefinementFailure(
            requestID: request.id,
            notice: .refinementFailed("Refinement is temporarily unavailable.")
        )
        #expect(didFinishWithFailure)
        model.updateReviewState(state)

        #expect(!model.isRefining)
        #expect(model.activeRefinementAction == nil)
        #expect(model.reviewViewportIdentity == viewportIdentity)
        #expect(model.reviewNoticeMessage == "Refinement is temporarily unavailable.")
        #expect(model.reviewNoticeTone == .warning)

        let pendingNeutralRequest = state.beginRefinement(action: .clearer)
        let neutralRequest = try #require(pendingNeutralRequest)
        let didFinishWithoutChanges = state.finishRefinementFailure(
            requestID: neutralRequest.id,
            notice: .unchangedRefinement
        )
        #expect(didFinishWithoutChanges)
        model.updateReviewState(state)

        #expect(model.reviewNoticeMessage == "The refinement did not change this version.")
        #expect(model.reviewNoticeTone == .neutral)
        let finalInvocationCount = await computer.invocationCount
        #expect(finalInvocationCount == 1)
    }

    @Test func revisionLimitProjectsAProactiveDisabledOrbitNotice() throws {
        let model = HaloPresentationModel()
        var state = makeState(raw: "Raw", final: "Version 1")

        for index in 1..<HaloReviewState.maximumRevisionCount {
            let parent = try #require(state.selectedRevision)
            let action = HaloRefinementOrbitPolicy.actions[(index - 1) % 5]
            let pendingRequest = state.beginRefinement(action: action)
            let request = try #require(pendingRequest)
            let revision = makeRevision(
                text: "Version \(index + 1)",
                parentID: parent.id,
                action: .refinement(action)
            )
            let completion = state.completeRefinement(
                requestID: request.id,
                revision: revision
            )
            #expect(completion == .appended)
        }

        model.updateReviewState(state)

        #expect(model.revisionCount == HaloReviewState.maximumRevisionCount)
        #expect(model.hasReachedRevisionLimit)
        #expect(!model.canRefine)
        #expect(!model.isRefining)
        #expect(model.activeRefinementAction == nil)
        #expect(model.reviewNoticeMessage == "This review already has six versions.")
        #expect(model.reviewNoticeTone == .warning)
    }

    @Test func reviewWithoutFrozenEnhancementConfigurationDisablesRefinement() {
        let model = HaloPresentationModel()
        let state = makeState(
            raw: "Raw",
            final: "Raw",
            supportsRefinement: false
        )

        model.updateReviewState(state)

        #expect(!model.canRefine)
        #expect(!model.isRefining)
        #expect(!model.hasReachedRevisionLimit)
        #expect(model.activeRefinementAction == nil)
    }

    @Test func manualEditProjectionDisablesCompetingActionsAndTracksDraft() {
        let model = HaloPresentationModel()
        var state = makeState(raw: "Raw", final: "Enhanced")

        let didBegin = state.beginManualEdit()
        let didUpdate = state.updateManualEdit("Hand edited")
        #expect(didBegin)
        #expect(didUpdate)
        model.updateReviewState(state)

        #expect(model.isEditingManually)
        #expect(model.manualEditText == "Hand edited")
        #expect(!model.canRefine)
        #expect(!model.canUseOriginal)
        #expect(!model.canBeginManualEdit)
        #expect(!model.canMovePrevious)
        #expect(!model.canMoveNext)

        let didCancel = state.cancelManualEdit()
        #expect(didCancel)
        model.updateReviewState(state)
        #expect(!model.isEditingManually)
        #expect(model.canUseOriginal)
        #expect(model.canBeginManualEdit)
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await condition() {
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeState(
        raw: String,
        final: String,
        supportsRefinement: Bool = true
    ) -> HaloReviewState {
        let metadata = HaloReviewModelMetadata(
            modeName: "Dictation",
            modeEmoji: "mic.fill",
            providerLabel: "OpenAI",
            connectionLabel: "OAuth",
            modelLabel: "gpt-5.6-luna"
        )
        let session = HaloReviewSession(
            transcriptionID: UUID(),
            rawText: raw,
            initialEnhancement: final,
            destination: nil,
            metadata: metadata,
            enhancementWarning: nil,
            output: OutputRuntimeConfiguration(
                mode: nil,
                outputMode: .paste,
                haloDeliveryPolicy: .alwaysReview,
                autoSendKey: .none,
                customCommand: nil
            ),
            enhancementConfiguration: supportsRefinement
                ? EnhancementRuntimeConfiguration(
                    mode: nil,
                    isEnabled: true,
                    prompt: CustomPrompt(
                        title: "Voice Dictation",
                        promptText: "Preserve every material fact.",
                        useSystemInstructions: false
                    ),
                    provider: .openAI,
                    modelName: "gpt-5.6-luna",
                    openAIAuthMode: .oauth,
                    useClipboardContext: false,
                    useSelectedTextContext: true,
                    useScreenCaptureContext: false
                )
                : nil,
            frozenContext: nil
        )
        return HaloReviewState(
            session: session,
            initialRevision: makeRevision(text: final, parentID: nil, action: .initial)
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

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
