import Foundation
import SwiftData
import Testing
@testable import VoiceInk

@MainActor
private final class EngineRefinementService: HaloRefinementServicing {
    enum Behavior {
        case success(String)
        case wrongRequestID(String)
        case wrongBaseRevisionID(String)
        case failure(Error)
        case suspended
    }

    private(set) var requests: [HaloRefinementRequest] = []
    private(set) var cancellationCount = 0
    var behaviors: [Behavior]

    init(behaviors: [Behavior]) {
        self.behaviors = behaviors
    }

    func refine(_ request: HaloRefinementRequest) async throws -> HaloRefinementResult {
        requests.append(request)
        let behavior = behaviors.isEmpty ? .success("Refined") : behaviors.removeFirst()

        switch behavior {
        case .success(let text):
            return HaloRefinementResult(
                requestID: request.requestID,
                baseRevisionID: request.baseRevisionID,
                replacementText: text
            )
        case .wrongRequestID(let text):
            return HaloRefinementResult(
                requestID: UUID(),
                baseRevisionID: request.baseRevisionID,
                replacementText: text
            )
        case .wrongBaseRevisionID(let text):
            return HaloRefinementResult(
                requestID: request.requestID,
                baseRevisionID: UUID(),
                replacementText: text
            )
        case .failure(let error):
            throw error
        case .suspended:
            do {
                try await Task.sleep(for: .seconds(30))
                return HaloRefinementResult(
                    requestID: request.requestID,
                    baseRevisionID: request.baseRevisionID,
                    replacementText: "Too late"
                )
            } catch {
                cancellationCount += 1
                throw error
            }
        }
    }
}

@MainActor
private final class EnginePasteDeliveryService: PasteDeliveryServicing {
    struct PrepareCall: Equatable {
        let text: String
        let autoSendKey: AutoSendKey
    }

    private(set) var prepareCalls: [PrepareCall] = []
    private(set) var deliveryPayloads: [PreparedPastePayload] = []
    private(set) var copyCount = 0
    private(set) var reviewReadyCount = 0
    var outcome: PasteDeliveryOutcome = .commandPosted

    func prepare(text: String, output: OutputRuntimeConfiguration) -> PreparedPastePayload {
        prepareCalls.append(PrepareCall(text: text, autoSendKey: output.autoSendKey))
        return PreparedPastePayload(
            displayText: text,
            pastedText: "licensed:\(text) ",
            autoSendKey: output.autoSendKey
        )
    }

    func deliver(
        _ payload: PreparedPastePayload,
        dismiss: () async -> Void,
        playStopSound: Bool
    ) async -> PasteDeliveryOutcome {
        deliveryPayloads.append(payload)
        await dismiss()
        return outcome
    }

    func deliverImmediately(
        _ payload: PreparedPastePayload,
        dismiss: () async -> Void,
        playStopSound: Bool
    ) async {
        deliveryPayloads.append(payload)
        await dismiss()
    }

    func copy(_ payload: PreparedPastePayload) -> Bool {
        copyCount += 1
        return true
    }

    func notifyReviewReady() {
        reviewReadyCount += 1
    }
}

@MainActor
private final class EngineDestinationService: PasteReviewDestinationServicing {
    func frontmostApplicationSnapshot() -> PasteReviewDestinationSnapshot {
        PasteReviewDestinationSnapshot(
            processID: nil,
            applicationName: nil,
            bundleIdentifier: nil,
            focusedElementIdentity: nil
        )
    }

    func validate(
        _ expected: PasteReviewDestinationSnapshot
    ) async -> PasteReviewDestinationValidation {
        .validationUnavailable
    }
}

@MainActor
private final class SuspendedEngineDestinationService: PasteReviewDestinationServicing {
    private(set) var validationCount = 0
    private var continuation: CheckedContinuation<PasteReviewDestinationValidation, Never>?

    func frontmostApplicationSnapshot() -> PasteReviewDestinationSnapshot {
        PasteReviewDestinationSnapshot(
            processID: 42,
            applicationName: "Destination",
            bundleIdentifier: "com.example.destination",
            focusedElementIdentity: nil
        )
    }

    func validate(
        _ expected: PasteReviewDestinationSnapshot
    ) async -> PasteReviewDestinationValidation {
        validationCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resumeValidation(
        with result: PasteReviewDestinationValidation = .processMatch
    ) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }
}

@MainActor
private final class SequencedEngineDestinationService: PasteReviewDestinationServicing {
    private var validations: [PasteReviewDestinationValidation]

    init(_ validations: [PasteReviewDestinationValidation]) {
        self.validations = validations
    }

    func frontmostApplicationSnapshot() -> PasteReviewDestinationSnapshot {
        PasteReviewDestinationSnapshot(
            processID: 42,
            applicationName: "Destination",
            bundleIdentifier: "com.example.destination",
            focusedElementIdentity: 100
        )
    }

    func validate(
        _ expected: PasteReviewDestinationSnapshot
    ) async -> PasteReviewDestinationValidation {
        validations.isEmpty ? .processMatch : validations.removeFirst()
    }
}

@MainActor
private final class EngineOutcomeRecorder: HaloOutcomeRecording {
    private(set) var counts: [HaloOutcomeMetric: Int] = [:]

    func record(_ metric: HaloOutcomeMetric) {
        counts[metric, default: 0] += 1
    }

    func snapshot() -> HaloOutcomeMetricsSnapshot {
        HaloOutcomeMetricsSnapshot(counts: counts)
    }

    func reset() {
        counts = [:]
    }
}

@MainActor
private final class EngineHaloPresenter: RecorderPanelPresenting, PasteReviewRecoveryPresenting {
    var isRecorderPanelVisible = true
    var isHaloPanelActive = true
    var keyboardHandlingAvailable = true
    private(set) var presentedReviewCount = 0
    private(set) var hiddenForDeliveryCount = 0
    private(set) var clearedReviewCount = 0
    private(set) var focusRecoveryBeginCount = 0
    private(set) var focusRecoveryEndCount = 0

    func dismissRecorderPanel() async {
        isRecorderPanelVisible = false
    }

    func reconcileRecorderPanel(for outputMode: ModeOutputMode) {}
    func preparePasteReviewKeyboardHandling() -> Bool { keyboardHandlingAvailable }
    func finishPasteReviewKeyboardHandling() {}

    func presentPasteReview(_ review: PendingPasteReview) {
        presentedReviewCount += 1
    }

    func clearPasteReview() {
        clearedReviewCount += 1
    }

    func showHaloPasteConfirmation() {}

    func hidePasteReviewForDelivery() {
        hiddenForDeliveryCount += 1
    }

    func restorePasteReviewAfterFailedDelivery() {}

    func beginPasteReviewFocusRecovery() {
        focusRecoveryBeginCount += 1
    }

    func endPasteReviewFocusRecovery() {
        focusRecoveryEndCount += 1
    }
}

@MainActor
struct HaloReviewRefinementEngineTests {
    @Test func keyboardMonitorFailureKeepsMouseOperableReviewInsteadOfPasting() async throws {
        let refinement = EngineRefinementService(behaviors: [])
        let harness = try makeHarness(refinement: refinement)
        harness.presenter.keyboardHandlingAvailable = false

        #expect(harness.engine.stagePasteReview(makeReview(), notifyReady: false))
        #expect(harness.engine.pendingPasteReview != nil)
        #expect(harness.engine.recordingState == .reviewing)
        #expect(harness.paste.deliveryPayloads.isEmpty)
        #expect(harness.outcomes.counts[.reviewShown] == 1)

        await harness.engine.cancelPendingPasteReview()
        #expect(harness.outcomes.counts[.cancel] == 1)
    }

    @Test func riskReviewReasonPreservesSuccessfulInitialEnhancement() async throws {
        let harness = try makeHarness(refinement: EngineRefinementService(behaviors: []))
        let reason = "Review suggested because the result was rewritten substantially."
        #expect(
            harness.engine.stagePasteReview(
                makeReview(deliveryReviewReason: reason),
                notifyReady: false
            )
        )

        #expect(harness.engine.haloReviewState?.session.initialEnhancement == "Initial version")
        #expect(harness.engine.haloReviewState?.session.enhancementWarning == nil)
        #expect(harness.engine.haloReviewState?.session.deliveryReviewReason == reason)
        #expect(harness.outcomes.counts[.reviewShown] == 1)

        await harness.engine.cancelPendingPasteReview()
    }

    @Test func successfulRefinementAppendsExactPayloadAndFinalizesOnlyAfterPaste() async throws {
        let refinement = EngineRefinementService(behaviors: [.success("Clear final version")])
        let harness = try makeHarness(refinement: refinement)
        let transcription = Transcription(
            text: "Raw words",
            duration: 1,
            enhancedText: "Initial version",
            transcriptionStatus: .completed
        )
        let transcriptionID = UUID()
        transcription.id = transcriptionID
        harness.container.mainContext.insert(transcription)
        try harness.container.mainContext.save()

        let review = makeReview(transcriptionID: transcriptionID)
        #expect(harness.engine.stagePasteReview(review, notifyReady: true))
        #expect(harness.engine.beginHaloRefinement(.clearer))
        await waitForRefinement(in: harness.engine)

        let state = try #require(harness.engine.haloReviewState)
        let selected = try #require(state.selectedRevision)
        #expect(state.revisions.count == 2)
        #expect(state.lens == .changes)
        #expect(state.comparisonBaseText == "Initial version")
        #expect(selected.text == "Clear final version")
        #expect(selected.action == .refinement(.clearer))
        #expect(selected.payload.displayText == "Clear final version")
        #expect(selected.payload.pastedText == "licensed:Clear final version ")
        #expect(selected.payload.autoSendKey == .enter)
        #expect(harness.paste.prepareCalls == [
            .init(text: "Clear final version", autoSendKey: .enter)
        ])
        // Refinement must not replay the stop/review-ready sound.
        #expect(harness.paste.reviewReadyCount == 1)
        #expect(transcription.finalizedText == nil)
        #expect(harness.outcomes.counts[.refinementSuccess] == 1)

        let request = try #require(refinement.requests.first)
        #expect(request.rawTranscript == "Raw words")
        #expect(request.selectedRevisionText == "Initial version")
        #expect(request.configuration.provider == .openAI)
        #expect(request.configuration.openAIAuthMode == .oauth)
        #expect(request.configuration.modelName == "gpt-5.6-luna")
        #expect(request.contextSnapshot?.clipboardText == "Frozen clipboard")

        await harness.engine.approvePendingPasteReview()

        #expect(harness.paste.deliveryPayloads == [selected.payload])
        #expect(transcription.finalizedText == "Clear final version")
        #expect(harness.engine.pendingPasteReview == nil)
        #expect(harness.engine.haloReviewState == nil)
        #expect(harness.outcomes.counts[.apply] == 1)

        let metrics = try harness.container.mainContext.fetch(FetchDescriptor<SessionMetric>())
        #expect(metrics.isEmpty)
    }

    @Test func inFlightRefinementRejectsDuplicateAndBlocksReviewDeliveryActions() async throws {
        let refinement = EngineRefinementService(behaviors: [.suspended])
        let harness = try makeHarness(refinement: refinement)
        #expect(harness.engine.stagePasteReview(makeReview(), notifyReady: false))

        #expect(harness.engine.beginHaloRefinement(.shorter))
        #expect(!harness.engine.beginHaloRefinement(.formal))
        #expect(harness.engine.haloReviewState?.isRefining == true)

        harness.engine.copyPendingPasteReview()
        #expect(harness.paste.copyCount == 0)
        #expect(!harness.engine.moveHaloReviewRevision(by: 1))
        await harness.engine.approvePendingPasteReview()
        #expect(harness.paste.deliveryPayloads.isEmpty)

        #expect(harness.engine.cancelHaloRefinementIfActive())
        #expect(harness.engine.pendingPasteReview != nil)
        #expect(harness.engine.recordingState == .reviewing)
        #expect(harness.engine.haloReviewState?.isRefining == false)
        #expect(harness.engine.haloReviewState?.notice == .refinementCancelled)
        await waitForCancellation(in: refinement)

        #expect(!harness.engine.cancelHaloRefinementIfActive())
        await harness.engine.cancelPendingPasteReview()
        #expect(harness.engine.pendingPasteReview == nil)
    }

    @Test func applyDoesNotCrossRefinementStartedDuringDestinationValidation() async throws {
        let destination = SuspendedEngineDestinationService()
        let refinement = EngineRefinementService(behaviors: [.suspended])
        let harness = try makeHarness(
            refinement: refinement,
            destinationService: destination
        )
        #expect(
            harness.engine.stagePasteReview(
                makeReview(destination: destination.frontmostApplicationSnapshot()),
                notifyReady: false
            )
        )

        let applyTask = Task { @MainActor in
            await harness.engine.approvePendingPasteReview()
        }
        await waitForValidation(in: destination)

        #expect(harness.engine.beginHaloRefinement(.shorter))
        destination.resumeValidation()
        await applyTask.value

        #expect(harness.paste.deliveryPayloads.isEmpty)
        #expect(harness.engine.pendingPasteReview != nil)
        #expect(harness.engine.haloReviewState?.isRefining == true)

        #expect(harness.engine.cancelHaloRefinementIfActive())
        await waitForCancellation(in: refinement)
        await harness.engine.cancelPendingPasteReview()
    }

    @Test func applyRequiresAnotherConfirmationAfterRevisionChangesDuringValidation() async throws {
        let destination = SuspendedEngineDestinationService()
        let refinement = EngineRefinementService(behaviors: [.success("New revision")])
        let harness = try makeHarness(
            refinement: refinement,
            destinationService: destination
        )
        #expect(
            harness.engine.stagePasteReview(
                makeReview(destination: destination.frontmostApplicationSnapshot()),
                notifyReady: false
            )
        )
        let initiallySelectedID = try #require(
            harness.engine.haloReviewState?.selectedRevision?.id
        )

        let applyTask = Task { @MainActor in
            await harness.engine.approvePendingPasteReview()
        }
        await waitForValidation(in: destination)

        #expect(harness.engine.beginHaloRefinement(.clearer))
        await waitForRefinement(in: harness.engine)
        let revisedID = try #require(
            harness.engine.haloReviewState?.selectedRevision?.id
        )
        #expect(revisedID != initiallySelectedID)

        destination.resumeValidation()
        await applyTask.value

        #expect(harness.paste.deliveryPayloads.isEmpty)
        #expect(harness.engine.pendingPasteReview != nil)
        #expect(harness.engine.haloReviewState?.selectedRevision?.id == revisedID)

        await harness.engine.cancelPendingPasteReview()
    }

    @Test func elapsedDeadlineRejectsRefinementBeforeTimerPublishesExpiry() async throws {
        let refinement = EngineRefinementService(behaviors: [.success("Too late")])
        let harness = try makeHarness(refinement: refinement)
        #expect(harness.engine.stagePasteReview(makeReview(), notifyReady: false))
        let state = try #require(harness.engine.haloReviewState)
        let afterDeadline = state.expiresAt.addingTimeInterval(0.001)

        #expect(!harness.engine.beginHaloRefinement(.formal, at: afterDeadline))
        #expect(refinement.requests.isEmpty)
        #expect(harness.engine.haloReviewState?.isExpired == true)
        #expect(harness.engine.haloReviewState?.isRefining == false)
        #expect(harness.engine.pasteReviewSecondsRemaining == 0)

        await harness.engine.cancelPendingPasteReview()
    }

    @Test func emptyUnchangedAndSanitizedFailurePreserveCurrentRevision() async throws {
        let refinement = EngineRefinementService(
            behaviors: [
                .success("Initial version"),
                .success("  \n"),
                .failure(EnhancementError.customError("HTTP 503 token=secret-state")),
            ]
        )
        let harness = try makeHarness(refinement: refinement)
        #expect(harness.engine.stagePasteReview(makeReview(), notifyReady: false))

        #expect(harness.engine.beginHaloRefinement(.clearer))
        await waitForRefinement(in: harness.engine)
        #expect(harness.engine.haloReviewState?.revisions.count == 1)
        #expect(harness.engine.haloReviewState?.notice == .unchangedRefinement)

        #expect(harness.engine.beginHaloRefinement(.shorter))
        await waitForRefinement(in: harness.engine)
        #expect(harness.engine.haloReviewState?.revisions.count == 1)
        #expect(harness.engine.haloReviewState?.notice == .emptyRefinement)

        #expect(harness.engine.beginHaloRefinement(.formal))
        await waitForRefinement(in: harness.engine)
        let failureState = try #require(harness.engine.haloReviewState)
        #expect(failureState.revisions.count == 1)
        guard case .refinementFailed(let message) = failureState.notice else {
            Issue.record("Expected a sanitized refinement failure")
            return
        }
        #expect(!message.contains("secret-state"))
        #expect(failureState.secondsRemaining() > 115)
        #expect(harness.outcomes.counts[.refinementFailure] == 3)
    }

    @Test func mismatchedServiceResultIDsFailExpectedRequestWithoutStrandingReview() async throws {
        let refinement = EngineRefinementService(
            behaviors: [
                .wrongRequestID("Wrong request"),
                .wrongBaseRevisionID("Wrong base"),
            ]
        )
        let harness = try makeHarness(refinement: refinement)
        #expect(harness.engine.stagePasteReview(makeReview(), notifyReady: false))

        #expect(harness.engine.beginHaloRefinement(.clearer))
        await waitForRefinement(in: harness.engine)
        assertMalformedResultWasRejected(in: harness.engine)

        // A second refinement proves the first task handle and reducer request
        // were both released rather than leaving the review permanently busy.
        #expect(harness.engine.beginHaloRefinement(.formal))
        await waitForRefinement(in: harness.engine)
        assertMalformedResultWasRejected(in: harness.engine)

        #expect(refinement.requests.count == 2)
        #expect(harness.paste.prepareCalls.isEmpty)
        #expect(harness.outcomes.counts[.refinementFailure] == 2)
        await harness.engine.cancelPendingPasteReview()
    }

    @Test func reviewTeardownCancelsRequestAndRejectsItsLateCompletion() async throws {
        let refinement = EngineRefinementService(behaviors: [.suspended])
        let harness = try makeHarness(refinement: refinement)
        #expect(harness.engine.stagePasteReview(makeReview(), notifyReady: false))
        #expect(harness.engine.beginHaloRefinement(.friendlier))

        await harness.engine.cancelPendingPasteReview()
        await waitForCancellation(in: refinement)

        #expect(refinement.cancellationCount == 1)
        #expect(harness.engine.pendingPasteReview == nil)
        #expect(harness.engine.haloReviewState == nil)
        #expect(harness.paste.deliveryPayloads.isEmpty)
        #expect(harness.outcomes.counts[.cancel] == 1)
        #expect(harness.outcomes.counts[.refinementFailure, default: 0] == 0)
    }

    @Test func mismatchRefocusRevalidatesBeforeASeparateApply() async throws {
        let mismatch = PasteReviewDestinationValidation.mismatch(
            PasteReviewDestinationMismatch(
                expectedApplicationName: "Destination",
                currentApplicationName: "Destination",
                reason: .stableElementChanged
            )
        )
        let destination = SequencedEngineDestinationService([
            mismatch,
            .stableElementMatch,
            .stableElementMatch,
        ])
        let harness = try makeHarness(
            refinement: EngineRefinementService(behaviors: []),
            destinationService: destination
        )
        #expect(
            harness.engine.stagePasteReview(
                makeReview(destination: destination.frontmostApplicationSnapshot()),
                notifyReady: false
            )
        )

        await harness.engine.approvePendingPasteReview()
        #expect(harness.engine.pasteReviewFeedback?.allowsRefocus == true)
        #expect(harness.paste.deliveryPayloads.isEmpty)
        #expect(harness.outcomes.counts[.destinationMismatch] == 1)

        #expect(harness.engine.beginPasteReviewFocusRecovery())
        #expect(harness.engine.isPasteReviewRefocusing)
        #expect(harness.presenter.focusRecoveryBeginCount == 1)

        // Return while collapsed only revalidates and restores the review.
        await harness.engine.approvePendingPasteReview()
        #expect(!harness.engine.isPasteReviewRefocusing)
        #expect(harness.engine.pasteReviewFeedback == nil)
        #expect(harness.presenter.focusRecoveryEndCount == 1)
        #expect(harness.paste.deliveryPayloads.isEmpty)
        #expect(harness.outcomes.counts[.destinationMismatch] == 1)

        await harness.engine.approvePendingPasteReview()
        #expect(harness.paste.deliveryPayloads.count == 1)
        #expect(harness.engine.pendingPasteReview == nil)
        #expect(harness.outcomes.counts[.apply] == 1)
    }

    @Test func copyAndExpiryRecordIndependentOutcomes() async throws {
        let harness = try makeHarness(refinement: EngineRefinementService(behaviors: []))
        #expect(harness.engine.stagePasteReview(makeReview(), notifyReady: false))

        harness.engine.copyPendingPasteReview()
        #expect(harness.paste.copyCount == 1)
        #expect(harness.outcomes.counts[.copy] == 1)

        await harness.engine.cancelPendingPasteReview(reason: .expiry)
        #expect(harness.engine.pendingPasteReview == nil)
        #expect(harness.outcomes.counts[.expiry] == 1)
        #expect(harness.outcomes.counts[.cancel, default: 0] == 0)
    }

    @Test func failedPasteRetryRecordsRetryAndOnlySuccessfulApply() async throws {
        let harness = try makeHarness(refinement: EngineRefinementService(behaviors: []))
        #expect(harness.engine.stagePasteReview(makeReview(), notifyReady: false))
        harness.paste.outcome = .commandNotPosted

        await harness.engine.approvePendingPasteReview()
        #expect(harness.engine.pasteReviewFeedback == .pasteFailed)
        #expect(harness.engine.pendingPasteReview != nil)
        #expect(harness.outcomes.counts[.apply, default: 0] == 0)

        harness.paste.outcome = .commandPosted
        await harness.engine.retryPendingPasteReview()

        #expect(harness.engine.pendingPasteReview == nil)
        #expect(harness.paste.deliveryPayloads.count == 2)
        #expect(harness.outcomes.counts[.retry] == 1)
        #expect(harness.outcomes.counts[.apply] == 1)
    }

    @Test func useOriginalAndManualEditPrepareExactImmutablePayloads() async throws {
        let harness = try makeHarness(refinement: EngineRefinementService(behaviors: []))
        let transcriptionID = UUID()
        let transcription = Transcription(
            text: "Raw words",
            duration: 1,
            enhancedText: "Initial version",
            transcriptionStatus: .completed
        )
        transcription.id = transcriptionID
        harness.container.mainContext.insert(transcription)
        try harness.container.mainContext.save()
        #expect(
            harness.engine.stagePasteReview(
                makeReview(transcriptionID: transcriptionID),
                notifyReady: false
            )
        )

        #expect(harness.engine.useOriginalHaloReview())
        let original = try #require(harness.engine.haloReviewState?.selectedRevision)
        #expect(original.action == .original)
        #expect(original.text == "Raw words")
        #expect(original.payload.pastedText == "licensed:Raw words ")

        #expect(harness.engine.beginHaloManualEdit())
        #expect(harness.engine.updateHaloManualEdit("Hand edited result"))
        #expect(harness.engine.saveHaloManualEdit())
        let edited = try #require(harness.engine.haloReviewState?.selectedRevision)
        #expect(edited.action == .manualEdit)
        #expect(edited.payload.pastedText == "licensed:Hand edited result ")
        #expect(harness.outcomes.counts[.useOriginal] == 1)
        #expect(harness.outcomes.counts[.manualEdit] == 1)

        await harness.engine.approvePendingPasteReview()
        #expect(harness.paste.deliveryPayloads == [edited.payload])
        #expect(transcription.finalizedText == "Hand edited result")
        #expect(harness.outcomes.counts[.apply] == 1)
    }

    private struct Harness {
        let container: ModelContainer
        let engine: VoiceInkEngine
        let paste: EnginePasteDeliveryService
        let presenter: EngineHaloPresenter
        let outcomes: EngineOutcomeRecorder
    }

    private func makeHarness(
        refinement: EngineRefinementService,
        destinationService: (any PasteReviewDestinationServicing)? = nil
    ) throws -> Harness {
        let schema = Schema([
            Transcription.self,
            VocabularyWord.self,
            WordReplacement.self,
            SessionMetric.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let modelsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInk-HR2-\(UUID().uuidString)")
        let whisper = WhisperModelManager(modelsDirectory: modelsDirectory)
        let fluidAudio = FluidAudioModelManager()
        let transcriptionModels = TranscriptionModelManager(
            whisperModelManager: whisper,
            fluidAudioModelManager: fluidAudio
        )
        let paste = EnginePasteDeliveryService()
        let presenter = EngineHaloPresenter()
        let outcomes = EngineOutcomeRecorder()
        let engine = VoiceInkEngine(
            modelContext: container.mainContext,
            whisperModelManager: whisper,
            transcriptionModelManager: transcriptionModels,
            enhancementService: nil,
            pasteDeliveryService: paste,
            pasteReviewDestinationService: destinationService ?? EngineDestinationService(),
            haloRefinementService: refinement,
            haloOutcomeRecorder: outcomes
        )
        engine.recorderUIManager = presenter
        return Harness(
            container: container,
            engine: engine,
            paste: paste,
            presenter: presenter,
            outcomes: outcomes
        )
    }

    private func makeReview(
        transcriptionID: UUID = UUID(),
        destination: PasteReviewDestinationSnapshot? = nil,
        deliveryReviewReason: String? = nil
    ) -> PendingPasteReview {
        let prompt = CustomPrompt(
            title: "Voice Dictation",
            promptText: "Keep every material fact.",
            useSystemInstructions: false
        )
        let output = OutputRuntimeConfiguration(
            mode: nil,
            outputMode: .paste,
            haloDeliveryPolicy: .alwaysReview,
            autoSendKey: .enter,
            customCommand: nil
        )
        let configuration = EnhancementRuntimeConfiguration(
            mode: nil,
            isEnabled: true,
            prompt: prompt,
            provider: .openAI,
            modelName: "gpt-5.6-luna",
            openAIAuthMode: .oauth,
            useClipboardContext: true,
            useSelectedTextContext: true,
            useScreenCaptureContext: true
        )
        return PendingPasteReview(
            transcriptionID: transcriptionID,
            rawText: "Raw words",
            finalText: "Initial version",
            payload: PreparedPastePayload(
                displayText: "Initial version",
                pastedText: "Initial version",
                autoSendKey: .enter
            ),
            modeName: "Voice Dictation",
            providerLabel: "OpenAI",
            connectionLabel: "ChatGPT Subscription (OAuth)",
            modelLabel: "gpt-5.6-luna",
            deliveryReviewReason: deliveryReviewReason,
            output: output,
            enhancementConfiguration: configuration,
            frozenContext: RecordingContextSnapshot(
                selectedText: "Frozen selection",
                clipboardText: "Frozen clipboard",
                screenText: "Frozen screen"
            ),
            destination: destination
        )
    }

    private func assertMalformedResultWasRejected(in engine: VoiceInkEngine) {
        #expect(engine.haloReviewState?.isRefining == false)
        #expect(engine.haloReviewState?.revisions.count == 1)
        guard case .refinementFailed(let message) = engine.haloReviewState?.notice else {
            Issue.record("Expected malformed refinement result feedback")
            return
        }
        #expect(message == HaloRefinementError.malformedResponse.errorDescription)
    }

    private func waitForRefinement(in engine: VoiceInkEngine) async {
        for _ in 0..<200 {
            if engine.haloReviewState?.isRefining != true {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Refinement did not finish")
    }

    private func waitForCancellation(in service: EngineRefinementService) async {
        for _ in 0..<200 {
            if service.cancellationCount > 0 {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Refinement task was not cancelled")
    }

    private func waitForValidation(
        in service: SuspendedEngineDestinationService
    ) async {
        for _ in 0..<200 {
            if service.validationCount > 0 {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Destination validation did not start")
    }
}
