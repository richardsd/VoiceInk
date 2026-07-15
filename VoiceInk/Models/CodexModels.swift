//
//  CodexModels.swift
//  VoiceInk
//
//  Model metadata for Codex OAuth models
//  Sources:
//  - https://developers.openai.com/api/docs/models
//  - https://developers.openai.com/api/docs/models/all
//  Last synced: 2026-07-15
//  Update checklist:
//  1) Verify model IDs in OpenAI docs match `id` values below
//  2) Update `status`/`isRecommended` when models are promoted or deprecated
//  3) Keep OAuth default model in AIService aligned with recommended model
//  4) Refresh this sync date
//

import Foundation

// MARK: - Subscription Tier

enum SubscriptionTier: String, Codable {
    case plus = "Plus"
    case pro = "Pro"
    case api = "API"

    var color: String {
        switch self {
        case .plus: return "blue"
        case .pro: return "purple"
        case .api: return "gray"
        }
    }
}

// MARK: - Model Status

enum ModelStatus: String, Codable {
    case current = "Current"
    case preview = "Preview"
    case legacy = "Legacy"
    case deprecated = "Deprecated"

    var color: String {
        switch self {
        case .current: return "green"
        case .preview: return "orange"
        case .legacy: return "gray"
        case .deprecated: return "red"
        }
    }
}

// MARK: - Model Metadata

struct CodexModelMetadata: Codable, Equatable {
    let id: String
    let displayName: String
    let description: String
    let tier: SubscriptionTier
    let status: ModelStatus
    let releaseDate: String
    let isRecommended: Bool
    let documentationURL: String
}

// MARK: - Available Codex Models

enum CodexModels {
    static let fallbackModels: [CodexModelMetadata] = [
        // Current GPT-5.6 family recommended for ChatGPT sign-in.
        CodexModelMetadata(
            id: "gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            description: "Flagship model for complex, open-ended work that needs maximum depth and polish.",
            tier: .plus,
            status: .current,
            releaseDate: "2026-07",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5.6-sol"
        ),
        CodexModelMetadata(
            id: "gpt-5.6-terra",
            displayName: "GPT-5.6 Terra",
            description: "Balanced everyday model for strong reasoning and tool use with lower latency.",
            tier: .plus,
            status: .current,
            releaseDate: "2026-07",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5.6-terra"
        ),
        CodexModelMetadata(
            id: "gpt-5.6-luna",
            displayName: "GPT-5.6 Luna",
            description: "Fast model for clear, repeatable transformations such as transcript cleanup.",
            tier: .plus,
            status: .current,
            releaseDate: "2026-07",
            isRecommended: true,
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5.6-luna"
        ),

        // Current recommended frontier models
        CodexModelMetadata(
            id: "gpt-5.5",
            displayName: "GPT-5.5",
            description: "Previous-generation frontier model retained for compatibility.",
            tier: .plus,
            status: .legacy,
            releaseDate: "2026-05",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5.5"
        ),
        CodexModelMetadata(
            id: "gpt-5.4",
            displayName: "GPT-5.4",
            description: "Best intelligence at scale for agentic, coding, and professional workflows.",
            tier: .plus,
            status: .current,
            releaseDate: "2026-03",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5.4"
        ),
        CodexModelMetadata(
            id: "gpt-5.4-mini",
            displayName: "GPT-5.4 mini",
            description: "Strong mini model for coding, computer use, and subagents.",
            tier: .plus,
            status: .current,
            releaseDate: "2026-03",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5.4-mini"
        ),
        CodexModelMetadata(
            id: "gpt-5.4-nano",
            displayName: "GPT-5.4 nano",
            description: "Cheapest GPT-5.4-class model for simple, high-volume tasks and subagents.",
            tier: .plus,
            status: .current,
            releaseDate: "2026-03",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5.4-nano"
        ),
        CodexModelMetadata(
            id: "gpt-5-mini",
            displayName: "GPT-5 mini",
            description: "Faster, cheaper GPT-5 variant for well-defined low-latency work.",
            tier: .plus,
            status: .current,
            releaseDate: "2025-08",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5-mini"
        ),
        CodexModelMetadata(
            id: "gpt-5-nano",
            displayName: "GPT-5 nano",
            description: "Fastest, lowest-cost GPT-5 variant for summarization and classification.",
            tier: .plus,
            status: .current,
            releaseDate: "2025-08",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5-nano"
        ),

        // Current coding-specialized model
        CodexModelMetadata(
            id: "gpt-5.3-codex",
            displayName: "GPT-5.3-Codex",
            description: "Deprecated coding-specialized model retained for compatibility with saved selections.",
            tier: .plus,
            status: .deprecated,
            releaseDate: "2026-02",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5.3-codex"
        ),
        CodexModelMetadata(
            id: "gpt-5.3-codex-spark",
            displayName: "GPT-5.3-Codex-Spark",
            description: "Research preview model retained for compatibility with older selections.",
            tier: .pro,
            status: .preview,
            releaseDate: "2026-02",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/all"
        ),

        // Previous but still documented frontier model
        CodexModelMetadata(
            id: "gpt-5",
            displayName: "GPT-5",
            description: "Previous GPT-5 reasoning model for coding and agentic tasks.",
            tier: .plus,
            status: .legacy,
            releaseDate: "2025-08",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5"
        ),
        CodexModelMetadata(
            id: "gpt-5.2",
            displayName: "GPT-5.2",
            description: "Deprecated ChatGPT-sign-in model retained for compatibility.",
            tier: .plus,
            status: .deprecated,
            releaseDate: "2025-11",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/all"
        ),
        CodexModelMetadata(
            id: "gpt-5.1",
            displayName: "GPT-5.1",
            description: "Previous GPT-5.1 model retained for compatibility.",
            tier: .plus,
            status: .legacy,
            releaseDate: "2025-08",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/all"
        ),

        // Deprecated coding models retained for compatibility with saved selections
        CodexModelMetadata(
            id: "gpt-5.2-codex",
            displayName: "GPT-5.2-Codex",
            description: "Deprecated long-horizon coding model retained for compatibility.",
            tier: .plus,
            status: .deprecated,
            releaseDate: "2025-11",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5.2-codex"
        ),
        CodexModelMetadata(
            id: "gpt-5.1-codex-max",
            displayName: "GPT-5.1-Codex-Max",
            description: "Deprecated long-running Codex model retained for compatibility.",
            tier: .plus,
            status: .deprecated,
            releaseDate: "2025-09",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5.1-codex-max"
        ),
        CodexModelMetadata(
            id: "gpt-5.1-codex",
            displayName: "GPT-5.1 Codex",
            description: "Deprecated Codex model retained for compatibility with older selections.",
            tier: .plus,
            status: .deprecated,
            releaseDate: "2025-08",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5.1-codex"
        ),
        CodexModelMetadata(
            id: "gpt-5.1-codex-mini",
            displayName: "GPT-5.1 Codex mini",
            description: "Deprecated smaller Codex model retained for compatibility.",
            tier: .plus,
            status: .deprecated,
            releaseDate: "2025-08",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5.1-codex-mini"
        ),
        CodexModelMetadata(
            id: "gpt-5-codex",
            displayName: "GPT-5-Codex",
            description: "Deprecated GPT-5 Codex variant retained for compatibility.",
            tier: .plus,
            status: .deprecated,
            releaseDate: "2025-08",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/gpt-5-codex"
        ),
        CodexModelMetadata(
            id: "gpt-5-codex-mini",
            displayName: "GPT-5-Codex-Mini",
            description: "Deprecated smaller GPT-5 Codex variant retained for compatibility.",
            tier: .plus,
            status: .deprecated,
            releaseDate: "2025-08",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/all"
        ),
        CodexModelMetadata(
            id: "codex-mini-latest",
            displayName: "codex-mini-latest",
            description: "Deprecated Codex CLI model retained for compatibility with older saved configs.",
            tier: .plus,
            status: .deprecated,
            releaseDate: "2025-08",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/api/docs/models/all"
        )
    ]

    static var sortedForPicker: [CodexModelMetadata] {
        sortedForPicker(fallbackModels)
    }

    static func sortedForPicker(_ models: [CodexModelMetadata]) -> [CodexModelMetadata] {
        models.sorted { lhs, rhs in
            if lhs.isRecommended != rhs.isRecommended {
                return lhs.isRecommended
            }
            if lhs.status == .current && rhs.status != .current {
                return true
            }
            if lhs.status != .current && rhs.status == .current {
                return false
            }
            if lhs.status == .preview && rhs.status == .legacy {
                return true
            }
            if lhs.status == .legacy && rhs.status == .preview {
                return false
            }
            if lhs.status == .legacy && rhs.status == .deprecated {
                return true
            }
            if lhs.status == .deprecated && rhs.status == .legacy {
                return false
            }
            if lhs.releaseDate != rhs.releaseDate {
                return lhs.releaseDate > rhs.releaseDate
            }
            return lhs.id < rhs.id
        }
    }

    static func metadata(for modelId: String) -> CodexModelMetadata? {
        fallbackModels.first { $0.id == modelId }
    }

    static func isCodexOAuthCandidate(_ modelId: String) -> Bool {
        modelId.hasPrefix("gpt-5") || modelId.localizedCaseInsensitiveContains("codex")
    }
}
