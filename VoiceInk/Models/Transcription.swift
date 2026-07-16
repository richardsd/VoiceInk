import Foundation
import SwiftData

enum TranscriptionStatus: String, Codable {
    case pending
    case completed
    case failed
    case canceled
}

@Model
final class Transcription {
    static let canceledTranscriptionText = "The transcription was canceled."

    var id: UUID = UUID()
    var text: String = ""
    var enhancedText: String?
    var finalizedText: String?
    var timestamp: Date = Date()
    var duration: TimeInterval = 0
    var audioFileURL: String?
    var transcriptionModelName: String?
    var aiEnhancementModelName: String?
    var promptName: String?
    var transcriptionDuration: TimeInterval?
    var enhancementDuration: TimeInterval?
    var aiRequestSystemMessage: String?
    var aiRequestUserMessage: String?
    @Attribute(originalName: "powerModeName")
    var modeName: String?
    @Attribute(originalName: "powerModeEmoji")
    var modeEmoji: String?
    var transcriptionStatus: String?

    init(
        text: String,
        duration: TimeInterval,
        enhancedText: String? = nil,
        finalizedText: String? = nil,
        audioFileURL: String? = nil,
        transcriptionModelName: String? = nil,
        aiEnhancementModelName: String? = nil,
        promptName: String? = nil,
        transcriptionDuration: TimeInterval? = nil,
        enhancementDuration: TimeInterval? = nil,
        aiRequestSystemMessage: String? = nil,
        aiRequestUserMessage: String? = nil,
        modeName: String? = nil,
        modeEmoji: String? = nil,
        transcriptionStatus: TranscriptionStatus = .pending
    ) {
        self.id = UUID()
        self.text = text
        self.enhancedText = enhancedText
        self.finalizedText = finalizedText
        self.timestamp = Date()
        self.duration = duration
        self.audioFileURL = audioFileURL
        self.transcriptionModelName = transcriptionModelName
        self.aiEnhancementModelName = aiEnhancementModelName
        self.promptName = promptName
        self.transcriptionDuration = transcriptionDuration
        self.enhancementDuration = enhancementDuration
        self.aiRequestSystemMessage = aiRequestSystemMessage
        self.aiRequestUserMessage = aiRequestUserMessage
        self.modeName = modeName
        self.modeEmoji = modeEmoji
        self.transcriptionStatus = transcriptionStatus.rawValue
    }

    func markAsCanceledTranscription(
        duration: TimeInterval? = nil,
        modelName: String? = nil
    ) {
        text = Self.canceledTranscriptionText
        enhancedText = nil
        finalizedText = nil
        transcriptionStatus = TranscriptionStatus.canceled.rawValue
        if let duration {
            self.duration = duration
        }
        if let modelName {
            transcriptionModelName = modelName
        }
        transcriptionDuration = nil
        enhancementDuration = nil
        aiEnhancementModelName = nil
        promptName = nil
        aiRequestSystemMessage = nil
        aiRequestUserMessage = nil
    }

    /// The result a user ultimately chose, falling back through each earlier
    /// stage for transcriptions that predate Halo finalization.
    var displayedResultText: String {
        finalizedText ?? usableEnhancedText ?? text
    }

    /// Enhancement failures have historically been stored in `enhancedText`.
    /// They remain available to exports and diagnostics, but must never become
    /// the canonical text copied, pasted, searched, or previewed for the user.
    var usableEnhancedText: String? {
        guard let enhancedText else { return nil }
        let trimmed = enhancedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.range(
            of: "Enhancement failed:",
            options: [.caseInsensitive, .anchored]
        ) == nil else {
            return nil
        }
        return enhancedText
    }
}

enum TranscriptionHistorySearch {
    static func predicate(
        matching searchText: String,
        before timestamp: Date? = nil
    ) -> Predicate<Transcription> {
        if let timestamp {
            return #Predicate<Transcription> { transcription in
                (transcription.text.localizedStandardContains(searchText)
                    || (transcription.enhancedText?.localizedStandardContains(searchText) ?? false)
                    || (transcription.finalizedText?.localizedStandardContains(searchText) ?? false))
                    && transcription.timestamp < timestamp
            }
        }

        return #Predicate<Transcription> { transcription in
            transcription.text.localizedStandardContains(searchText)
                || (transcription.enhancedText?.localizedStandardContains(searchText) ?? false)
                || (transcription.finalizedText?.localizedStandardContains(searchText) ?? false)
        }
    }
}
