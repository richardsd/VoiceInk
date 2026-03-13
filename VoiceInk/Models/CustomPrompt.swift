import Foundation
import SwiftUI

struct CustomPrompt: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let promptText: String
    let triggerWords: [String]
    let useSystemInstructions: Bool
    let parentPromptId: UUID?
    
    init(
        id: UUID = UUID(),
        title: String,
        promptText: String,
        triggerWords: [String] = [],
        useSystemInstructions: Bool = true,
        parentPromptId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.promptText = promptText
        self.triggerWords = Self.normalizedTriggerWords(triggerWords)
        self.useSystemInstructions = useSystemInstructions
        self.parentPromptId = parentPromptId
    }

    enum CodingKeys: String, CodingKey {
        case id, title, promptText, triggerWords, useSystemInstructions, parentPromptId
        case legacyTriggerWord = "triggerWord"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        promptText = try container.decode(String.self, forKey: .promptText)
        let decodedTriggerWords = try container.decodeIfPresent([String].self, forKey: .triggerWords)
        let legacyTriggerWord = try container.decodeIfPresent(String.self, forKey: .legacyTriggerWord)
        triggerWords = Self.normalizedTriggerWords(
            decodedTriggerWords ?? legacyTriggerWord.map { [$0] } ?? []
        )
        useSystemInstructions = try container.decodeIfPresent(Bool.self, forKey: .useSystemInstructions) ?? true
        parentPromptId = try container.decodeIfPresent(UUID.self, forKey: .parentPromptId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(promptText, forKey: .promptText)
        if !triggerWords.isEmpty {
            try container.encode(triggerWords, forKey: .triggerWords)
        }
        try container.encode(useSystemInstructions, forKey: .useSystemInstructions)
        try container.encodeIfPresent(parentPromptId, forKey: .parentPromptId)
    }

    private static func normalizedTriggerWords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.compactMap { word in
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    var finalPromptText: String {
        if useSystemInstructions {
            return String(format: AIPrompts.enhancementSystemTemplate, self.promptText)
        } else {
            return self.promptText
        }
    }
}

struct PromptResolver {
    static let maxInheritanceDepth = 8

    static func resolvedPromptText(for prompt: CustomPrompt, in prompts: [CustomPrompt]) -> String {
        let resolvedBody = resolvedPromptBody(for: prompt, in: prompts)
        if prompt.useSystemInstructions {
            return String(format: AIPrompts.enhancementSystemTemplate, resolvedBody)
        }
        return resolvedBody
    }

    static func resolvedPromptBody(for prompt: CustomPrompt, in prompts: [CustomPrompt]) -> String {
        let promptLookup = Dictionary(uniqueKeysWithValues: prompts.map { ($0.id, $0) })
        var visited = Set<UUID>()
        return resolveSegments(for: prompt, promptLookup: promptLookup, visited: &visited, depth: 0)
            .joined(separator: "\n\n")
    }

    static func canAssignParent(_ parentId: UUID?, to promptId: UUID?, in prompts: [CustomPrompt]) -> Bool {
        guard let parentId else { return true }
        guard let promptId else { return true }
        guard parentId != promptId else { return false }

        let promptLookup = Dictionary(uniqueKeysWithValues: prompts.map { ($0.id, $0) })
        var currentId: UUID? = parentId
        var visited = Set<UUID>()
        var depth = 0

        while let candidateId = currentId,
              let prompt = promptLookup[candidateId],
              depth < maxInheritanceDepth {
            if candidateId == promptId || visited.contains(candidateId) {
                return false
            }
            visited.insert(candidateId)
            currentId = prompt.parentPromptId
            depth += 1
        }

        return depth < maxInheritanceDepth || currentId == nil
    }

    static func availableParentPrompts(for promptId: UUID?, in prompts: [CustomPrompt]) -> [CustomPrompt] {
        prompts.filter { candidate in
            canAssignParent(candidate.id, to: promptId, in: prompts)
        }
    }

    private static func resolveSegments(
        for prompt: CustomPrompt,
        promptLookup: [UUID: CustomPrompt],
        visited: inout Set<UUID>,
        depth: Int
    ) -> [String] {
        guard depth < maxInheritanceDepth else {
            return [prompt.promptText]
        }

        var segments: [String] = []
        visited.insert(prompt.id)

        if let parentPromptId = prompt.parentPromptId,
           let parentPrompt = promptLookup[parentPromptId],
           !visited.contains(parentPrompt.id) {
            segments.append(contentsOf: resolveSegments(
                for: parentPrompt,
                promptLookup: promptLookup,
                visited: &visited,
                depth: depth + 1
            ))
        }

        segments.append(prompt.promptText)
        return segments
    }
}

// MARK: - UI Extensions
extension CustomPrompt {
    func promptIcon(
        isSelected: Bool, onTap: @escaping () -> Void, onEdit: ((CustomPrompt) -> Void)? = nil,
        onDelete: ((CustomPrompt) -> Void)? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)

            if !triggerWords.isEmpty {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityLabel("Has trigger words")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, minHeight: 30)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? AppTheme.Accent.primary : AppTheme.Surface.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(AppTheme.Border.control, lineWidth: isSelected ? 0 : 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let onEdit = onEdit {
                onEdit(self)
            }
        }
        .onTapGesture(count: 1) {
            onTap()
        }
        .contextMenu {
            if onEdit != nil || onDelete != nil {
                if let onEdit = onEdit {
                    Button {
                        onEdit(self)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }

                if let onDelete = onDelete {
                    Button(role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = String(localized: "Delete Prompt?")
                        alert.informativeText = String(
                            format: String(
                                localized: "Are you sure you want to delete '%@' prompt? This action cannot be undone."),
                            self.title)
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: String(localized: "Delete"))
                        alert.addButton(withTitle: String(localized: "Cancel"))

                        let response = alert.runModal()
                        if response == .alertFirstButtonReturn {
                            onDelete(self)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    static func addNewButton(action: @escaping () -> Void) -> some View {
        Label("Add New", systemImage: "plus.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(AppTheme.Surface.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(AppTheme.Border.control, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}
