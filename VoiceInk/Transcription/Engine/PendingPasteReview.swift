import Foundation

struct PendingPasteReview: Identifiable {
    static let defaultLifetime: TimeInterval = 120

    let id: UUID
    let transcriptionID: UUID
    let rawText: String
    let finalText: String
    let payload: PreparedPastePayload
    let modeName: String?
    let modeEmoji: String?
    let providerLabel: String?
    let connectionLabel: String?
    let modelLabel: String?
    let enhancementWarning: String?
    let output: OutputRuntimeConfiguration
    let enhancementConfiguration: EnhancementRuntimeConfiguration?
    let frozenContext: RecordingContextSnapshot?
    let destination: PasteReviewDestinationSnapshot?
    let expiresAt: Date

    func isExpired(at date: Date = Date()) -> Bool {
        expiresAt <= date
    }

    init(
        id: UUID = UUID(),
        transcriptionID: UUID = UUID(),
        rawText: String,
        finalText: String,
        payload: PreparedPastePayload,
        modeName: String? = nil,
        modeEmoji: String? = nil,
        providerLabel: String? = nil,
        connectionLabel: String? = nil,
        modelLabel: String? = nil,
        enhancementWarning: String? = nil,
        output: OutputRuntimeConfiguration = OutputRuntimeConfiguration(
            mode: nil,
            outputMode: .paste,
            autoSendKey: .none,
            customCommand: nil
        ),
        enhancementConfiguration: EnhancementRuntimeConfiguration? = nil,
        frozenContext: RecordingContextSnapshot? = nil,
        destination: PasteReviewDestinationSnapshot? = nil,
        expiresAt: Date = Date().addingTimeInterval(defaultLifetime)
    ) {
        self.id = id
        self.transcriptionID = transcriptionID
        self.rawText = rawText
        self.finalText = finalText
        self.payload = payload
        self.modeName = modeName
        self.modeEmoji = modeEmoji
        self.providerLabel = providerLabel
        self.connectionLabel = connectionLabel
        self.modelLabel = modelLabel
        self.enhancementWarning = enhancementWarning
        self.output = output
        self.enhancementConfiguration = enhancementConfiguration
        self.frozenContext = frozenContext
        self.destination = destination
        self.expiresAt = expiresAt
    }

    func withDestination(_ destination: PasteReviewDestinationSnapshot?) -> PendingPasteReview {
        PendingPasteReview(
            id: id,
            transcriptionID: transcriptionID,
            rawText: rawText,
            finalText: finalText,
            payload: payload,
            modeName: modeName,
            modeEmoji: modeEmoji,
            providerLabel: providerLabel,
            connectionLabel: connectionLabel,
            modelLabel: modelLabel,
            enhancementWarning: enhancementWarning,
            output: output,
            enhancementConfiguration: enhancementConfiguration,
            frozenContext: frozenContext,
            destination: destination,
            expiresAt: expiresAt
        )
    }
}

enum PasteReviewFeedback: Equatable, Sendable {
    case copied
    case copyFailed
    case destinationChanged(PasteReviewDestinationMismatch)
    case pasteFailed
    case deliveryUnavailable

    var allowsRetry: Bool {
        self == .pasteFailed
    }

    var message: String {
        switch self {
        case .copied:
            return String(localized: "Copied exact paste text")
        case .copyFailed:
            return String(localized: "Could not copy the transcript")
        case .destinationChanged(let mismatch):
            if let expected = mismatch.expectedApplicationName?.trimmingCharacters(in: .whitespacesAndNewlines),
                !expected.isEmpty
            {
                return String(
                    format: String(localized: "Return to %@ to apply this transcript."),
                    expected
                )
            }
            return String(localized: "Return to the original text field to apply this transcript.")
        case .pasteFailed:
            return String(localized: "Paste was not delivered. Try again or copy the result.")
        case .deliveryUnavailable:
            return String(localized: "Paste is temporarily unavailable. Copy the result instead.")
        }
    }
}

enum PasteReviewExpiration {
    static let warningThresholdSeconds = 15

    static func secondsRemaining(until expiration: Date, at date: Date = Date()) -> Int {
        max(0, Int(ceil(expiration.timeIntervalSince(date))))
    }

    static func isInWarningWindow(secondsRemaining: Int) -> Bool {
        (1...warningThresholdSeconds).contains(secondsRemaining)
    }
}

/// MainActor owns the gate in VoiceInkEngine. Its explicit transitions prevent
/// Return, mouse Apply, Retry, Copy, and Cancel from racing across suspension
/// points while a paste command is being posted.
struct PasteReviewResolutionGate: Equatable {
    enum Phase: Equatable {
        case idle
        case pending(UUID)
        case delivering(UUID)
        case completed(UUID)
    }

    private(set) var phase: Phase = .idle

    mutating func stage(_ reviewID: UUID) -> Bool {
        switch phase {
        case .idle, .completed:
            phase = .pending(reviewID)
            return true
        case .pending, .delivering:
            return false
        }
    }

    mutating func beginDelivery(_ reviewID: UUID) -> Bool {
        guard phase == .pending(reviewID) else { return false }
        phase = .delivering(reviewID)
        return true
    }

    mutating func restoreAfterFailure(_ reviewID: UUID) -> Bool {
        guard phase == .delivering(reviewID) else { return false }
        phase = .pending(reviewID)
        return true
    }

    mutating func completeDelivery(_ reviewID: UUID) -> Bool {
        guard phase == .delivering(reviewID) else { return false }
        phase = .completed(reviewID)
        return true
    }

    mutating func cancel(_ reviewID: UUID) -> Bool {
        guard phase == .pending(reviewID) else { return false }
        phase = .completed(reviewID)
        return true
    }

    func permitsNonDeliveryAction(for reviewID: UUID) -> Bool {
        phase == .pending(reviewID)
    }

    mutating func reset() {
        phase = .idle
    }
}

enum PendingPasteReviewSlot {
    /// The caller owns synchronization. VoiceInkEngine invokes this on MainActor,
    /// making approval/cancellation a single consume operation.
    static func take(_ pending: inout PendingPasteReview?) -> PendingPasteReview? {
        let review = pending
        pending = nil
        return review
    }
}

enum PasteReviewLifecycle {
    static func canReturnToIdle(
        hasActivePipeline: Bool,
        isResolvingReview: Bool
    ) -> Bool {
        !hasActivePipeline && !isResolvingReview
    }
}
