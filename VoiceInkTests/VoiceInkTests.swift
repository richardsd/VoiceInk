//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
@testable import VoiceInk
import Foundation
import SwiftData

struct VoiceInkTests {

    @Test func modeConfigDecodesLegacyPowerModeWithoutOpenAIFields() throws {
        let legacyConfigJSON = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Legacy Power Mode",
          "emoji": "⚡️",
          "isAIEnhancementEnabled": true,
          "useScreenCapture": false,
          "selectedAIProvider": "OpenAI",
          "selectedAIModel": "gpt-5.2",
          "isAutoSendEnabled": false,
          "isEnabled": true,
          "isDefault": false
        }
        """#

        let config = try JSONDecoder().decode(ModeConfig.self, from: Data(legacyConfigJSON.utf8))

        #expect(config.icon.legacyEmojiValue == "⚡️")
        #expect(config.selectedOpenAIAuthMode == nil)
        #expect(config.selectedOpenAIOAuthModel == nil)
        #expect(config.openAIAuthMode == .apiKey)
        #expect(config.effectiveAIModel == "gpt-5.2")
    }

    @Test func modeConfigPrefersCodexModelForOpenAIOAuth() {
        let config = ModeConfig(
            name: "Codex",
            icon: .emoji("🤖"),
            isAIEnhancementEnabled: true,
            selectedAIProvider: AIProvider.openAI.rawValue,
            selectedAIModel: "gpt-5.2",
            selectedOpenAIAuthMode: OpenAIAuthMode.oauth.rawValue,
            selectedOpenAIOAuthModel: "gpt-5.3-codex"
        )

        #expect(config.openAIAuthMode == .oauth)
        #expect(config.effectiveAIModel == "gpt-5.3-codex")
    }

    @MainActor
    @Test func modeRuntimeResolverUsesModeCodexOAuthModelForEnhancement() throws {
        let defaults = UserDefaults.standard
        let originalAuthMode = defaults.string(forKey: "openAIAuthMode")
        let originalOAuthModel = defaults.string(forKey: "openAIOAuthModel")
        let originalPrompts = defaults.data(forKey: "customPrompts")
        defer {
            restoreDefault(originalAuthMode, forKey: "openAIAuthMode")
            restoreDefault(originalOAuthModel, forKey: "openAIOAuthModel")
            restoreDefault(originalPrompts, forKey: "customPrompts")
        }

        let aiService = AIService()
        aiService.openAIAuthMode = .apiKey
        aiService.isOAuthAuthenticated = true

        let container = try makeInMemoryModelContainer()
        let enhancementService = AIEnhancementService(
            aiService: aiService,
            modelContext: container.mainContext
        )
        let prompt = CustomPrompt(
            id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            title: "Codex Prompt",
            promptText: "Improve this",
            useSystemInstructions: false
        )
        enhancementService.customPrompts = [prompt]

        let mode = ModeConfig(
            name: "Codex Enhancement",
            isAIEnhancementEnabled: true,
            selectedPrompt: prompt.id.uuidString,
            selectedAIProvider: AIProvider.openAI.rawValue,
            selectedAIModel: "gpt-5.2",
            selectedOpenAIAuthMode: OpenAIAuthMode.oauth.rawValue,
            selectedOpenAIOAuthModel: "gpt-5.3-codex"
        )

        let configuration = ModeRuntimeResolver.currentEnhancementConfiguration(
            mode: mode,
            enhancementService: enhancementService,
            aiService: aiService
        )

        #expect(configuration.prompt?.id == prompt.id)
        #expect(configuration.provider == .openAI)
        #expect(configuration.openAIAuthMode == .oauth)
        #expect(configuration.modelName == "gpt-5.3-codex")
    }

    @Test func modeConfigDraftPreservesCodexOAuthFieldsWhenSaving() {
        let originalConfig = ModeConfig(
            name: "Codex",
            isAIEnhancementEnabled: true,
            selectedAIProvider: AIProvider.openAI.rawValue,
            selectedAIModel: "gpt-5.2",
            selectedOpenAIAuthMode: OpenAIAuthMode.oauth.rawValue,
            selectedOpenAIOAuthModel: "gpt-5.3-codex"
        )
        var draft = ModeConfigDraft(
            mode: .edit(originalConfig),
            modeManager: ModeManager.shared
        )

        draft.selectedOpenAIOAuthModel = "gpt-5.5"
        let updatedConfig = draft.makeConfig(mode: .edit(originalConfig))

        #expect(updatedConfig.selectedOpenAIAuthMode == OpenAIAuthMode.oauth.rawValue)
        #expect(updatedConfig.selectedOpenAIOAuthModel == "gpt-5.5")
        #expect(updatedConfig.effectiveAIModel == "gpt-5.5")
    }

    @Test func onboardingMigrationPreservesLegacyPowerModeConfigurations() throws {
        let isolatedDefaults = makeIsolatedDefaults()
        let defaults = isolatedDefaults.defaults
        defer { removeIsolatedDefaults(named: isolatedDefaults.suiteName) }

        let legacyConfigJSON = #"""
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy Power Mode",
            "emoji": "⚡️",
            "isAIEnhancementEnabled": true,
            "selectedPrompt": "00000000-0000-0000-0000-000000000001",
            "useScreenCapture": true,
            "isEnabled": true,
            "isDefault": true
          }
        ]
        """#

        defaults.set(true, forKey: "hasCompletedOnboarding")
        defaults.set(Data(legacyConfigJSON.utf8), forKey: "powerModeConfigurationsV2")

        OnboardingV2Migration.prepareIfNeeded(defaults: defaults)

        let migratedData = try #require(defaults.data(forKey: "modeConfigurationsV2"))
        let migratedConfigs = try JSONDecoder().decode([ModeConfig].self, from: migratedData)

        #expect(defaults.bool(forKey: "hasCompletedOnboardingV2"))
        #expect(defaults.bool(forKey: "hasPreparedOnboardingV2"))
        #expect(migratedConfigs.count == 1)
        #expect(migratedConfigs[0].name == "Legacy Power Mode")
        #expect(migratedConfigs[0].icon.legacyEmojiValue == "⚡️")
        #expect(migratedConfigs[0].useScreenCapture)
    }

    @Test func onboardingMigrationCreatesDefaultModeFromLegacyGlobalEnhancementSettings() throws {
        let isolatedDefaults = makeIsolatedDefaults()
        let defaults = isolatedDefaults.defaults
        defer { removeIsolatedDefaults(named: isolatedDefaults.suiteName) }

        defaults.set(true, forKey: "hasCompletedOnboarding")
        defaults.set(true, forKey: "isAIEnhancementEnabled")
        defaults.set(PromptTemplates.defaultPromptId.uuidString, forKey: "selectedPromptId")
        defaults.set(AIProvider.openAI.rawValue, forKey: "selectedAIProvider")
        defaults.set("gpt-5.2", forKey: "\(AIProvider.openAI.rawValue)SelectedModel")
        defaults.set(OpenAIAuthMode.oauth.rawValue, forKey: "openAIAuthMode")
        defaults.set("gpt-5.3-codex", forKey: "openAIOAuthModel")
        defaults.set(true, forKey: "useClipboardContext")
        defaults.set(true, forKey: "useScreenCaptureContext")
        defaults.set("parakeet-tdt-0.6b-v3", forKey: "CurrentTranscriptionModel")

        OnboardingV2Migration.prepareIfNeeded(defaults: defaults)

        let migratedData = try #require(defaults.data(forKey: "modeConfigurationsV2"))
        let migratedConfigs = try JSONDecoder().decode([ModeConfig].self, from: migratedData)
        let promptsData = try #require(defaults.data(forKey: "customPrompts"))
        let prompts = try JSONDecoder().decode([CustomPrompt].self, from: promptsData)

        #expect(migratedConfigs.count == 1)
        #expect(migratedConfigs[0].name == "Enhancement")
        #expect(migratedConfigs[0].isAIEnhancementEnabled)
        #expect(migratedConfigs[0].selectedPrompt == PromptTemplates.defaultPromptId.uuidString)
        #expect(migratedConfigs[0].selectedAIProvider == AIProvider.openAI.rawValue)
        #expect(migratedConfigs[0].selectedAIModel == "gpt-5.2")
        #expect(migratedConfigs[0].selectedOpenAIAuthMode == OpenAIAuthMode.oauth.rawValue)
        #expect(migratedConfigs[0].selectedOpenAIOAuthModel == "gpt-5.3-codex")
        #expect(migratedConfigs[0].useClipboardContext)
        #expect(migratedConfigs[0].useScreenCapture)
        #expect(prompts.contains { $0.id == PromptTemplates.defaultPromptId })
    }

    @Test func promptResolverConcatenatesParentThenChild() {
        let parentPrompt = CustomPrompt(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            title: "Prompt A",
            promptText: "Parent instructions",
            useSystemInstructions: false
        )
        let childPrompt = CustomPrompt(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            title: "Prompt B",
            promptText: "Child instructions",
            useSystemInstructions: false,
            parentPromptId: parentPrompt.id
        )

        let resolvedPrompt = PromptResolver.resolvedPromptText(for: childPrompt, in: [parentPrompt, childPrompt])

        #expect(resolvedPrompt == "Parent instructions\n\nChild instructions")
    }

    @Test func promptResolverAppliesWrapperOnlyFromSelectedPrompt() {
        let parentPrompt = CustomPrompt(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            title: "Prompt A",
            promptText: "Parent instructions",
            useSystemInstructions: false
        )
        let childPrompt = CustomPrompt(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            title: "Prompt B",
            promptText: "Child instructions",
            useSystemInstructions: true,
            parentPromptId: parentPrompt.id
        )

        let resolvedPrompt = PromptResolver.resolvedPromptText(for: childPrompt, in: [parentPrompt, childPrompt])

        #expect(resolvedPrompt.contains("Parent instructions\n\nChild instructions"))
        #expect(resolvedPrompt.contains("TRANSCRIPTION ENHANCER"))
    }

    @Test func promptResolverRejectsCircularParentAssignment() {
        let promptA = CustomPrompt(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            title: "Prompt A",
            promptText: "A",
            useSystemInstructions: false,
            parentPromptId: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        )
        let promptB = CustomPrompt(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            title: "Prompt B",
            promptText: "B",
            useSystemInstructions: false
        )

        let canAssign = PromptResolver.canAssignParent(promptA.id, to: promptB.id, in: [promptA, promptB])

        #expect(canAssign == false)
    }

    private func makeIsolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "VoiceInkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func removeIsolatedDefaults(named suiteName: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func restoreDefault(_ value: String?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func restoreDefault(_ value: Data?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makeInMemoryModelContainer() throws -> ModelContainer {
        let schema = Schema([
            Transcription.self,
            VocabularyWord.self,
            WordReplacement.self,
            SessionMetric.self
        ])
        let transcriptSchema = Schema([Transcription.self])
        let dictionarySchema = Schema([VocabularyWord.self, WordReplacement.self])
        let statsSchema = Schema([SessionMetric.self])

        return try ModelContainer(
            for: schema,
            configurations:
                ModelConfiguration("default", schema: transcriptSchema, isStoredInMemoryOnly: true),
                ModelConfiguration("dictionary", schema: dictionarySchema, isStoredInMemoryOnly: true),
                ModelConfiguration("stats", schema: statsSchema, isStoredInMemoryOnly: true)
        )
    }

}
