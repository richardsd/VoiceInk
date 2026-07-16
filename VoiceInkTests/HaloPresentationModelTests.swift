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
        #expect(
            state.completeRefinement(requestID: request.id, revision: nextRevision) == .appended
        )
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

    private func makeState(raw: String, final: String) -> HaloReviewState {
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
            enhancementConfiguration: nil,
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
