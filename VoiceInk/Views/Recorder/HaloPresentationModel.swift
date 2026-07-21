import Combine
import Foundation

enum HaloPresentationPhase: Equatable, Sendable {
    case listening
    case transcribing
    case enhancing
    case reviewing
    case confirmed
    case noSpeechDetected

    static func resolve(recordingState: RecordingState) -> HaloPresentationPhase {
        switch recordingState {
        case .idle, .starting, .recording:
            return .listening
        case .transcribing, .busy:
            return .transcribing
        case .enhancing:
            return .enhancing
        case .reviewing:
            return .reviewing
        }
    }
}

struct HaloPresentationMetadata: Equatable, Sendable {
    var applicationName: String?
    var modeName: String?
    var contextLabels: [String]
    var providerLabel: String?
    var connectionLabel: String?
    var modelLabel: String?

    init(
        applicationName: String? = nil,
        modeName: String? = nil,
        contextLabels: [String] = [],
        providerLabel: String? = nil,
        connectionLabel: String? = nil,
        modelLabel: String? = nil
    ) {
        self.applicationName = applicationName
        self.modeName = modeName
        self.contextLabels = contextLabels
        self.providerLabel = providerLabel
        self.connectionLabel = connectionLabel
        self.modelLabel = modelLabel
    }
}

struct HaloReviewPresentation: Equatable, Sendable {
    let rawText: String
    let finalText: String
    let enhancementWarning: String?
    let deliveryReviewReason: String?

    var showsRawText: Bool {
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !raw.isEmpty && raw != final
    }
}

/// Stable identity for the text currently occupying the review viewport.
/// SwiftUI can use this value to recreate its scroll position whenever the
/// selected revision or lens changes, without reacting to countdown updates.
struct HaloReviewViewportIdentity: Equatable, Hashable, Sendable {
    let sessionID: UUID
    let revisionID: UUID
    let lens: HaloReviewLens
}

enum HaloReviewNoticeTone: Equatable, Sendable {
    case neutral
    case warning
}

/// A review-state projection that is safe for presentation code. The source
/// `HaloReviewState` also owns destination, prepared paste, and frozen context
/// data; none of those implementation details should reach the view layer.
private struct HaloReviewPresentationSnapshot: Equatable, Sendable {
    let sessionID: UUID
    let revisionID: UUID
    let selectedRevisionText: String
    let originalText: String
    let comparisonBaseText: String
    let selectedRevisionIndex: Int
    let revisionCount: Int
    let lens: HaloReviewLens
    let selectedRevisionAction: HaloReviewRevisionAction
    let canRefine: Bool
    let isRefining: Bool
    let voiceRefinementPhase: HaloVoiceRefinementPhase
    let canStartVoiceRefinement: Bool
    let canStartTypedRefinement: Bool
    let isEditingManually: Bool
    let manualEditText: String?
    let canUseOriginal: Bool
    let canBeginManualEdit: Bool
    let activeRefinementAction: HaloRefinementAction?
    let hasReachedRevisionLimit: Bool
    let noticeMessage: String?
    let noticeTone: HaloReviewNoticeTone?
    let enhancementWarning: String?
    let deliveryReviewReason: String?

    var canMovePrevious: Bool {
        !isRefining && !voiceRefinementPhase.isActive && !isEditingManually
            && selectedRevisionIndex > 0
    }

    var canMoveNext: Bool {
        !isRefining && !voiceRefinementPhase.isActive && !isEditingManually
            && selectedRevisionIndex + 1 < revisionCount
    }

    var viewportIdentity: HaloReviewViewportIdentity {
        HaloReviewViewportIdentity(
            sessionID: sessionID,
            revisionID: revisionID,
            lens: lens
        )
    }

    var diffRequestKey: HaloReviewDiffRequestKey {
        HaloReviewDiffRequestKey(
            sessionID: sessionID,
            revisionID: revisionID,
            original: comparisonBaseText,
            revised: selectedRevisionText
        )
    }
}

/// UI-only state for the Halo. It deliberately contains labels instead of
/// provider objects or credentials, which keeps its chips read-only and safe.
@MainActor
final class HaloPresentationModel: ObservableObject {
    typealias ReviewDiffComputer = @Sendable (
        _ original: String,
        _ revised: String
    ) async -> HaloReviewDiffResult

    @Published private(set) var phase: HaloPresentationPhase = .listening
    @Published private(set) var metadata = HaloPresentationMetadata()
    @Published private(set) var review: HaloReviewPresentation?
    @Published private(set) var reviewFeedback: PasteReviewFeedback?
    @Published private(set) var reviewSecondsRemaining: Int?
    @Published private(set) var isReviewDelivering = false
    @Published private(set) var isReviewRefocusing = false
    @Published private(set) var deliveryOverride: HaloSessionDeliveryOverride?
    @Published private(set) var diffResult: HaloReviewDiffResult?
    @Published private(set) var isComputingDiff = false
    @Published private(set) var isVoiceRefinementReady = false
    @Published private(set) var voiceInstructionAudioMeter = AudioMeter(
        averagePower: 0,
        peakPower: 0
    )
    @Published private(set) var voiceInstructionPartialTranscript = ""
    @Published private(set) var voiceCommandConfirmation: HaloVoiceCommandConfirmation?
    @Published private(set) var capabilitySnapshot = HaloCapabilityStore.recommendedDefaults

    @Published private var reviewSnapshot: HaloReviewPresentationSnapshot?

    private let reviewDiffComputer: ReviewDiffComputer
    private var reviewDiffTask: Task<Void, Never>?
    private var reviewDiffRequestGate = HaloReviewDiffRequestGate()
    private var completedDiffKey: HaloReviewDiffRequestKey?
    private var completedDiffResult: HaloReviewDiffResult?

    init(
        reviewDiffComputer: @escaping ReviewDiffComputer = { original, revised in
            HaloReviewDiffEngine.compare(original: original, revised: revised)
        }
    ) {
        self.reviewDiffComputer = reviewDiffComputer
    }

    var reviewLens: HaloReviewLens {
        reviewSnapshot?.lens ?? .final
    }

    var selectedRevisionText: String {
        reviewSnapshot?.selectedRevisionText ?? review?.finalText ?? ""
    }

    var originalText: String {
        reviewSnapshot?.originalText ?? review?.rawText ?? ""
    }

    var comparisonBaseText: String {
        reviewSnapshot?.comparisonBaseText ?? originalText
    }

    /// Zero-based index of the selected revision. It is zero when no review is
    /// active so view code can render `index + 1` without optional arithmetic.
    var selectedRevisionIndex: Int {
        reviewSnapshot?.selectedRevisionIndex ?? 0
    }

    var revisionCount: Int {
        reviewSnapshot?.revisionCount ?? (review == nil ? 0 : 1)
    }

    var canMovePrevious: Bool {
        reviewSnapshot?.canMovePrevious ?? false
    }

    var canMoveNext: Bool {
        reviewSnapshot?.canMoveNext ?? false
    }

    var reviewViewportIdentity: HaloReviewViewportIdentity? {
        reviewSnapshot?.viewportIdentity
    }

    var selectedRevisionAction: HaloReviewRevisionAction? {
        reviewSnapshot?.selectedRevisionAction
    }

    var canRefine: Bool {
        reviewSnapshot?.canRefine ?? false
    }

    var isRefining: Bool {
        reviewSnapshot?.isRefining ?? false
    }

    var voiceRefinementPhase: HaloVoiceRefinementPhase {
        reviewSnapshot?.voiceRefinementPhase ?? .idle
    }

    var isVoiceRefinementActive: Bool {
        voiceRefinementPhase.isActive
    }

    var isVoiceRefinementListening: Bool {
        if case .listening = voiceRefinementPhase {
            return true
        }
        return false
    }

    var isAwaitingInstructionConfirmation: Bool {
        if case .awaitingConfirmation = voiceRefinementPhase { return true }
        return false
    }

    var isEditingInstruction: Bool {
        if case .editingInstruction = voiceRefinementPhase { return true }
        return false
    }

    var instructionDraftText: String {
        voiceRefinementPhase.instructionDraft?.text ?? ""
    }

    var instructionDraftRequestID: UUID? {
        voiceRefinementPhase.instructionDraft?.requestID
    }

    var instructionDraftSource: HaloInstructionSource? {
        voiceRefinementPhase.instructionDraft?.source
    }

    var canSubmitInstructionDraft: Bool {
        let normalized = instructionDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty
            && normalized.count <= HaloFreeformRefinementDirective.maximumCharacterCount
    }

    var canStartVoiceRefinement: Bool {
        guard isVoiceRefinementReady,
            voiceCommandConfirmation == nil,
            let reviewSnapshot,
            reviewSnapshot.canStartVoiceRefinement
        else {
            return false
        }
        if capabilitySnapshot.voiceCommandsEnabled {
            return true
        }
        return capabilitySnapshot.spokenRefinementEnabled && reviewSnapshot.canRefine
    }

    var isVoiceCommandConfirmationActive: Bool {
        voiceCommandConfirmation != nil
    }

    var canStartTypedRefinement: Bool {
        capabilitySnapshot.typedRefinementEnabled
            && (reviewSnapshot?.canStartTypedRefinement ?? false)
    }

    var isReviewOperationActive: Bool {
        isRefining || isVoiceRefinementActive
    }

    var activeRefinementAction: HaloRefinementAction? {
        reviewSnapshot?.activeRefinementAction
    }

    var isEditingManually: Bool {
        reviewSnapshot?.isEditingManually ?? false
    }

    var isTextEntryActive: Bool {
        isEditingManually || isEditingInstruction
    }

    var manualEditText: String {
        reviewSnapshot?.manualEditText ?? selectedRevisionText
    }

    var canUseOriginal: Bool {
        reviewSnapshot?.canUseOriginal ?? false
    }

    var canBeginManualEdit: Bool {
        reviewSnapshot?.canBeginManualEdit ?? false
    }

    var hasReachedRevisionLimit: Bool {
        reviewSnapshot?.hasReachedRevisionLimit ?? false
    }

    var reviewNoticeMessage: String? {
        reviewSnapshot?.noticeMessage
    }

    var reviewNoticeTone: HaloReviewNoticeTone? {
        reviewSnapshot?.noticeTone
    }

    func setPhase(_ phase: HaloPresentationPhase) {
        self.phase = phase
        if phase != .reviewing {
            clearReview()
        }
    }

    func setCapturedApplication(_ applicationName: String?) {
        metadata.applicationName = applicationName
    }

    func updateDeliveryOverride(_ deliveryOverride: HaloSessionDeliveryOverride?) {
        self.deliveryOverride = deliveryOverride
    }

    func presentPasteConfirmation() {
        clearReview()
        deliveryOverride = nil
        phase = .confirmed
    }

    func presentNoSpeechDetected() {
        clearReview()
        deliveryOverride = nil
        phase = .noSpeechDetected
    }

    func updateMetadata(_ updated: HaloPresentationMetadata) {
        let capturedApplication = metadata.applicationName
        metadata = updated
        if metadata.applicationName == nil {
            metadata.applicationName = capturedApplication
        }
    }

    func presentReview(
        rawText: String,
        finalText: String,
        modeName: String?,
        providerLabel: String?,
        connectionLabel: String?,
        modelLabel: String?,
        enhancementWarning: String?,
        deliveryReviewReason: String? = nil
    ) {
        metadata.modeName = modeName ?? metadata.modeName
        metadata.providerLabel = providerLabel ?? metadata.providerLabel
        metadata.connectionLabel = connectionLabel ?? metadata.connectionLabel
        metadata.modelLabel = modelLabel ?? metadata.modelLabel
        review = HaloReviewPresentation(
            rawText: rawText,
            finalText: finalText,
            enhancementWarning: enhancementWarning,
            deliveryReviewReason: deliveryReviewReason
        )
        phase = .reviewing
    }

    /// Projects the reducer-owned review state into presentation-only values.
    /// The diff key deliberately excludes expiry/countdown data, so periodic
    /// status refreshes cannot restart an in-flight or completed comparison.
    func updateReviewState(_ state: HaloReviewState?) {
        guard let state, let selectedRevision = state.selectedRevision else {
            clearReview()
            return
        }

        let selectedIndex = state.selectedRevisionIndex ?? 0
        let hasReachedRevisionLimit = state.revisions.count >= HaloReviewState.maximumRevisionCount
        let notice = reviewNoticePresentation(
            state.notice,
            hasReachedRevisionLimit: hasReachedRevisionLimit
        )
        let snapshot = HaloReviewPresentationSnapshot(
            sessionID: state.session.id,
            revisionID: selectedRevision.id,
            selectedRevisionText: selectedRevision.text,
            originalText: state.session.rawText,
            comparisonBaseText: state.comparisonBaseText,
            selectedRevisionIndex: selectedIndex,
            revisionCount: state.revisions.count,
            lens: state.lens,
            selectedRevisionAction: selectedRevision.action,
            canRefine: state.canRefine
                && state.session.enhancementConfiguration != nil
                && state.session.refinementInputSnapshot != nil,
            isRefining: state.isRefining,
            voiceRefinementPhase: state.voiceRefinementPhase,
            canStartVoiceRefinement: !state.isExpired
                && !state.isReviewOperationActive
                && state.session.transcriptionConfiguration != nil,
            canStartTypedRefinement: state.canRefine
                && state.session.enhancementConfiguration != nil
                && state.session.refinementInputSnapshot != nil,
            isEditingManually: state.isEditingManually,
            manualEditText: state.manualEdit?.text,
            canUseOriginal: !state.isExpired
                && !state.isRefining
                && !state.isVoiceRefinementActive
                && !state.isEditingManually
                && selectedRevision.text != state.session.rawText
                && (state.revisions.contains(where: { $0.action == .original })
                    || state.revisions.count < HaloReviewState.maximumRevisionCount),
            canBeginManualEdit: !state.isExpired
                && !state.isRefining
                && !state.isVoiceRefinementActive
                && !state.isEditingManually
                && state.revisions.count < HaloReviewState.maximumRevisionCount,
            activeRefinementAction: state.refinementRequest?.action,
            hasReachedRevisionLimit: hasReachedRevisionLimit,
            noticeMessage: notice.message,
            noticeTone: notice.tone,
            enhancementWarning: state.session.enhancementWarning,
            deliveryReviewReason: state.session.deliveryReviewReason
        )

        if reviewSnapshot != snapshot {
            reviewSnapshot = snapshot
        }

        let updatedReview = HaloReviewPresentation(
            rawText: snapshot.originalText,
            finalText: snapshot.selectedRevisionText,
            enhancementWarning: snapshot.enhancementWarning,
            deliveryReviewReason: snapshot.deliveryReviewReason
        )
        if review != updatedReview {
            review = updatedReview
        }

        metadata.modeName = state.session.metadata.modeName ?? metadata.modeName
        metadata.providerLabel = state.session.metadata.providerLabel ?? metadata.providerLabel
        metadata.connectionLabel = state.session.metadata.connectionLabel ?? metadata.connectionLabel
        metadata.modelLabel = state.session.metadata.modelLabel ?? metadata.modelLabel
        phase = .reviewing

        updateDiff(for: snapshot)
    }

    func clearReview() {
        cancelReviewDiff(clearCache: true)
        reviewSnapshot = nil
        review = nil
        reviewFeedback = nil
        reviewSecondsRemaining = nil
        isReviewDelivering = false
        isReviewRefocusing = false
        isVoiceRefinementReady = false
        voiceInstructionAudioMeter = AudioMeter(averagePower: 0, peakPower: 0)
        voiceInstructionPartialTranscript = ""
        voiceCommandConfirmation = nil
    }

    func updateFocusRecovery(isRefocusing: Bool) {
        isReviewRefocusing = isRefocusing
    }

    func updateVoiceRefinementPresentation(
        isReady: Bool,
        audioMeter: AudioMeter,
        partialTranscript: String
    ) {
        isVoiceRefinementReady = isReady
        voiceInstructionAudioMeter = audioMeter
        voiceInstructionPartialTranscript = partialTranscript
    }

    func updateVoiceCommandConfirmation(
        _ confirmation: HaloVoiceCommandConfirmation?
    ) {
        voiceCommandConfirmation = confirmation
    }

    func updateCapabilities(_ snapshot: HaloCapabilitySnapshot) {
        capabilitySnapshot = snapshot
    }

    func updateReviewStatus(
        feedback: PasteReviewFeedback?,
        secondsRemaining: Int?,
        isDelivering: Bool
    ) {
        reviewFeedback = feedback
        reviewSecondsRemaining = secondsRemaining
        isReviewDelivering = isDelivering
    }

    func reset() {
        cancelReviewDiff(clearCache: true)
        phase = .listening
        metadata = HaloPresentationMetadata()
        review = nil
        reviewFeedback = nil
        reviewSecondsRemaining = nil
        isReviewDelivering = false
        isReviewRefocusing = false
        isVoiceRefinementReady = false
        voiceInstructionAudioMeter = AudioMeter(averagePower: 0, peakPower: 0)
        voiceInstructionPartialTranscript = ""
        voiceCommandConfirmation = nil
        deliveryOverride = nil
        reviewSnapshot = nil
    }

    private func updateDiff(for snapshot: HaloReviewPresentationSnapshot) {
        guard snapshot.lens == .changes else {
            cancelReviewDiff(clearCache: false)
            diffResult = nil
            return
        }

        let key = snapshot.diffRequestKey
        if completedDiffKey == key, let completedDiffResult {
            cancelReviewDiff(clearCache: false)
            if diffResult != completedDiffResult {
                diffResult = completedDiffResult
            }
            return
        }

        // A reducer update may only refresh a notice or inactivity deadline.
        // Keep the current background work when its text identity is unchanged.
        if reviewDiffRequestGate.activeKey == key, reviewDiffTask != nil {
            return
        }

        cancelReviewDiff(clearCache: false)
        let requestID = reviewDiffRequestGate.begin(key)
        isComputingDiff = true
        diffResult = nil
        let computer = reviewDiffComputer

        reviewDiffTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let result = await computer(key.original, key.revised)
            guard !Task.isCancelled else { return }
            await self?.acceptDiffResult(
                result,
                requestID: requestID,
                key: key
            )
        }
    }

    private func acceptDiffResult(
        _ result: HaloReviewDiffResult,
        requestID: UUID,
        key: HaloReviewDiffRequestKey
    ) {
        guard reviewDiffRequestGate.accepts(requestID: requestID, key: key),
            reviewSnapshot?.lens == .changes,
            reviewSnapshot?.diffRequestKey == key
        else {
            return
        }

        reviewDiffTask = nil
        reviewDiffRequestGate.invalidate()
        completedDiffKey = key
        completedDiffResult = result
        diffResult = result
        isComputingDiff = false
    }

    private func cancelReviewDiff(clearCache: Bool) {
        reviewDiffTask?.cancel()
        reviewDiffTask = nil
        reviewDiffRequestGate.invalidate()
        isComputingDiff = false

        if clearCache {
            completedDiffKey = nil
            completedDiffResult = nil
            diffResult = nil
        }
    }

    private func reviewNoticePresentation(
        _ notice: HaloReviewNotice?,
        hasReachedRevisionLimit: Bool
    ) -> (message: String?, tone: HaloReviewNoticeTone?) {
        switch notice {
        case .emptyRefinement, .unchangedRefinement, .refinementCancelled,
            .emptyManualEdit, .unchangedManualEdit, .voiceRefinementCancelled:
            return (notice?.message, .neutral)
        case .refinementFailed, .revisionLimitReached, .voiceRefinementFailed,
            .instructionValidation:
            return (notice?.message, .warning)
        case .copied, .copyFailed, nil:
            if hasReachedRevisionLimit {
                return (
                    HaloReviewNotice.revisionLimitReached.message,
                    .warning
                )
            }
            // Copy feedback already has a dedicated presentation lane. Avoid
            // repeating the same outcome as a reducer notice.
            return (nil, nil)
        }
    }
}
