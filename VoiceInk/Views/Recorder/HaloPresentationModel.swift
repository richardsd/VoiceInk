import Combine
import Foundation

enum HaloPresentationPhase: Equatable, Sendable {
    case listening
    case transcribing
    case enhancing
    case reviewing

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

    var showsRawText: Bool {
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !raw.isEmpty && raw != final
    }
}

/// UI-only state for the Halo. It deliberately contains labels instead of
/// provider objects or credentials, which keeps its chips read-only and safe.
@MainActor
final class HaloPresentationModel: ObservableObject {
    @Published private(set) var phase: HaloPresentationPhase = .listening
    @Published private(set) var metadata = HaloPresentationMetadata()
    @Published private(set) var review: HaloReviewPresentation?
    @Published private(set) var reviewFeedback: PasteReviewFeedback?
    @Published private(set) var reviewSecondsRemaining: Int?
    @Published private(set) var isReviewDelivering = false

    func setPhase(_ phase: HaloPresentationPhase) {
        self.phase = phase
        if phase != .reviewing {
            clearReview()
        }
    }

    func setCapturedApplication(_ applicationName: String?) {
        metadata.applicationName = applicationName
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
        enhancementWarning: String?
    ) {
        metadata.modeName = modeName ?? metadata.modeName
        metadata.providerLabel = providerLabel ?? metadata.providerLabel
        metadata.connectionLabel = connectionLabel ?? metadata.connectionLabel
        metadata.modelLabel = modelLabel ?? metadata.modelLabel
        review = HaloReviewPresentation(
            rawText: rawText,
            finalText: finalText,
            enhancementWarning: enhancementWarning
        )
        phase = .reviewing
    }

    func clearReview() {
        review = nil
        reviewFeedback = nil
        reviewSecondsRemaining = nil
        isReviewDelivering = false
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
        phase = .listening
        metadata = HaloPresentationMetadata()
        review = nil
        reviewFeedback = nil
        reviewSecondsRemaining = nil
        isReviewDelivering = false
    }
}
