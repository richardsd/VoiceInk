import Foundation
import Testing
@testable import VoiceInk

struct HaloDeliveryPolicyTests {
    @Test func legacyModeDecodesWithAlwaysReviewPolicy() throws {
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Legacy Paste Mode",
          "icon": { "kind": "symbol", "value": "mic.fill" },
          "isAIEnhancementEnabled": false,
          "useClipboardContext": false,
          "useSelectedTextContext": true,
          "useScreenCapture": false,
          "outputMode": "paste"
        }
        """#

        let config = try JSONDecoder().decode(ModeConfig.self, from: Data(json.utf8))

        #expect(config.haloDeliveryPolicy == .alwaysReview)
    }

    @Test func modePolicyRoundTripsThroughCodableStorage() throws {
        let config = ModeConfig(
            name: "Quick Paste",
            isAIEnhancementEnabled: true,
            outputMode: .paste,
            haloDeliveryPolicy: .pasteImmediately
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ModeConfig.self, from: data)

        #expect(decoded.haloDeliveryPolicy == .pasteImmediately)
    }

    @Test func newModeDefaultsToReviewWhenNeededAndPreservesPolicyAcrossOutputChanges() {
        var draft = ModeConfigDraft(mode: .add, modeManager: .shared)
        #expect(draft.haloDeliveryPolicy == .reviewWhenNeeded)

        draft.haloDeliveryPolicy = .pasteImmediately
        draft.outputMode = .customCommand
        draft.applyOutputRules(canRespond: true)
        draft.outputMode = .paste
        draft.applyOutputRules(canRespond: true)

        #expect(draft.haloDeliveryPolicy == .pasteImmediately)
        #expect(draft.makeConfig(mode: .add).haloDeliveryPolicy == .pasteImmediately)
    }

    @Test func editingModePreservesExplicitPolicy() {
        let original = ModeConfig(
            name: "Careful Paste",
            isAIEnhancementEnabled: false,
            outputMode: .paste,
            haloDeliveryPolicy: .alwaysReview
        )
        let draft = ModeConfigDraft(mode: .edit(original), modeManager: .shared)

        #expect(draft.haloDeliveryPolicy == .alwaysReview)
        #expect(draft.makeConfig(mode: .edit(original)).haloDeliveryPolicy == .alwaysReview)
    }

    @Test func starterPasteModesDefaultToReviewWhenNeeded() {
        for template in StarterModeCatalog.templates where template.outputMode == .paste {
            #expect(template.haloDeliveryPolicy == .reviewWhenNeeded)
        }
    }

    @MainActor
    @Test func outputRuntimeConfigurationUsesTheFinalResolvedModesPolicy() {
        let initialMode = ModeConfig(
            name: "Initial",
            isAIEnhancementEnabled: false,
            haloDeliveryPolicy: .alwaysReview
        )
        let triggerWordMode = ModeConfig(
            name: "Triggered",
            isAIEnhancementEnabled: false,
            haloDeliveryPolicy: .pasteImmediately
        )

        let initial = ModeRuntimeResolver.outputConfiguration(mode: initialMode)
        let resolvedAfterTrigger = ModeRuntimeResolver.outputConfiguration(mode: triggerWordMode)

        #expect(initial.haloDeliveryPolicy == .alwaysReview)
        #expect(resolvedAfterTrigger.haloDeliveryPolicy == .pasteImmediately)
        #expect(resolvedAfterTrigger.mode?.id == triggerWordMode.id)
    }
}
