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

}
