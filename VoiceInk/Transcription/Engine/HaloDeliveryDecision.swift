import Foundation

enum HaloSessionDeliveryOverride: String, Equatable, Sendable {
    case forceDirect
    case forceReview
}

enum HaloEnhancementOutcome: Equatable, Sendable {
    case succeeded
    case rawFallback
}

enum HaloDeliveryDestinationState: Equatable, Sendable {
    /// The route is being selected before the asynchronous focus validation.
    case unresolved
    case valid
    case changed
}

enum HaloDeliveryRoute: Equatable, Sendable {
    case review
    case direct
}

enum HaloDeliveryRisk: Equatable, Hashable, Sendable {
    /// Auto-send turns a paste into an externally visible action, so the user
    /// should see the result before it is posted.
    case autoSend
    /// Enhancement did not produce a usable result and delivery is using the
    /// raw transcript instead.
    case rawFallback
    /// A successful enhancement returned no visible text.
    case emptyResult
    /// The enhanced result is dramatically shorter or longer than the raw
    /// transcript.
    case suspiciousLengthChange
    /// The enhanced result replaces a substantial share of the source words.
    case substantialRewrite
}

struct HaloDeliveryRiskAssessment: Equatable, Sendable {
    let risks: Set<HaloDeliveryRisk>

    static let none = HaloDeliveryRiskAssessment(risks: [])

    var requiresReview: Bool {
        !risks.isEmpty
    }

    /// A fixed, transcript-free explanation for why Review When Needed paused.
    /// Priority keeps one concise message even when several local signals fire.
    var reviewMessage: String? {
        if risks.contains(.rawFallback) {
            return String(localized: "Review suggested because enhancement was unavailable.")
        }
        if risks.contains(.emptyResult) {
            return String(localized: "Review suggested because the enhanced result is empty.")
        }
        if risks.contains(.suspiciousLengthChange) {
            return String(localized: "Review suggested because the result changed length substantially.")
        }
        if risks.contains(.substantialRewrite) {
            return String(localized: "Review suggested because the result was rewritten substantially.")
        }
        if risks.contains(.autoSend) {
            return String(localized: "Review suggested because this Mode will send immediately.")
        }
        return nil
    }
}

/// Pure, deterministic risk classification for `Review When Needed`.
///
/// The thresholds deliberately ignore small punctuation and cleanup changes.
/// A result is considered structurally suspicious when its visible length
/// changes by at least 50% and 12 characters, or by at least 25% and 48
/// characters. A same-length rewrite is caught separately when at least four
/// word/symbol units and half of the larger side were replaced.
enum HaloDeliveryRiskEvaluator {
    static func assess(
        rawText: String,
        finalText: String,
        autoSendEnabled: Bool,
        enhancementOutcome: HaloEnhancementOutcome
    ) -> HaloDeliveryRiskAssessment {
        var risks = Set<HaloDeliveryRisk>()

        if autoSendEnabled {
            risks.insert(.autoSend)
        }

        if enhancementOutcome == .rawFallback {
            risks.insert(.rawFallback)
        }

        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

        if enhancementOutcome == .succeeded, final.isEmpty {
            risks.insert(.emptyResult)
        }

        if hasSuspiciousLengthChange(raw: raw, final: final) {
            risks.insert(.suspiciousLengthChange)
        }

        if isSubstantialRewrite(raw: raw, final: final) {
            risks.insert(.substantialRewrite)
        }

        return HaloDeliveryRiskAssessment(risks: risks)
    }

    private static func hasSuspiciousLengthChange(raw: String, final: String) -> Bool {
        guard !raw.isEmpty, !final.isEmpty else { return false }

        let rawCount = raw.count
        let finalCount = final.count
        let absoluteDelta = abs(rawCount - finalCount)
        let relativeDelta = Double(absoluteDelta) / Double(max(rawCount, finalCount))

        return (absoluteDelta >= 12 && relativeDelta >= 0.50)
            || (absoluteDelta >= 48 && relativeDelta >= 0.25)
    }

    private static func isSubstantialRewrite(raw: String, final: String) -> Bool {
        guard !raw.isEmpty, !final.isEmpty, raw != final else { return false }

        let originalUnits = semanticUnits(in: raw)
        let revisedUnits = semanticUnits(in: final)
        let largerSideCount = max(originalUnits.count, revisedUnits.count)
        guard largerSideCount > 0 else { return false }

        // Keep delivery responsive for unusually long dictations. The bounded
        // multiset comparison is linear and deliberately conservative; normal
        // reviews continue to use the grouped, order-aware diff below.
        if max(raw.count, final.count) > 8_000 || largerSideCount > 1_000 {
            var remaining = Dictionary(grouping: originalUnits, by: { $0 })
                .mapValues(\.count)
            var commonCount = 0
            for unit in revisedUnits where remaining[unit, default: 0] > 0 {
                commonCount += 1
                remaining[unit, default: 0] -= 1
            }
            let changedUnitCount = max(
                originalUnits.count - commonCount,
                revisedUnits.count - commonCount
            )
            return changedUnitCount >= 4
                && Double(changedUnitCount) / Double(largerSideCount) >= 0.50
        }

        let diff = HaloReviewDiffEngine.compare(original: raw, revised: final)
        let removedUnitCount = diff.segments
            .filter { $0.operation == .removal }
            .reduce(0) { $0 + reviewUnitCount(in: $1.text) }
        let addedUnitCount = diff.segments
            .filter { $0.operation == .addition }
            .reduce(0) { $0 + reviewUnitCount(in: $1.text) }
        let changedUnitCount = max(removedUnitCount, addedUnitCount)
        let changedShare = Double(changedUnitCount) / Double(largerSideCount)

        return changedUnitCount >= 4 && changedShare >= 0.50
    }

    private static func reviewUnitCount(in text: String) -> Int {
        semanticUnits(in: text).count
    }

    private static func semanticUnits(in text: String) -> [String] {
        HaloReviewDiffEngine.tokenize(text).flatMap { token -> [String] in
            switch token.kind {
            case .word:
                let characters = token.text.map(String.init)
                if characters.contains(where: containsCJKScalar) {
                    return characters.map { $0.lowercased() }
                }
                return [token.text.lowercased()]
            case .symbol:
                return [token.text]
            case .punctuation, .whitespace, .lineBreak:
                return []
            }
        }
    }

    private static func containsCJKScalar(_ character: String) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, // Hiragana and Katakana
                0x3400...0x4DBF, // CJK Extension A
                0x4E00...0x9FFF, // Unified ideographs
                0xAC00...0xD7AF, // Hangul syllables
                0xF900...0xFAFF: // Compatibility ideographs
                return true
            default:
                return false
            }
        }
    }
}

struct HaloDeliveryDecisionContext: Equatable, Sendable {
    let policy: HaloDeliveryPolicy
    let enhancementOutcome: HaloEnhancementOutcome
    let sessionOverride: HaloSessionDeliveryOverride?
    let destinationState: HaloDeliveryDestinationState
    let riskAssessment: HaloDeliveryRiskAssessment

    init(
        policy: HaloDeliveryPolicy,
        enhancementOutcome: HaloEnhancementOutcome,
        sessionOverride: HaloSessionDeliveryOverride?,
        destinationState: HaloDeliveryDestinationState,
        riskAssessment: HaloDeliveryRiskAssessment = .none
    ) {
        self.policy = policy
        self.enhancementOutcome = enhancementOutcome
        self.sessionOverride = sessionOverride
        self.destinationState = destinationState
        self.riskAssessment = riskAssessment
    }
}

enum HaloDeliveryDecisionResolver {
    static func route(for context: HaloDeliveryDecisionContext) -> HaloDeliveryRoute {
        if context.destinationState == .changed {
            return .review
        }

        switch context.sessionOverride {
        case .forceDirect:
            return .direct
        case .forceReview:
            return .review
        case nil:
            break
        }

        switch (context.policy, context.enhancementOutcome) {
        case (.alwaysReview, _):
            return .review
        case (.reviewWhenNeeded, .succeeded):
            return context.riskAssessment.requiresReview ? .review : .direct
        case (.reviewWhenNeeded, .rawFallback):
            return .review
        case (.pasteImmediately, _):
            return .direct
        }
    }
}

enum HaloSessionDeliveryOverrideResolver {
    static func toggled(
        current: HaloSessionDeliveryOverride?,
        policy: HaloDeliveryPolicy
    ) -> HaloSessionDeliveryOverride? {
        if current != nil {
            return nil
        }

        return policy == .pasteImmediately ? .forceReview : .forceDirect
    }
}
