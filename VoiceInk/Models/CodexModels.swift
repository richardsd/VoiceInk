//
//  CodexModels.swift
//  VoiceInk
//
//  Model metadata for Codex OAuth models
//  Source: https://developers.openai.com/codex/models/
//  Last synced: 2026-03-17
//  Update checklist:
//  1) Verify model IDs in Codex docs match `id` values below
//  2) Update `status`/`isRecommended` when models are succeeded/promoted
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

struct CodexModelMetadata {
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
    static let all: [CodexModelMetadata] = [
        // GPT-5.4 Series
        CodexModelMetadata(
            id: "gpt-5.4",
            displayName: "GPT-5.4",
            description: "Flagship frontier model for professional work that brings the industry-leading coding capabilities of GPT-5.3-Codex together with stronger reasoning, tool use, and agentic workflows.",
            tier: .plus,
            status: .current,
            releaseDate: "2026-03",
            isRecommended: true,
            documentationURL: "https://developers.openai.com/codex/models#gpt-5-4"
        ),

        // GPT-5.3 Series
        CodexModelMetadata(
            id: "gpt-5.3-codex",
            displayName: "GPT-5.3-Codex",
            description: "Industry-leading coding model for complex software engineering. Its coding capabilities now also power GPT-5.4.",
            tier: .plus,
            status: .current,
            releaseDate: "2026-01",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/codex/models#gpt-5-3-codex"
        ),
        CodexModelMetadata(
            id: "gpt-5.3-codex-spark",
            displayName: "GPT-5.3-Codex-Spark",
            description: "Text-only research preview model optimized for near-instant, real-time coding iteration. Available to ChatGPT Pro users.",
            tier: .pro,
            status: .preview,
            releaseDate: "2026-01",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/codex/models#gpt-5-3-codex-spark"
        ),
        
        // GPT-5.2 Series
        CodexModelMetadata(
            id: "gpt-5.2-codex",
            displayName: "GPT-5.2-Codex",
            description: "Advanced coding model for real-world engineering. Succeeded by GPT-5.3-Codex.",
            tier: .plus,
            status: .legacy,
            releaseDate: "2025-11",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/codex/models#gpt-5-2-codex"
        ),
        CodexModelMetadata(
            id: "gpt-5.2",
            displayName: "GPT-5.2",
            description: "Previous general-purpose model for coding and agentic tasks across industries and domains. Succeeded by GPT-5.4.",
            tier: .plus,
            status: .legacy,
            releaseDate: "2025-11",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/codex/models#gpt-5-2"
        ),
        
        // GPT-5.1 Series
        CodexModelMetadata(
            id: "gpt-5.1-codex-max",
            displayName: "GPT-5.1-Codex-Max",
            description: "Optimized for long-horizon, agentic coding tasks in Codex.",
            tier: .plus,
            status: .legacy,
            releaseDate: "2025-09",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/codex/models#gpt-5-1-codex-max"
        ),
        CodexModelMetadata(
            id: "gpt-5.1",
            displayName: "GPT-5.1",
            description: "Great for coding and agentic tasks across domains. Succeeded by GPT-5.2.",
            tier: .plus,
            status: .legacy,
            releaseDate: "2025-08",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/codex/models#gpt-5-1"
        ),
        CodexModelMetadata(
            id: "gpt-5.1-codex",
            displayName: "GPT-5.1-Codex",
            description: "Optimized for long-running, agentic coding tasks in Codex. Succeeded by GPT-5.1-Codex-Max.",
            tier: .plus,
            status: .legacy,
            releaseDate: "2025-08",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/codex/models#gpt-5-1-codex"
        ),
        
        // GPT-5 Series (Legacy)
        CodexModelMetadata(
            id: "gpt-5-codex",
            displayName: "GPT-5-Codex",
            description: "Version of GPT-5 tuned for long-running, agentic coding tasks. Succeeded by GPT-5.1-Codex.",
            tier: .plus,
            status: .legacy,
            releaseDate: "2025-06",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/codex/models#gpt-5-codex"
        ),
        CodexModelMetadata(
            id: "gpt-5-codex-mini",
            displayName: "GPT-5-Codex-Mini",
            description: "Smaller, more cost-effective version of GPT-5-Codex. Succeeded by GPT-5.1-Codex-Mini.",
            tier: .plus,
            status: .legacy,
            releaseDate: "2025-06",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/codex/models#gpt-5-codex-mini"
        ),
        CodexModelMetadata(
            id: "gpt-5",
            displayName: "GPT-5",
            description: "Reasoning model for coding and agentic tasks across domains. Succeeded by GPT-5.1.",
            tier: .plus,
            status: .legacy,
            releaseDate: "2025-06",
            isRecommended: false,
            documentationURL: "https://developers.openai.com/codex/models#gpt-5"
        )
    ]
    
    static var sortedForPicker: [CodexModelMetadata] {
        all.sorted { lhs, rhs in
            // Recommended first
            if lhs.isRecommended != rhs.isRecommended {
                return lhs.isRecommended
            }
            // Current status models next
            if lhs.status == .current && rhs.status != .current {
                return true
            }
            if lhs.status != .current && rhs.status == .current {
                return false
            }
            // Preview before legacy
            if lhs.status == .preview && rhs.status == .legacy {
                return true
            }
            if lhs.status == .legacy && rhs.status == .preview {
                return false
            }
            // Newer models first (by release date descending)
            return lhs.releaseDate > rhs.releaseDate
        }
    }
    
    static func metadata(for modelId: String) -> CodexModelMetadata? {
        all.first { $0.id == modelId }
    }
}
