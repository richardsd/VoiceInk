//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
@testable import VoiceInk
import Foundation

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

}
