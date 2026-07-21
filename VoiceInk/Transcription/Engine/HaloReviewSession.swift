import Foundation

enum HaloReviewLens: String, CaseIterable, Equatable, Identifiable, Sendable {
    case final
    case changes
    case original

    var id: Self { self }

    var displayName: String {
        switch self {
        case .final:
            return String(localized: "Final")
        case .changes:
            return String(localized: "Changes")
        case .original:
            return String(localized: "Original")
        }
    }
}

enum HaloRefinementAction: String, CaseIterable, Equatable, Identifiable, Sendable {
    case shorter
    case clearer
    case friendlier
    case formal
    case fixTerms

    var id: Self { self }

    var displayName: String {
        switch self {
        case .shorter:
            return String(localized: "Shorter")
        case .clearer:
            return String(localized: "Clearer")
        case .friendlier:
            return String(localized: "Friendlier")
        case .formal:
            return String(localized: "Formal")
        case .fixTerms:
            return String(localized: "Fix terms")
        }
    }

    var instruction: String {
        switch self {
        case .shorter:
            return "Make the result more concise while preserving every important fact and intent."
        case .clearer:
            return "Improve clarity, structure, and readability without changing the meaning."
        case .friendlier:
            return "Use a warmer, more approachable tone without adding claims or excessive enthusiasm."
        case .formal:
            return "Use a polished, professional tone while preserving the speaker's meaning."
        case .fixTerms:
            return "Correct names, acronyms, product terms, and technical vocabulary using the supplied context and vocabulary."
        }
    }
}

enum HaloReviewRevisionAction: Equatable, Sendable {
    case initial
    case refinement(HaloRefinementAction)
    /// A voice-directed replacement. The recognized instruction is
    /// intentionally not retained in revision metadata.
    case voiceRefinement
    case typedRefinement
    case anotherTake
    case original
    case manualEdit
}

enum HaloInstructionSource: String, Equatable, Sendable {
    case voice
    case typed

    var promptLabel: String {
        switch self {
        case .voice: return "spoken"
        case .typed: return "typed"
        }
    }
}

struct HaloInstructionDraft: Equatable, Sendable {
    let requestID: UUID
    let baseRevisionID: UUID
    let source: HaloInstructionSource
    var text: String
}

struct HaloReviewModelMetadata: Equatable, Sendable {
    let modeName: String?
    let modeEmoji: String?
    let providerLabel: String?
    let connectionLabel: String?
    let modelLabel: String?
}

struct HaloReviewRevision: Identifiable, Equatable {
    let id: UUID
    let parentID: UUID?
    let action: HaloReviewRevisionAction
    let text: String
    let metadata: HaloReviewModelMetadata
    let payload: PreparedPastePayload

    init(
        id: UUID = UUID(),
        parentID: UUID?,
        action: HaloReviewRevisionAction,
        text: String,
        metadata: HaloReviewModelMetadata,
        payload: PreparedPastePayload
    ) {
        self.id = id
        self.parentID = parentID
        self.action = action
        self.text = text
        self.metadata = metadata
        self.payload = payload
    }
}

/// Immutable recording- and provider-specific material retained only while a
/// Halo review is alive. It deliberately stores IDs and prepared payload data;
/// it never persists clipboard, selection, or screen context.
struct HaloReviewSession {
    let id: UUID
    let transcriptionID: UUID
    let rawText: String
    let initialEnhancement: String?
    let destination: PasteReviewDestinationSnapshot?
    let metadata: HaloReviewModelMetadata
    let enhancementWarning: String?
    let deliveryReviewReason: String?
    let output: OutputRuntimeConfiguration
    let transcriptionConfiguration: TranscriptionRuntimeConfiguration?
    let enhancementConfiguration: EnhancementRuntimeConfiguration?
    let refinementInputSnapshot: HaloRefinementInputSnapshot?
    let frozenContext: RecordingContextSnapshot?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        transcriptionID: UUID,
        rawText: String,
        initialEnhancement: String?,
        destination: PasteReviewDestinationSnapshot?,
        metadata: HaloReviewModelMetadata,
        enhancementWarning: String?,
        deliveryReviewReason: String? = nil,
        output: OutputRuntimeConfiguration,
        transcriptionConfiguration: TranscriptionRuntimeConfiguration? = nil,
        enhancementConfiguration: EnhancementRuntimeConfiguration?,
        refinementInputSnapshot: HaloRefinementInputSnapshot? = nil,
        frozenContext: RecordingContextSnapshot?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.transcriptionID = transcriptionID
        self.rawText = rawText
        self.initialEnhancement = initialEnhancement
        self.destination = destination
        self.metadata = metadata
        self.enhancementWarning = enhancementWarning
        self.deliveryReviewReason = deliveryReviewReason
        self.output = output
        self.transcriptionConfiguration = transcriptionConfiguration
        self.enhancementConfiguration = enhancementConfiguration
        self.refinementInputSnapshot = refinementInputSnapshot
        self.frozenContext = frozenContext
        self.createdAt = createdAt
    }
}

enum HaloReviewRefinementKind: Equatable, Sendable {
    case preset(HaloRefinementAction)
    case anotherTake

    var presetAction: HaloRefinementAction? {
        guard case .preset(let action) = self else { return nil }
        return action
    }

    var revisionAction: HaloReviewRevisionAction {
        switch self {
        case .preset(let action):
            return .refinement(action)
        case .anotherTake:
            return .anotherTake
        }
    }
}

struct HaloReviewRefinementRequest: Equatable, Sendable {
    let id: UUID
    let kind: HaloReviewRefinementKind
    let baseRevisionID: UUID

    init(id: UUID, action: HaloRefinementAction, baseRevisionID: UUID) {
        self.id = id
        kind = .preset(action)
        self.baseRevisionID = baseRevisionID
    }

    init(id: UUID, kind: HaloReviewRefinementKind, baseRevisionID: UUID) {
        self.id = id
        self.kind = kind
        self.baseRevisionID = baseRevisionID
    }

    var action: HaloRefinementAction? { kind.presetAction }
}

struct HaloReviewManualEdit: Equatable, Sendable {
    let baseRevisionID: UUID
    var text: String
}

struct HaloVoiceRefinementRequest: Equatable, Sendable {
    let id: UUID
    let baseRevisionID: UUID
    let source: HaloInstructionSource

    init(
        id: UUID,
        baseRevisionID: UUID,
        source: HaloInstructionSource = .voice
    ) {
        self.id = id
        self.baseRevisionID = baseRevisionID
        self.source = source
    }
}

enum HaloVoiceRefinementFailure: Equatable, Sendable {
    case emptyInstruction
    case tooLongInstruction
    case captureUnavailable
    case captureFailed
    case transcriptionFailed
    case refinementFailed
    case emptyResult
    case unchangedResult

    var message: String {
        switch self {
        case .emptyInstruction:
            return String(localized: "No spoken change was detected.")
        case .tooLongInstruction:
            return String(localized: "The spoken change is too long. Try a shorter instruction.")
        case .captureUnavailable:
            return String(localized: "Voice refinement cannot access the microphone.")
        case .captureFailed:
            return String(localized: "The spoken change could not be recorded.")
        case .transcriptionFailed:
            return String(localized: "The spoken change could not be understood.")
        case .refinementFailed:
            return String(localized: "The spoken change could not be applied. Your current version is unchanged.")
        case .emptyResult:
            return String(localized: "The spoken refinement returned no usable text.")
        case .unchangedResult:
            return String(localized: "The spoken refinement did not change this version.")
        }
    }
}

enum HaloVoiceRefinementPhase: Equatable, Sendable {
    case idle
    case listening(HaloVoiceRefinementRequest)
    case transcribing(HaloVoiceRefinementRequest)
    case awaitingConfirmation(HaloInstructionDraft)
    case editingInstruction(HaloInstructionDraft)
    case refining(HaloVoiceRefinementRequest)
    case failed(HaloVoiceRefinementFailure)

    var activeRequest: HaloVoiceRefinementRequest? {
        switch self {
        case .listening(let request), .transcribing(let request), .refining(let request):
            return request
        case .awaitingConfirmation(let draft), .editingInstruction(let draft):
            return HaloVoiceRefinementRequest(
                id: draft.requestID,
                baseRevisionID: draft.baseRevisionID,
                source: draft.source
            )
        case .idle, .failed:
            return nil
        }
    }

    var isActive: Bool { activeRequest != nil }

    var isProcessing: Bool {
        switch self {
        case .listening, .transcribing, .refining:
            return true
        case .idle, .awaitingConfirmation, .editingInstruction, .failed:
            return false
        }
    }

    var instructionDraft: HaloInstructionDraft? {
        switch self {
        case .awaitingConfirmation(let draft), .editingInstruction(let draft):
            return draft
        case .idle, .listening, .transcribing, .refining, .failed:
            return nil
        }
    }
}

enum HaloReviewNotice: Equatable, Sendable {
    case copied
    case copyFailed
    case emptyRefinement
    case unchangedRefinement
    case refinementCancelled
    case refinementFailed(String)
    case revisionLimitReached
    case emptyManualEdit
    case unchangedManualEdit
    case voiceRefinementCancelled
    case voiceRefinementFailed(HaloVoiceRefinementFailure)
    case instructionValidation(String)

    var message: String {
        switch self {
        case .copied:
            return String(localized: "Copied exact paste text")
        case .copyFailed:
            return String(localized: "Could not copy the transcript")
        case .emptyRefinement:
            return String(localized: "The refinement returned no usable text.")
        case .unchangedRefinement:
            return String(localized: "The refinement did not change this version.")
        case .refinementCancelled:
            return String(localized: "Refinement cancelled")
        case .refinementFailed(let message):
            return message
        case .revisionLimitReached:
            return String(localized: "This review already has six versions.")
        case .emptyManualEdit:
            return String(localized: "Manual edits cannot be empty.")
        case .unchangedManualEdit:
            return String(localized: "The manual edit did not change this version.")
        case .voiceRefinementCancelled:
            return String(localized: "Voice refinement cancelled")
        case .voiceRefinementFailed(let failure):
            return failure.message
        case .instructionValidation(let message):
            return message
        }
    }
}

struct HaloReviewState {
    static let maximumRevisionCount = 6
    static let inactivityLifetime: TimeInterval = 120

    let session: HaloReviewSession
    private(set) var revisions: [HaloReviewRevision]
    private(set) var selectedRevisionID: UUID
    private(set) var lens: HaloReviewLens
    private(set) var refinementRequest: HaloReviewRefinementRequest?
    private(set) var voiceRefinementPhase: HaloVoiceRefinementPhase
    private(set) var manualEdit: HaloReviewManualEdit?
    private(set) var notice: HaloReviewNotice?
    private(set) var expiresAt: Date
    private(set) var isExpired = false

    init(
        session: HaloReviewSession,
        initialRevision: HaloReviewRevision,
        now: Date = Date()
    ) {
        self.session = session
        revisions = [initialRevision]
        selectedRevisionID = initialRevision.id
        lens = .final
        refinementRequest = nil
        voiceRefinementPhase = .idle
        manualEdit = nil
        notice = nil
        expiresAt = now.addingTimeInterval(Self.inactivityLifetime)
    }

    var selectedRevision: HaloReviewRevision? {
        revisions.first { $0.id == selectedRevisionID }
    }

    var selectedRevisionIndex: Int? {
        revisions.firstIndex { $0.id == selectedRevisionID }
    }

    var parentRevision: HaloReviewRevision? {
        guard let parentID = selectedRevision?.parentID else { return nil }
        return revisions.first { $0.id == parentID }
    }

    var comparisonBaseText: String {
        parentRevision?.text ?? session.rawText
    }

    var canRefine: Bool {
        !isExpired && refinementRequest == nil && !voiceRefinementPhase.isActive && manualEdit == nil
            && revisions.count < Self.maximumRevisionCount
    }

    var isRefining: Bool { refinementRequest != nil }
    var isVoiceRefinementActive: Bool { voiceRefinementPhase.isActive }
    var isEditingManually: Bool { manualEdit != nil }
    var isReviewOperationActive: Bool {
        isRefining || isVoiceRefinementActive || isEditingManually
    }

    var canResolveReview: Bool {
        !isExpired && !isReviewOperationActive
    }

    func secondsRemaining(at date: Date = Date()) -> Int {
        if isRefining || voiceRefinementPhase.isProcessing {
            return max(1, Int(ceil(expiresAt.timeIntervalSince(date))))
        }
        return max(0, Int(ceil(expiresAt.timeIntervalSince(date))))
    }

    mutating func touch(at date: Date = Date()) {
        guard !isExpired, !isRefining, !voiceRefinementPhase.isProcessing else { return }
        expiresAt = date.addingTimeInterval(Self.inactivityLifetime)
    }

    mutating func setNotice(_ notice: HaloReviewNotice?, at date: Date = Date()) {
        self.notice = notice
        touch(at: date)
    }

    mutating func selectLens(_ lens: HaloReviewLens, at date: Date = Date()) {
        guard !isExpired else { return }
        self.lens = lens
        touch(at: date)
    }

    @discardableResult
    mutating func selectRevision(id: UUID, at date: Date = Date()) -> Bool {
        guard !isExpired, !isRefining, !isVoiceRefinementActive, !isEditingManually,
            revisions.contains(where: { $0.id == id })
        else {
            return false
        }
        selectedRevisionID = id
        notice = nil
        touch(at: date)
        return true
    }

    @discardableResult
    mutating func moveRevision(by offset: Int, at date: Date = Date()) -> Bool {
        guard let selectedRevisionIndex else { return false }
        let target = selectedRevisionIndex + offset
        guard revisions.indices.contains(target) else { return false }
        return selectRevision(id: revisions[target].id, at: date)
    }

    @discardableResult
    mutating func beginRefinement(
        action: HaloRefinementAction,
        requestID: UUID = UUID(),
        at date: Date = Date()
    ) -> HaloReviewRefinementRequest? {
        guard !isExpired, refinementRequest == nil, !voiceRefinementPhase.isActive, manualEdit == nil,
            let selectedRevision
        else {
            return nil
        }
        guard revisions.count < Self.maximumRevisionCount else {
            notice = .revisionLimitReached
            touch(at: date)
            return nil
        }

        // Freeze the remaining lifetime while the request runs. Completion or
        // failure grants a fresh inactivity window.
        expiresAt = max(expiresAt, date.addingTimeInterval(1))
        let request = HaloReviewRefinementRequest(
            id: requestID,
            action: action,
            baseRevisionID: selectedRevision.id
        )
        refinementRequest = request
        notice = nil
        return request
    }

    @discardableResult
    mutating func beginAnotherTake(
        requestID: UUID = UUID(),
        at date: Date = Date()
    ) -> HaloReviewRefinementRequest? {
        guard !isExpired, refinementRequest == nil, !voiceRefinementPhase.isActive,
            manualEdit == nil, let selectedRevision
        else {
            return nil
        }
        guard revisions.count < Self.maximumRevisionCount else {
            notice = .revisionLimitReached
            touch(at: date)
            return nil
        }

        expiresAt = max(expiresAt, date.addingTimeInterval(1))
        let request = HaloReviewRefinementRequest(
            id: requestID,
            kind: .anotherTake,
            baseRevisionID: selectedRevision.id
        )
        refinementRequest = request
        notice = nil
        return request
    }

    enum CompletionResult: Equatable {
        case appended
        case empty
        case unchanged
        case stale
        case limitReached
    }

    @discardableResult
    mutating func completeRefinement(
        requestID: UUID,
        revision: HaloReviewRevision,
        at date: Date = Date()
    ) -> CompletionResult {
        guard let request = refinementRequest,
            request.id == requestID,
            request.baseRevisionID == revision.parentID,
            let base = revisions.first(where: { $0.id == request.baseRevisionID })
        else {
            return .stale
        }

        refinementRequest = nil
        expiresAt = date.addingTimeInterval(Self.inactivityLifetime)

        let trimmed = revision.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            notice = .emptyRefinement
            return .empty
        }
        guard revision.text != base.text else {
            notice = .unchangedRefinement
            return .unchanged
        }
        guard revisions.count < Self.maximumRevisionCount else {
            notice = .revisionLimitReached
            return .limitReached
        }

        revisions.append(revision)
        selectedRevisionID = revision.id
        lens = .changes
        notice = nil
        return .appended
    }

    @discardableResult
    mutating func finishRefinementFailure(
        requestID: UUID,
        notice: HaloReviewNotice,
        at date: Date = Date()
    ) -> Bool {
        guard refinementRequest?.id == requestID else { return false }
        refinementRequest = nil
        self.notice = notice
        expiresAt = date.addingTimeInterval(Self.inactivityLifetime)
        return true
    }

    @discardableResult
    mutating func cancelRefinement(at date: Date = Date()) -> Bool {
        guard refinementRequest != nil else { return false }
        refinementRequest = nil
        notice = .refinementCancelled
        expiresAt = date.addingTimeInterval(Self.inactivityLifetime)
        return true
    }

    @discardableResult
    mutating func beginVoiceRefinement(
        requestID: UUID = UUID(),
        allowsRevisionLimit: Bool = false,
        at date: Date = Date()
    ) -> HaloVoiceRefinementRequest? {
        guard !isExpired, refinementRequest == nil, !voiceRefinementPhase.isActive,
            manualEdit == nil, let selectedRevision
        else {
            return nil
        }
        guard allowsRevisionLimit || revisions.count < Self.maximumRevisionCount else {
            notice = .revisionLimitReached
            touch(at: date)
            return nil
        }

        // Freeze expiry while capture, transcription, or replacement
        // refinement is active. Every terminal path grants a fresh window.
        expiresAt = max(expiresAt, date.addingTimeInterval(1))
        let request = HaloVoiceRefinementRequest(
            id: requestID,
            baseRevisionID: selectedRevision.id
        )
        voiceRefinementPhase = .listening(request)
        notice = nil
        return request
    }

    /// Completes a final-only local voice command without creating a revision
    /// or retaining the recognized phrase in review state.
    @discardableResult
    mutating func completeVoiceCommandCapture(
        requestID: UUID,
        at date: Date = Date()
    ) -> Bool {
        let request: HaloVoiceRefinementRequest
        switch voiceRefinementPhase {
        case .listening(let active), .transcribing(let active):
            request = active
        case .idle, .awaitingConfirmation, .editingInstruction, .refining, .failed:
            return false
        }
        guard request.id == requestID else { return false }
        voiceRefinementPhase = .idle
        notice = nil
        expiresAt = date.addingTimeInterval(Self.inactivityLifetime)
        return true
    }

    @discardableResult
    mutating func finishVoiceCapture(
        requestID: UUID,
        at date: Date = Date()
    ) -> Bool {
        guard case .listening(let request) = voiceRefinementPhase,
            request.id == requestID
        else {
            return false
        }
        voiceRefinementPhase = .transcribing(request)
        expiresAt = max(expiresAt, date.addingTimeInterval(1))
        return true
    }

    @discardableResult
    mutating func finishVoiceTranscription(
        requestID: UUID,
        at date: Date = Date()
    ) -> Bool {
        guard case .transcribing(let request) = voiceRefinementPhase,
            request.id == requestID
        else {
            return false
        }
        voiceRefinementPhase = .refining(request)
        expiresAt = max(expiresAt, date.addingTimeInterval(1))
        return true
    }

    /// Stages recognized speech for explicit user confirmation. No model
    /// request is started until `submitInstructionDraft` succeeds.
    @discardableResult
    mutating func stageVoiceInstruction(
        requestID: UUID,
        text: String,
        at date: Date = Date()
    ) -> Bool {
        guard case .transcribing(let request) = voiceRefinementPhase,
            request.id == requestID
        else {
            return false
        }

        voiceRefinementPhase = .awaitingConfirmation(
            HaloInstructionDraft(
                requestID: request.id,
                baseRevisionID: request.baseRevisionID,
                source: .voice,
                text: text
            )
        )
        notice = nil
        expiresAt = date.addingTimeInterval(Self.inactivityLifetime)
        return true
    }

    @discardableResult
    mutating func beginTypedInstruction(
        requestID: UUID = UUID(),
        at date: Date = Date()
    ) -> HaloInstructionDraft? {
        guard !isExpired, refinementRequest == nil, !voiceRefinementPhase.isActive,
            manualEdit == nil, let selectedRevision
        else {
            return nil
        }
        guard revisions.count < Self.maximumRevisionCount else {
            notice = .revisionLimitReached
            touch(at: date)
            return nil
        }

        let draft = HaloInstructionDraft(
            requestID: requestID,
            baseRevisionID: selectedRevision.id,
            source: .typed,
            text: ""
        )
        voiceRefinementPhase = .editingInstruction(draft)
        notice = nil
        expiresAt = date.addingTimeInterval(Self.inactivityLifetime)
        return draft
    }

    @discardableResult
    mutating func editInstructionDraft(at date: Date = Date()) -> Bool {
        guard case .awaitingConfirmation(let draft) = voiceRefinementPhase else {
            return false
        }
        voiceRefinementPhase = .editingInstruction(draft)
        touch(at: date)
        return true
    }

    @discardableResult
    mutating func updateInstructionDraft(
        requestID: UUID,
        _ text: String,
        at date: Date = Date()
    ) -> Bool {
        guard case .editingInstruction(var draft) = voiceRefinementPhase else {
            return false
        }
        guard draft.requestID == requestID else { return false }
        draft.text = text
        voiceRefinementPhase = .editingInstruction(draft)
        touch(at: date)
        return true
    }

    /// Atomically leaves the editable/confirmable draft state and freezes the
    /// inactivity timer for the resulting model request. The caller receives
    /// the draft exactly once through the reducer effect and can build the
    /// ephemeral request without retaining instruction text in review state.
    @discardableResult
    mutating func submitInstructionDraft(
        at date: Date = Date()
    ) -> HaloInstructionDraft? {
        guard !isExpired else { return nil }
        guard date < expiresAt else {
            _ = expireIfNeeded(at: date)
            return nil
        }

        let draft: HaloInstructionDraft
        switch voiceRefinementPhase {
        case .awaitingConfirmation(let pending), .editingInstruction(let pending):
            draft = pending
        case .idle, .listening, .transcribing, .refining, .failed:
            return nil
        }

        voiceRefinementPhase = .refining(
            HaloVoiceRefinementRequest(
                id: draft.requestID,
                baseRevisionID: draft.baseRevisionID,
                source: draft.source
            )
        )
        notice = nil
        expiresAt = max(expiresAt, date.addingTimeInterval(1))
        return draft
    }

    @discardableResult
    mutating func completeVoiceRefinement(
        requestID: UUID,
        revision: HaloReviewRevision,
        at date: Date = Date()
    ) -> CompletionResult {
        guard case .refining(let request) = voiceRefinementPhase,
            request.id == requestID,
            request.baseRevisionID == revision.parentID,
            revision.action == (request.source == .voice ? .voiceRefinement : .typedRefinement),
            let base = revisions.first(where: { $0.id == request.baseRevisionID })
        else {
            return .stale
        }

        expiresAt = date.addingTimeInterval(Self.inactivityLifetime)
        let trimmed = revision.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            voiceRefinementPhase = .failed(.emptyResult)
            notice = .voiceRefinementFailed(.emptyResult)
            return .empty
        }
        guard revision.text != base.text else {
            voiceRefinementPhase = .failed(.unchangedResult)
            notice = .voiceRefinementFailed(.unchangedResult)
            return .unchanged
        }
        guard revisions.count < Self.maximumRevisionCount else {
            voiceRefinementPhase = .idle
            notice = .revisionLimitReached
            return .limitReached
        }

        revisions.append(revision)
        selectedRevisionID = revision.id
        lens = .changes
        voiceRefinementPhase = .idle
        notice = nil
        return .appended
    }

    @discardableResult
    mutating func finishVoiceRefinementFailure(
        requestID: UUID,
        failure: HaloVoiceRefinementFailure,
        at date: Date = Date()
    ) -> Bool {
        guard voiceRefinementPhase.activeRequest?.id == requestID else { return false }
        voiceRefinementPhase = .failed(failure)
        notice = .voiceRefinementFailed(failure)
        expiresAt = date.addingTimeInterval(Self.inactivityLifetime)
        return true
    }

    @discardableResult
    mutating func cancelVoiceRefinement(at date: Date = Date()) -> HaloVoiceRefinementRequest? {
        guard let request = voiceRefinementPhase.activeRequest else { return nil }
        voiceRefinementPhase = .idle
        notice = .voiceRefinementCancelled
        expiresAt = date.addingTimeInterval(Self.inactivityLifetime)
        return request
    }

    @discardableResult
    mutating func useOriginal(
        revision: HaloReviewRevision,
        at date: Date = Date()
    ) -> Bool {
        guard !isExpired, !isRefining, !isVoiceRefinementActive, !isEditingManually else {
            return false
        }

        if let existing = revisions.first(where: { $0.action == .original }) {
            selectedRevisionID = existing.id
            lens = .final
            notice = nil
            touch(at: date)
            return true
        }

        guard revisions.count < Self.maximumRevisionCount,
            !revision.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            notice = .revisionLimitReached
            touch(at: date)
            return false
        }

        revisions.append(revision)
        selectedRevisionID = revision.id
        lens = .final
        notice = nil
        touch(at: date)
        return true
    }

    @discardableResult
    mutating func beginManualEdit(at date: Date = Date()) -> Bool {
        guard !isExpired, !isRefining, !isVoiceRefinementActive, manualEdit == nil,
            revisions.count < Self.maximumRevisionCount,
            let selectedRevision
        else {
            if revisions.count >= Self.maximumRevisionCount {
                notice = .revisionLimitReached
                touch(at: date)
            }
            return false
        }

        manualEdit = HaloReviewManualEdit(
            baseRevisionID: selectedRevision.id,
            text: selectedRevision.text
        )
        notice = nil
        touch(at: date)
        return true
    }

    @discardableResult
    mutating func updateManualEdit(_ text: String, at date: Date = Date()) -> Bool {
        guard !isExpired, manualEdit != nil else { return false }
        manualEdit?.text = text
        touch(at: date)
        return true
    }

    @discardableResult
    mutating func completeManualEdit(
        revision: HaloReviewRevision,
        at date: Date = Date()
    ) -> Bool {
        guard let edit = manualEdit,
            edit.baseRevisionID == revision.parentID,
            let base = revisions.first(where: { $0.id == edit.baseRevisionID })
        else {
            return false
        }

        manualEdit = nil
        let trimmed = revision.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            notice = .emptyManualEdit
            touch(at: date)
            return false
        }
        guard revision.text != base.text else {
            notice = .unchangedManualEdit
            touch(at: date)
            return false
        }
        guard revisions.count < Self.maximumRevisionCount else {
            notice = .revisionLimitReached
            touch(at: date)
            return false
        }

        revisions.append(revision)
        selectedRevisionID = revision.id
        lens = .final
        notice = nil
        touch(at: date)
        return true
    }

    @discardableResult
    mutating func cancelManualEdit(at date: Date = Date()) -> Bool {
        guard manualEdit != nil else { return false }
        manualEdit = nil
        notice = nil
        touch(at: date)
        return true
    }

    @discardableResult
    mutating func expireIfNeeded(at date: Date = Date()) -> Bool {
        guard !isExpired, !isRefining, !voiceRefinementPhase.isProcessing,
            date >= expiresAt
        else {
            return false
        }
        isExpired = true
        voiceRefinementPhase = .idle
        manualEdit = nil
        return true
    }
}

enum HaloReviewReducerAction: Equatable {
    case selectLens(HaloReviewLens, at: Date)
    case selectRevision(UUID, at: Date)
    case moveRevision(Int, at: Date)
    case copied(succeeded: Bool, at: Date)
    case beginRefinement(HaloRefinementAction, requestID: UUID, at: Date)
    case beginAnotherTake(requestID: UUID, at: Date)
    case completeRefinement(requestID: UUID, revision: HaloReviewRevision, at: Date)
    case failRefinement(requestID: UUID, notice: HaloReviewNotice, at: Date)
    case cancelRefinement(at: Date)
    case beginVoiceRefinement(requestID: UUID, at: Date)
    case beginVoiceCommandCapture(requestID: UUID, at: Date)
    case finishVoiceCapture(requestID: UUID, at: Date)
    case finishVoiceTranscription(requestID: UUID, at: Date)
    case stageVoiceInstruction(requestID: UUID, text: String, at: Date)
    case completeVoiceCommandCapture(requestID: UUID, at: Date)
    case beginTypedInstruction(requestID: UUID, at: Date)
    case editInstructionDraft(at: Date)
    case updateInstructionDraft(requestID: UUID, text: String, at: Date)
    case submitInstructionDraft(at: Date)
    case completeVoiceRefinement(requestID: UUID, revision: HaloReviewRevision, at: Date)
    case failVoiceRefinement(requestID: UUID, failure: HaloVoiceRefinementFailure, at: Date)
    case cancelVoiceRefinement(at: Date)
    case cancelActiveTransientAction(at: Date)
    case useOriginal(HaloReviewRevision, at: Date)
    case beginManualEdit(at: Date)
    case updateManualEdit(String, at: Date)
    case completeManualEdit(HaloReviewRevision, at: Date)
    case cancelManualEdit(at: Date)
    case timeout(at: Date)
    case touch(at: Date)
}

enum HaloReviewReducerEffect: Equatable {
    case none
    case refinementStarted(HaloReviewRefinementRequest)
    case voiceRefinementStarted(HaloVoiceRefinementRequest)
    case voiceRefinementPhaseChanged(HaloVoiceRefinementPhase)
    case instructionSubmitted(HaloInstructionDraft)
    case voiceRefinementCancelled(UUID)
    case revisionAppended(UUID)
    case expired
    case ignored
}

enum HaloReviewReducer {
    @discardableResult
    static func reduce(
        state: inout HaloReviewState,
        action: HaloReviewReducerAction
    ) -> HaloReviewReducerEffect {
        switch action {
        case .selectLens(let lens, let date):
            state.selectLens(lens, at: date)
            return .none

        case .selectRevision(let id, let date):
            return state.selectRevision(id: id, at: date) ? .none : .ignored

        case .moveRevision(let offset, let date):
            return state.moveRevision(by: offset, at: date) ? .none : .ignored

        case .copied(let succeeded, let date):
            guard !state.isVoiceRefinementActive else { return .ignored }
            state.setNotice(succeeded ? .copied : .copyFailed, at: date)
            return .none

        case .beginRefinement(let refinement, let requestID, let date):
            guard let request = state.beginRefinement(
                action: refinement,
                requestID: requestID,
                at: date
            ) else {
                return .ignored
            }
            return .refinementStarted(request)

        case .beginAnotherTake(let requestID, let date):
            guard let request = state.beginAnotherTake(
                requestID: requestID,
                at: date
            ) else {
                return .ignored
            }
            return .refinementStarted(request)

        case .completeRefinement(let requestID, let revision, let date):
            let result = state.completeRefinement(
                requestID: requestID,
                revision: revision,
                at: date
            )
            return result == .appended ? .revisionAppended(revision.id) : .ignored

        case .failRefinement(let requestID, let notice, let date):
            return state.finishRefinementFailure(
                requestID: requestID,
                notice: notice,
                at: date
            ) ? .none : .ignored

        case .cancelRefinement(let date):
            return state.cancelRefinement(at: date) ? .none : .ignored

        case .beginVoiceRefinement(let requestID, let date):
            guard let request = state.beginVoiceRefinement(
                requestID: requestID,
                at: date
            ) else {
                return .ignored
            }
            return .voiceRefinementStarted(request)

        case .beginVoiceCommandCapture(let requestID, let date):
            guard let request = state.beginVoiceRefinement(
                requestID: requestID,
                allowsRevisionLimit: true,
                at: date
            ) else {
                return .ignored
            }
            return .voiceRefinementStarted(request)

        case .finishVoiceCapture(let requestID, let date):
            guard state.finishVoiceCapture(requestID: requestID, at: date) else {
                return .ignored
            }
            return .voiceRefinementPhaseChanged(state.voiceRefinementPhase)

        case .finishVoiceTranscription(let requestID, let date):
            guard state.finishVoiceTranscription(requestID: requestID, at: date) else {
                return .ignored
            }
            return .voiceRefinementPhaseChanged(state.voiceRefinementPhase)

        case .stageVoiceInstruction(let requestID, let text, let date):
            guard state.stageVoiceInstruction(
                requestID: requestID,
                text: text,
                at: date
            ) else {
                return .ignored
            }
            return .voiceRefinementPhaseChanged(state.voiceRefinementPhase)

        case .completeVoiceCommandCapture(let requestID, let date):
            guard state.completeVoiceCommandCapture(
                requestID: requestID,
                at: date
            ) else {
                return .ignored
            }
            return .voiceRefinementPhaseChanged(state.voiceRefinementPhase)

        case .beginTypedInstruction(let requestID, let date):
            guard state.beginTypedInstruction(requestID: requestID, at: date) != nil else {
                return .ignored
            }
            return .voiceRefinementPhaseChanged(state.voiceRefinementPhase)

        case .editInstructionDraft(let date):
            guard state.editInstructionDraft(at: date) else { return .ignored }
            return .voiceRefinementPhaseChanged(state.voiceRefinementPhase)

        case .updateInstructionDraft(let requestID, let text, let date):
            guard state.updateInstructionDraft(
                requestID: requestID,
                text,
                at: date
            ) else { return .ignored }
            return .voiceRefinementPhaseChanged(state.voiceRefinementPhase)

        case .submitInstructionDraft(let date):
            guard let draft = state.submitInstructionDraft(at: date) else {
                return .ignored
            }
            return .instructionSubmitted(draft)

        case .completeVoiceRefinement(let requestID, let revision, let date):
            let result = state.completeVoiceRefinement(
                requestID: requestID,
                revision: revision,
                at: date
            )
            return result == .appended ? .revisionAppended(revision.id) : .ignored

        case .failVoiceRefinement(let requestID, let failure, let date):
            guard state.finishVoiceRefinementFailure(
                requestID: requestID,
                failure: failure,
                at: date
            ) else {
                return .ignored
            }
            return .voiceRefinementPhaseChanged(state.voiceRefinementPhase)

        case .cancelVoiceRefinement(let date):
            guard let request = state.cancelVoiceRefinement(at: date) else {
                return .ignored
            }
            return .voiceRefinementCancelled(request.id)

        case .cancelActiveTransientAction(let date):
            if let request = state.cancelVoiceRefinement(at: date) {
                return .voiceRefinementCancelled(request.id)
            }
            if state.cancelRefinement(at: date) {
                return .none
            }
            if state.cancelManualEdit(at: date) {
                return .none
            }
            return .ignored

        case .useOriginal(let revision, let date):
            return state.useOriginal(revision: revision, at: date)
                ? .revisionAppended(state.selectedRevisionID)
                : .ignored

        case .beginManualEdit(let date):
            return state.beginManualEdit(at: date) ? .none : .ignored

        case .updateManualEdit(let text, let date):
            return state.updateManualEdit(text, at: date) ? .none : .ignored

        case .completeManualEdit(let revision, let date):
            return state.completeManualEdit(revision: revision, at: date)
                ? .revisionAppended(revision.id)
                : .ignored

        case .cancelManualEdit(let date):
            return state.cancelManualEdit(at: date) ? .none : .ignored

        case .timeout(let date):
            return state.expireIfNeeded(at: date) ? .expired : .ignored

        case .touch(let date):
            state.touch(at: date)
            return .none
        }
    }
}
