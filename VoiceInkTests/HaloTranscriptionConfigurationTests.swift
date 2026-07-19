import Foundation
import Testing
@testable import VoiceInk

struct HaloTranscriptionConfigurationTests {
    @Test func resolvedRequestContextRemainsFrozenAfterDefaultsChange() {
        let defaults = UserDefaults.standard
        let key = "TranscriptionPrompt"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.set("Original prompt", forKey: key)
        let model = WhisperModel(
            name: "halo-test-model",
            displayName: "Halo test model",
            size: "1 MB",
            supportedLanguages: ["en": "English"],
            description: "Test model",
            speed: 1,
            accuracy: 1,
            ramUsage: 1
        )
        let configuration = TranscriptionRuntimeConfiguration(
            mode: nil,
            model: model,
            language: "en",
            isRealtimeEnabled: false
        )

        defaults.set("Changed later", forKey: key)

        #expect(configuration.requestContext.language == "en")
        #expect(configuration.requestContext.prompt == "Original prompt")
    }

    @Test func destinationRebindingPreservesFrozenTranscriptionRoute() throws {
        let model = CloudModel(
            name: "halo-cloud-test",
            displayName: "Halo cloud test",
            description: "Test model",
            provider: .groq,
            speed: 1,
            accuracy: 1,
            isMultilingual: true,
            supportedLanguages: ["en": "English"]
        )
        let configuration = TranscriptionRuntimeConfiguration(
            mode: nil,
            model: model,
            language: "en",
            isRealtimeEnabled: false,
            requestContext: TranscriptionRequestContext(
                language: "en",
                prompt: nil
            )
        )
        let review = PendingPasteReview(
            rawText: "Raw",
            finalText: "Final",
            payload: PreparedPastePayload(
                displayText: "Final",
                pastedText: "Final",
                autoSendKey: .none
            ),
            transcriptionConfiguration: configuration,
            refinementInputSnapshot: HaloRefinementInputSnapshot(
                originalModeRequirements: "Keep the frozen requirements.",
                customVocabulary: "VoiceInk"
            )
        )

        let rebound = review.withDestination(
            PasteReviewDestinationSnapshot(
                processID: 42,
                applicationName: "Editor",
                bundleIdentifier: "com.example.editor",
                focusedElementIdentity: nil
            )
        )
        let frozen = try #require(rebound.transcriptionConfiguration)

        #expect(frozen.model.name == "halo-cloud-test")
        #expect(frozen.model.provider == .groq)
        #expect(frozen.language == "en")
        #expect(frozen.requestContext.language == "en")
        #expect(
            rebound.refinementInputSnapshot
                == HaloRefinementInputSnapshot(
                    originalModeRequirements: "Keep the frozen requirements.",
                    customVocabulary: "VoiceInk"
                )
        )
    }
}
