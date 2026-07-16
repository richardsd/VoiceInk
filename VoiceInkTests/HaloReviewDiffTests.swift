import Foundation
import Testing
@testable import VoiceInk

struct HaloReviewDiffTests {
    @Test func tokenizerPreservesUnicodePunctuationWhitespaceAndLineBreaks() {
        let source = "Café 👩🏽‍💻!\tline\r\n二"
        let tokens = HaloReviewDiffEngine.tokenize(source)

        #expect(tokens.map(\.kind) == [
            .word,
            .whitespace,
            .symbol,
            .punctuation,
            .whitespace,
            .word,
            .lineBreak,
            .word,
        ])
        #expect(tokens.map(\.text).joined() == source)
    }

    @Test func identicalTextProducesOneUnchangedGroup() {
        let source = "Hello, world!\nSecond line 👋"
        let result = HaloReviewDiffEngine.compare(original: source, revised: source)

        #expect(!result.hasChanges)
        #expect(result.groups.count == 1)
        #expect(result.groups.first?.kind == .unchanged)
        #expect(result.originalText == source)
        #expect(result.revisedText == source)
    }

    @Test func emptyInputsRemainLossless() {
        let bothEmpty = HaloReviewDiffEngine.compare(original: "", revised: "")
        let insertion = HaloReviewDiffEngine.compare(original: "", revised: "New text")
        let removal = HaloReviewDiffEngine.compare(original: "Old text", revised: "")

        #expect(bothEmpty.groups.isEmpty)
        #expect(!bothEmpty.hasChanges)
        #expect(insertion.segments.map(\.operation) == [.addition])
        #expect(removal.segments.map(\.operation) == [.removal])
        #expect(insertion.revisedText == "New text")
        #expect(removal.originalText == "Old text")
    }

    @Test func punctuationInsertionIsItsOwnVisibleChange() {
        let result = HaloReviewDiffEngine.compare(
            original: "Hello world",
            revised: "Hello, world"
        )

        #expect(result.originalText == "Hello world")
        #expect(result.revisedText == "Hello, world")
        #expect(
            result.segments.contains {
                $0.operation == .addition && $0.text == ","
            }
        )
    }

    @Test func adjacentWordEditsFormOneReadablePhraseGroup() {
        let result = HaloReviewDiffEngine.compare(
            original: "It is very bad, honestly.",
            revised: "It is quite good, honestly."
        )
        let changedGroups = result.groups.filter { $0.kind == .change }

        #expect(changedGroups.count == 1)
        #expect(changedGroups[0].segments.contains { $0.operation == .removal })
        #expect(changedGroups[0].segments.contains { $0.operation == .addition })
        #expect(result.originalText == "It is very bad, honestly.")
        #expect(result.revisedText == "It is quite good, honestly.")
    }

    @Test func paragraphContentKeepsDistantChangesInSeparateGroups() {
        let result = HaloReviewDiffEngine.compare(
            original: "Alpha bad\nBeta old",
            revised: "Alpha good\nBeta new"
        )
        let changedGroups = result.groups.filter { $0.kind == .change }

        #expect(changedGroups.count == 2)
        #expect(result.originalText == "Alpha bad\nBeta old")
        #expect(result.revisedText == "Alpha good\nBeta new")
    }

    @Test func whitespaceOnlyChangesArePreservedExactly() {
        let original = "one  two\tthree\nfour"
        let revised = "one two\t\tthree\n\nfour"
        let result = HaloReviewDiffEngine.compare(original: original, revised: revised)

        #expect(result.hasChanges)
        #expect(result.originalText == original)
        #expect(result.revisedText == revised)
    }

    @Test func unicodeAndEmojiReplacementPreservesBothSides() {
        let original = "Olá 🌍 — 東京"
        let revised = "Olá 🌏 — 東京都"
        let result = HaloReviewDiffEngine.compare(original: original, revised: revised)

        #expect(result.hasChanges)
        #expect(result.originalText == original)
        #expect(result.revisedText == revised)
        #expect(result.segments.contains { $0.operation == .removal && $0.text.contains("🌍") })
        #expect(result.segments.contains { $0.operation == .addition && $0.text.contains("🌏") })
    }

    @Test func accessibilityDescriptionsNameAdditionsAndRemovals() {
        let result = HaloReviewDiffEngine.compare(
            original: "old phrase",
            revised: "new phrase"
        )
        let changedGroup = result.groups.first { $0.kind == .change }

        #expect(changedGroup?.accessibilityLabel.contains("Removed:") == true)
        #expect(changedGroup?.accessibilityLabel.contains("Added:") == true)
    }

    @Test func longInputDiffRemainsLossless() {
        var originalWords = (0..<2_000).map { "word\($0)" }
        var revisedWords = originalWords
        originalWords[997] = "before"
        revisedWords[997] = "after"
        revisedWords.insert("🚀", at: 1_503)
        let original = originalWords.joined(separator: " ")
        let revised = revisedWords.joined(separator: " ")

        let result = HaloReviewDiffEngine.compare(original: original, revised: revised)

        #expect(result.hasChanges)
        #expect(result.originalText == original)
        #expect(result.revisedText == revised)
    }

    @Test func requestGateRejectsStaleAndCancelledBackgroundResults() {
        let sessionID = UUID()
        let firstKey = HaloReviewDiffRequestKey(
            sessionID: sessionID,
            revisionID: UUID(),
            original: "Raw",
            revised: "First"
        )
        let secondKey = HaloReviewDiffRequestKey(
            sessionID: sessionID,
            revisionID: UUID(),
            original: "First",
            revised: "Second"
        )
        var gate = HaloReviewDiffRequestGate()

        let firstID = gate.begin(firstKey)
        #expect(gate.accepts(requestID: firstID, key: firstKey))

        let secondID = gate.begin(secondKey)
        #expect(!gate.accepts(requestID: firstID, key: firstKey))
        #expect(gate.accepts(requestID: secondID, key: secondKey))

        gate.invalidate()
        #expect(!gate.accepts(requestID: secondID, key: secondKey))
    }
}
