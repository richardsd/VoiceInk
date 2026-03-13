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

    @Test func powerModeConfigDecodesLegacyWithoutOpenAIFields() throws {
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

        let config = try JSONDecoder().decode(PowerModeConfig.self, from: Data(legacyConfigJSON.utf8))

        #expect(config.selectedOpenAIAuthMode == nil)
        #expect(config.selectedOpenAIOAuthModel == nil)
        #expect(config.openAIAuthMode == .apiKey)
        #expect(config.effectiveAIModel == "gpt-5.2")
    }

    @Test func powerModeConfigPrefersCodexModelForOpenAIOAuth() {
        let config = PowerModeConfig(
            name: "Codex",
            emoji: "🤖",
            isAIEnhancementEnabled: true,
            selectedAIProvider: AIProvider.openAI.rawValue,
            selectedAIModel: "gpt-5.2",
            selectedOpenAIAuthMode: OpenAIAuthMode.oauth.rawValue,
            selectedOpenAIOAuthModel: "gpt-5.3-codex"
        )

        #expect(config.openAIAuthMode == .oauth)
        #expect(config.effectiveAIModel == "gpt-5.3-codex")
    }

    @Test func powerModeValidatorRejectsOpenAIOAuthWithoutAuthentication() {
        let originalConfigurations = PowerModeManager.shared.configurations
        defer {
            PowerModeManager.shared.configurations = originalConfigurations
        }

        PowerModeManager.shared.configurations = []

        let config = PowerModeConfig(
            name: "Codex",
            emoji: "🤖",
            isAIEnhancementEnabled: true,
            selectedAIProvider: AIProvider.openAI.rawValue,
            selectedOpenAIAuthMode: OpenAIAuthMode.oauth.rawValue,
            selectedOpenAIOAuthModel: "gpt-5.3-codex"
        )

        let validator = PowerModeValidator(
            powerModeManager: PowerModeManager.shared,
            isOpenAIOAuthAuthenticated: false
        )
        let errors = validator.validateForSave(config: config, mode: .add)

        #expect(errors.contains(.openAIOAuthAuthenticationRequired))
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

}
