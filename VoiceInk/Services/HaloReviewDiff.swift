import Foundation

enum HaloReviewDiffTokenKind: String, Equatable, Sendable {
    case word
    case punctuation
    case whitespace
    case lineBreak
    case symbol
}

struct HaloReviewDiffToken: Equatable, Hashable, Sendable {
    let text: String
    let kind: HaloReviewDiffTokenKind
}

enum HaloReviewDiffOperation: String, Equatable, Sendable {
    case unchanged
    case addition
    case removal
}

struct HaloReviewDiffSegment: Equatable, Sendable {
    let operation: HaloReviewDiffOperation
    let text: String

    /// A ready-to-use VoiceOver description for a rendered diff run. The
    /// visual layer may localize or combine these descriptions further, but it
    /// never needs to infer meaning from color or strikethrough alone.
    var accessibilityLabel: String {
        let describedText = HaloReviewDiffAccessibility.describe(text)

        switch operation {
        case .unchanged:
            return String(
                format: String(localized: "Unchanged: %@"),
                describedText
            )
        case .addition:
            return String(
                format: String(localized: "Added: %@"),
                describedText
            )
        case .removal:
            return String(
                format: String(localized: "Removed: %@"),
                describedText
            )
        }
    }
}

enum HaloReviewDiffGroupKind: Equatable, Sendable {
    case unchanged
    case change
}

/// A readable diff phrase. A change group can contain removals, additions,
/// and short unchanged punctuation/whitespace bridges between those edits.
struct HaloReviewDiffGroup: Equatable, Sendable {
    let kind: HaloReviewDiffGroupKind
    let segments: [HaloReviewDiffSegment]

    var accessibilityLabel: String {
        segments
            .filter { kind == .unchanged || $0.operation != .unchanged }
            .map(\.accessibilityLabel)
            .joined(separator: ". ")
    }
}

struct HaloReviewDiffResult: Equatable, Sendable {
    let groups: [HaloReviewDiffGroup]

    var segments: [HaloReviewDiffSegment] {
        groups.flatMap(\.segments)
    }

    var hasChanges: Bool {
        segments.contains { $0.operation != .unchanged }
    }

    /// Reconstructing either side makes preservation straightforward to test
    /// and lets callers safely derive complete selectable text.
    var originalText: String {
        segments
            .filter { $0.operation != .addition }
            .map(\.text)
            .joined()
    }

    var revisedText: String {
        segments
            .filter { $0.operation != .removal }
            .map(\.text)
            .joined()
    }
}

struct HaloReviewDiffRequestKey: Equatable, Sendable {
    let sessionID: UUID
    let revisionID: UUID
    let original: String
    let revised: String
}

/// A small generation gate for asynchronous UI consumers. Diff computation is
/// intentionally pure; callers invalidate this gate when a task is cancelled
/// or a newer lens/revision wins, and publish only accepted results.
struct HaloReviewDiffRequestGate {
    private(set) var activeRequestID: UUID?
    private(set) var activeKey: HaloReviewDiffRequestKey?

    @discardableResult
    mutating func begin(_ key: HaloReviewDiffRequestKey) -> UUID {
        let requestID = UUID()
        activeRequestID = requestID
        activeKey = key
        return requestID
    }

    mutating func invalidate() {
        activeRequestID = nil
        activeKey = nil
    }

    func accepts(requestID: UUID, key: HaloReviewDiffRequestKey) -> Bool {
        activeRequestID == requestID && activeKey == key
    }
}

enum HaloReviewDiffEngine {
    static func compare(original: String, revised: String) -> HaloReviewDiffResult {
        let originalTokens = tokenize(original)
        let revisedTokens = tokenize(revised)
        let segments = coalescedSegments(
            originalTokens: originalTokens,
            revisedTokens: revisedTokens
        )

        return HaloReviewDiffResult(groups: groupedSegments(segments))
    }

    /// Splits text without normalizing it. Concatenating the token text always
    /// recreates the source byte-for-byte at the Swift `String` level.
    static func tokenize(_ source: String) -> [HaloReviewDiffToken] {
        guard !source.isEmpty else { return [] }

        var tokens: [HaloReviewDiffToken] = []

        for character in source {
            let text = String(character)
            let kind = tokenKind(for: character)

            if let lastIndex = tokens.indices.last,
               tokens[lastIndex].kind == kind,
               kind.canCoalesceCharacters {
                let previous = tokens[lastIndex]
                tokens[lastIndex] = HaloReviewDiffToken(
                    text: previous.text + text,
                    kind: kind
                )
            } else {
                tokens.append(HaloReviewDiffToken(text: text, kind: kind))
            }
        }

        return tokens
    }

    private static func coalescedSegments(
        originalTokens: [HaloReviewDiffToken],
        revisedTokens: [HaloReviewDiffToken]
    ) -> [HaloReviewDiffSegment] {
        let difference = revisedTokens.difference(from: originalTokens)
        var removalOffsets = Set<Int>()
        var insertionOffsets = Set<Int>()

        for change in difference {
            switch change {
            case .remove(let offset, _, _):
                removalOffsets.insert(offset)
            case .insert(let offset, _, _):
                insertionOffsets.insert(offset)
            }
        }

        var originalIndex = 0
        var revisedIndex = 0
        var segments: [HaloReviewDiffSegment] = []

        func append(_ operation: HaloReviewDiffOperation, _ text: String) {
            guard !text.isEmpty else { return }

            if let lastIndex = segments.indices.last,
               segments[lastIndex].operation == operation {
                let previous = segments[lastIndex]
                segments[lastIndex] = HaloReviewDiffSegment(
                    operation: operation,
                    text: previous.text + text
                )
            } else {
                segments.append(HaloReviewDiffSegment(operation: operation, text: text))
            }
        }

        while originalIndex < originalTokens.count || revisedIndex < revisedTokens.count {
            if originalIndex < originalTokens.count,
               removalOffsets.contains(originalIndex) {
                append(.removal, originalTokens[originalIndex].text)
                originalIndex += 1
                continue
            }

            if revisedIndex < revisedTokens.count,
               insertionOffsets.contains(revisedIndex) {
                append(.addition, revisedTokens[revisedIndex].text)
                revisedIndex += 1
                continue
            }

            if originalIndex < originalTokens.count,
               revisedIndex < revisedTokens.count,
               originalTokens[originalIndex] == revisedTokens[revisedIndex] {
                append(.unchanged, originalTokens[originalIndex].text)
                originalIndex += 1
                revisedIndex += 1
                continue
            }

            // `CollectionDifference` normally makes this fallback
            // unreachable. Keeping a lossless fallback avoids trapping if a
            // future token-equivalence rule makes the alignment ambiguous.
            if originalIndex < originalTokens.count {
                append(.removal, originalTokens[originalIndex].text)
                originalIndex += 1
            }
            if revisedIndex < revisedTokens.count {
                append(.addition, revisedTokens[revisedIndex].text)
                revisedIndex += 1
            }
        }

        return segments
    }

    private static func groupedSegments(
        _ segments: [HaloReviewDiffSegment]
    ) -> [HaloReviewDiffGroup] {
        var groups: [HaloReviewDiffGroup] = []
        var index = 0

        while index < segments.count {
            let segment = segments[index]

            guard segment.operation != .unchanged else {
                groups.append(HaloReviewDiffGroup(kind: .unchanged, segments: [segment]))
                index += 1
                continue
            }

            var changeSegments = [segment]
            index += 1

            while index < segments.count {
                let candidate = segments[index]

                if candidate.operation != .unchanged {
                    changeSegments.append(candidate)
                    index += 1
                    continue
                }

                let hasFollowingEdit = index + 1 < segments.count
                    && segments[index + 1].operation != .unchanged
                guard hasFollowingEdit, isPhraseBridge(candidate.text) else {
                    break
                }

                changeSegments.append(candidate)
                changeSegments.append(segments[index + 1])
                index += 2
            }

            groups.append(HaloReviewDiffGroup(kind: .change, segments: changeSegments))
        }

        return groups
    }

    private static func isPhraseBridge(_ text: String) -> Bool {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return false }

        return tokens.allSatisfy { token in
            token.kind == .whitespace || token.kind == .punctuation
        }
    }

    private static func tokenKind(for character: Character) -> HaloReviewDiffTokenKind {
        let scalars = character.unicodeScalars

        if scalars.allSatisfy({ $0.isHaloLineBreak }) {
            return .lineBreak
        }

        if scalars.allSatisfy({ $0.properties.isWhitespace }) {
            return .whitespace
        }

        if scalars.contains(where: { $0.isHaloWordScalar }),
           scalars.allSatisfy({ $0.isHaloWordScalar || $0.isHaloWordModifier }) {
            return .word
        }

        if scalars.allSatisfy({ $0.isHaloPunctuation || $0.isHaloWordModifier }) {
            return .punctuation
        }

        return .symbol
    }
}

private extension HaloReviewDiffTokenKind {
    var canCoalesceCharacters: Bool {
        switch self {
        case .word, .whitespace:
            return true
        case .punctuation, .lineBreak, .symbol:
            return false
        }
    }
}

private extension Unicode.Scalar {
    var isHaloLineBreak: Bool {
        switch value {
        case 0x000A, 0x000D, 0x0085, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }

    var isHaloWordScalar: Bool {
        switch properties.generalCategory {
        case .uppercaseLetter,
             .lowercaseLetter,
             .titlecaseLetter,
             .modifierLetter,
             .otherLetter,
             .decimalNumber,
             .letterNumber,
             .otherNumber,
             .connectorPunctuation:
            return true
        default:
            return false
        }
    }

    var isHaloWordModifier: Bool {
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format:
            return true
        default:
            return false
        }
    }

    var isHaloPunctuation: Bool {
        switch properties.generalCategory {
        case .dashPunctuation,
             .openPunctuation,
             .closePunctuation,
             .initialPunctuation,
             .finalPunctuation,
             .otherPunctuation:
            return true
        default:
            return false
        }
    }
}

private enum HaloReviewDiffAccessibility {
    static func describe(_ text: String) -> String {
        let tokens = HaloReviewDiffEngine.tokenize(text)
        guard !tokens.isEmpty else { return String(localized: "empty text") }

        return tokens.map { token in
            switch token.kind {
            case .lineBreak:
                return String(localized: "line break")
            case .whitespace:
                if token.text.contains("\t") {
                    return String(localized: "tab")
                }
                return String(localized: "space")
            case .word, .punctuation, .symbol:
                return token.text
            }
        }
        .joined(separator: " ")
    }
}
