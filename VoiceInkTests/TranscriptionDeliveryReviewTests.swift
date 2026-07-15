import Foundation
import Testing
@testable import VoiceInk

@MainActor
private final class SpyPasteDeliveryService: PasteDeliveryServicing {
    var preparedTexts: [String] = []
    var deliveredPayloads: [PreparedPastePayload] = []
    var copiedPayloads: [PreparedPastePayload] = []
    var reviewReadyCount = 0

    func prepare(text: String, output: OutputRuntimeConfiguration) -> PreparedPastePayload {
        preparedTexts.append(text)
        return PreparedPastePayload(
            displayText: text,
            pastedText: "prepared:\(text)",
            autoSendKey: output.outputMode == .paste ? output.autoSendKey : .none
        )
    }

    func deliver(
        _ payload: PreparedPastePayload,
        dismiss: () async -> Void,
        playStopSound: Bool
    ) async -> PasteDeliveryOutcome {
        await dismiss()
        deliveredPayloads.append(payload)
        return .commandPosted
    }

    func deliverImmediately(
        _ payload: PreparedPastePayload,
        dismiss: () async -> Void,
        playStopSound: Bool
    ) async {
        await dismiss()
        deliveredPayloads.append(payload)
    }

    func copy(_ payload: PreparedPastePayload) -> Bool {
        copiedPayloads.append(payload)
        return true
    }

    func notifyReviewReady() {
        reviewReadyCount += 1
    }
}

struct TranscriptionDeliveryReviewTests {
    @MainActor
    @Test func pasteStagesImmutableReviewWithoutDismissingOrPasting() async throws {
        let service = SpyPasteDeliveryService()
        let delivery = TranscriptionDelivery(pasteDeliveryService: service)
        let transcription = Transcription(
            text: "Raw transcript",
            duration: 1,
            transcriptionStatus: .completed
        )
        var dismissCount = 0
        var stagedReview: PendingPasteReview?

        await delivery.deliver(
            .init(
                transcription: transcription,
                text: "Enhanced transcript",
                output: output(.paste, autoSendKey: .commandEnter),
                enhancementConfiguration: nil,
                responseConfig: nil,
                responseError: nil,
                usedRawEnhancementFallback: false,
                isAssistantFollowUp: false,
                allowsPasteReview: true
            ),
            actions: actions(
                dismiss: { dismissCount += 1 },
                stage: {
                    stagedReview = $0
                    return true
                }
            )
        )

        let review = try #require(stagedReview)
        #expect(review.rawText == "Raw transcript")
        #expect(review.finalText == "Enhanced transcript")
        #expect(review.payload.pastedText == "prepared:Enhanced transcript")
        #expect(review.payload.autoSendKey == .commandEnter)
        #expect(dismissCount == 0)
        #expect(service.deliveredPayloads.isEmpty)
        #expect(service.reviewReadyCount == 1)
    }

    @Test func reviewExpirationUsesTheSnapshottedDeadline() {
        let deadline = Date(timeIntervalSince1970: 1_000)
        let review = PendingPasteReview(
            rawText: "Raw",
            finalText: "Final",
            payload: PreparedPastePayload(
                displayText: "Final",
                pastedText: "Final",
                autoSendKey: .none
            ),
            expiresAt: deadline
        )

        #expect(!review.isExpired(at: deadline.addingTimeInterval(-0.001)))
        #expect(review.isExpired(at: deadline))
        #expect(review.isExpired(at: deadline.addingTimeInterval(0.001)))
    }

    @Test func pendingReviewCanOnlyBeConsumedOnce() {
        var pending: PendingPasteReview? = PendingPasteReview(
            rawText: "Raw",
            finalText: "Final",
            payload: PreparedPastePayload(
                displayText: "Final",
                pastedText: "Final",
                autoSendKey: .none
            )
        )

        #expect(PendingPasteReviewSlot.take(&pending) != nil)
        #expect(PendingPasteReviewSlot.take(&pending) == nil)
    }

    @Test func reviewLifecycleWaitsForBothResolutionAndPipelineCleanup() {
        #expect(
            !PasteReviewLifecycle.canReturnToIdle(
                hasActivePipeline: true,
                isResolvingReview: true
            )
        )
        #expect(
            !PasteReviewLifecycle.canReturnToIdle(
                hasActivePipeline: true,
                isResolvingReview: false
            )
        )
        #expect(
            !PasteReviewLifecycle.canReturnToIdle(
                hasActivePipeline: false,
                isResolvingReview: true
            )
        )
        #expect(
            PasteReviewLifecycle.canReturnToIdle(
                hasActivePipeline: false,
                isResolvingReview: false
            )
        )
    }

    @MainActor
    @Test func unavailableReviewMonitorFallsBackToImmediatePaste() async {
        let service = SpyPasteDeliveryService()
        let delivery = TranscriptionDelivery(pasteDeliveryService: service)
        let transcription = Transcription(
            text: "Raw transcript",
            duration: 1,
            transcriptionStatus: .completed
        )
        var dismissCount = 0

        await delivery.deliver(
            .init(
                transcription: transcription,
                text: "Raw transcript",
                output: output(.paste),
                enhancementConfiguration: nil,
                responseConfig: nil,
                responseError: "backend detail that must not be shown",
                usedRawEnhancementFallback: true,
                isAssistantFollowUp: false,
                allowsPasteReview: false
            ),
            actions: actions(
                dismiss: { dismissCount += 1 },
                stage: { _ in false }
            )
        )

        #expect(dismissCount == 1)
        #expect(service.deliveredPayloads.count == 1)
        #expect(service.reviewReadyCount == 0)
    }

    @MainActor
    @Test func enhancementFailureStagesRawTextWithSanitizedWarning() async throws {
        let service = SpyPasteDeliveryService()
        let delivery = TranscriptionDelivery(pasteDeliveryService: service)
        let transcription = Transcription(
            text: "Usable raw transcript",
            duration: 1,
            enhancedText: "Enhancement failed: sensitive backend response",
            transcriptionStatus: .completed
        )
        var stagedReview: PendingPasteReview?

        await delivery.deliver(
            .init(
                transcription: transcription,
                text: "Usable raw transcript",
                output: output(.paste),
                enhancementConfiguration: nil,
                responseConfig: nil,
                responseError: "sensitive backend response",
                usedRawEnhancementFallback: true,
                isAssistantFollowUp: false,
                allowsPasteReview: true
            ),
            actions: actions(
                dismiss: {},
                stage: {
                    stagedReview = $0
                    return true
                }
            )
        )

        let review = try #require(stagedReview)
        #expect(review.finalText == "Usable raw transcript")
        #expect(review.enhancementWarning != nil)
        #expect(review.enhancementWarning?.contains("sensitive backend response") == false)
        #expect(service.deliveredPayloads.isEmpty)
    }

    @MainActor
    @Test func unavailableConfiguredEnhancementStagesRawFallbackWarning() async throws {
        let service = SpyPasteDeliveryService()
        let delivery = TranscriptionDelivery(pasteDeliveryService: service)
        let transcription = Transcription(
            text: "Raw because the configured connection is unavailable",
            duration: 1,
            transcriptionStatus: .completed
        )
        var stagedReview: PendingPasteReview?

        await delivery.deliver(
            .init(
                transcription: transcription,
                text: transcription.text,
                output: output(.paste),
                enhancementConfiguration: nil,
                responseConfig: nil,
                responseError: nil,
                usedRawEnhancementFallback: true,
                isAssistantFollowUp: false,
                allowsPasteReview: true
            ),
            actions: actions(
                dismiss: {},
                stage: {
                    stagedReview = $0
                    return true
                }
            )
        )

        let review = try #require(stagedReview)
        #expect(review.finalText == transcription.text)
        #expect(review.enhancementWarning != nil)
        #expect(service.deliveredPayloads.isEmpty)
    }

    @MainActor
    @Test func respondRawFallbackAndCustomCommandNeverStageHaloReview() async {
        let service = SpyPasteDeliveryService()
        let delivery = TranscriptionDelivery(pasteDeliveryService: service)
        let transcription = Transcription(
            text: "Raw transcript",
            duration: 1,
            transcriptionStatus: .completed
        )
        var stageCount = 0
        var dismissCount = 0
        let sharedActions = actions(
            dismiss: { dismissCount += 1 },
            stage: { _ in
                stageCount += 1
                return true
            }
        )

        await delivery.deliver(
            .init(
                transcription: transcription,
                text: "Raw transcript",
                output: output(.respond),
                enhancementConfiguration: nil,
                responseConfig: nil,
                responseError: nil,
                usedRawEnhancementFallback: false,
                isAssistantFollowUp: false,
                allowsPasteReview: false
            ),
            actions: sharedActions
        )
        await delivery.deliver(
            .init(
                transcription: transcription,
                text: "Raw transcript",
                output: OutputRuntimeConfiguration(
                    mode: nil,
                    outputMode: .customCommand,
                    autoSendKey: .none,
                    customCommand: ModeCustomCommand()
                ),
                enhancementConfiguration: nil,
                responseConfig: nil,
                responseError: nil,
                usedRawEnhancementFallback: false,
                isAssistantFollowUp: false,
                allowsPasteReview: false
            ),
            actions: sharedActions
        )

        #expect(stageCount == 0)
        #expect(service.deliveredPayloads.count == 1)
        #expect(dismissCount == 2)
    }

    @MainActor
    private func actions(
        dismiss: @escaping () async -> Void,
        stage: @escaping (PendingPasteReview) -> Bool
    ) -> TranscriptionDelivery.Actions {
        .init(
            setState: { _ in },
            dismiss: dismiss,
            sendFollowUp: { _, _ in },
            showResponse: { _, _ in },
            failResponse: { _ in },
            stagePasteReview: stage
        )
    }

    private func output(
        _ mode: ModeOutputMode,
        autoSendKey: AutoSendKey = .none
    ) -> OutputRuntimeConfiguration {
        OutputRuntimeConfiguration(
            mode: nil,
            outputMode: mode,
            autoSendKey: autoSendKey,
            customCommand: nil
        )
    }
}
