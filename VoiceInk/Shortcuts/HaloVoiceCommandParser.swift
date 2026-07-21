import Foundation

enum HaloVoiceCommand: Equatable, Sendable {
    case apply
    case copy
    case cancel
    case showLens(HaloReviewLens)
    case previousRevision
    case nextRevision
}

struct HaloVoiceCommandConfirmation: Equatable, Sendable {
    let id: UUID
    let reviewID: UUID
    let command: HaloVoiceCommand

    init(
        id: UUID = UUID(),
        reviewID: UUID,
        command: HaloVoiceCommand
    ) {
        precondition(command == .apply || command == .cancel)
        self.id = id
        self.reviewID = reviewID
        self.command = command
    }

    var title: String {
        switch command {
        case .apply:
            return String(localized: "Apply this version?")
        case .cancel:
            return String(localized: "Cancel this review?")
        case .copy, .showLens, .previousRevision, .nextRevision:
            return ""
        }
    }

    var confirmationLabel: String {
        switch command {
        case .apply:
            return String(localized: "Apply")
        case .cancel:
            return String(localized: "Cancel review")
        case .copy, .showLens, .previousRevision, .nextRevision:
            return ""
        }
    }
}

/// Recognizes the deliberately small, local-only Halo review command grammar.
/// Callers must supply a final recognition result; partial transcripts must
/// never be routed through this parser as executable commands.
enum HaloVoiceCommandParser {
    static func parse(_ finalTranscript: String) -> HaloVoiceCommand? {
        switch normalizedCommand(finalTranscript) {
        case "halo apply":
            return .apply
        case "halo copy":
            return .copy
        case "halo cancel":
            return .cancel
        case "halo show final":
            return .showLens(.final)
        case "halo show changes":
            return .showLens(.changes)
        case "halo show original":
            return .showLens(.original)
        case "halo previous version":
            return .previousRevision
        case "halo next version":
            return .nextRevision
        default:
            return nil
        }
    }

    private static func normalizedCommand(_ value: String) -> String {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)

        while let last = candidate.last, permittedTerminalPunctuation.contains(last) {
            candidate.removeLast()
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return candidate
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private static let permittedTerminalPunctuation: Set<Character> = [
        ".", "!", "?", "…",
    ]
}
