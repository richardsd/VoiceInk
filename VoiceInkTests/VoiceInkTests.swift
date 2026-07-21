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

    @Test func openAIConnectionPolicyKeepsBothConnectionsIndependent() {
        #expect(AIService.configuredOpenAIAuthModes(hasAPIKey: false, hasOAuthSession: false).isEmpty)
        #expect(AIService.configuredOpenAIAuthModes(hasAPIKey: true, hasOAuthSession: false) == [.apiKey])
        #expect(AIService.configuredOpenAIAuthModes(hasAPIKey: false, hasOAuthSession: true) == [.oauth])
        #expect(AIService.configuredOpenAIAuthModes(hasAPIKey: true, hasOAuthSession: true) == [.oauth, .apiKey])

        #expect(AIService.preferredOpenAIAuthMode(hasAPIKey: true, hasOAuthSession: true) == .oauth)
        #expect(AIService.preferredOpenAIAuthMode(hasAPIKey: true, hasOAuthSession: false) == .apiKey)
        #expect(AIService.preferredOpenAIAuthMode(hasAPIKey: false, hasOAuthSession: false) == .oauth)
    }

    @Test func codexOAuthCatalogUsesLunaAndRetainsLegacySelections() throws {
        #expect(AIService.fallbackOpenAIOAuthModel == "gpt-5.6-luna")
        #expect(CodexModels.sortedForPicker.first(where: \.isRecommended)?.id == "gpt-5.6-luna")
        #expect(CodexModels.metadata(for: "gpt-5.6-sol")?.status == .current)
        #expect(CodexModels.metadata(for: "gpt-5.6-terra")?.status == .current)
        #expect(CodexModels.metadata(for: "gpt-5.5")?.status == .legacy)
        #expect(CodexModels.metadata(for: "gpt-5.3-codex")?.status == .deprecated)
        #expect(CodexModels.metadata(for: "gpt-5.2")?.status == .deprecated)

        let savedMode = ModeConfig(
            name: "Existing OAuth Mode",
            isAIEnhancementEnabled: true,
            selectedAIProvider: AIProvider.openAI.rawValue,
            selectedOpenAIAuthMode: OpenAIAuthMode.oauth.rawValue,
            selectedOpenAIOAuthModel: "gpt-5.5"
        )
        let encoded = try JSONEncoder().encode(savedMode)
        let decoded = try JSONDecoder().decode(ModeConfig.self, from: encoded)
        #expect(decoded.selectedOpenAIOAuthModel == "gpt-5.5")
    }

    @MainActor
    @Test func explicitDisconnectedProviderIsNotSilentlyReplaced() {
        let resolved = ModeRuntimeResolver.resolvedProvider(
            providerName: AIProvider.openAI.rawValue,
            connectedProviders: [.gemini]
        )
        #expect(resolved == .openAI)

        let fallback = ModeRuntimeResolver.resolvedProvider(
            providerName: nil,
            connectedProviders: [.gemini]
        )
        #expect(fallback == .gemini)

        let preservedModel = ModeRuntimeResolver.resolvedModelName(
            configuredModelName: "saved-model-no-longer-in-catalog",
            availableModels: ["gpt-5.6-luna"],
            defaultModel: "gpt-5.6-luna"
        )
        #expect(preservedModel == "saved-model-no-longer-in-catalog")
    }

    @Test func codexCallbackParserAcceptsOnlyExpectedCallback() throws {
        let validRequest = "GET /auth/callback?code=abc123&state=expected HTTP/1.1\r\nHost: localhost\r\n\r\n"
        #expect(
            try CodexCallbackRequestParser.authorizationCode(
                from: validRequest,
                expectedState: "expected"
            ) == "abc123"
        )

        #expect(callbackError(for: "POST /auth/callback?code=x&state=expected HTTP/1.1\r\n\r\n") == .unsupportedMethod)
        #expect(callbackError(for: "GET /wrong?code=x&state=expected HTTP/1.1\r\n\r\n") == .invalidPath)
        #expect(callbackError(for: "GET /auth/callback?code=x&state=wrong HTTP/1.1\r\n\r\n") == .invalidState)
        #expect(callbackError(for: "GET /auth/callback?state=expected HTTP/1.1\r\n\r\n") == .missingCode)
        #expect(
            callbackError(for: "GET /auth/callback?error=access_denied&state=expected HTTP/1.1\r\n\r\n")
                == .authorizationDenied
        )
    }

    @Test func codexSSEParserHandlesStreamingAndMalformedEvents() throws {
        let streamedResponse = Data(
            """
            data: {"type":"response.output_text.delta","delta":"Hello "}
            data: this-is-not-json
            data: {"type":"response.output_text.delta","delta":"world"}
            data: [DONE]

            """.utf8
        )
        #expect(try CodexSSEParser.parse(streamedResponse) == "Hello world")

        let completedResponse = Data(
            """
            data: {"type":"response.output_text.delta","delta":"Partial"}
            data: {"type":"response.output_text.done","text":"Final result"}

            """.utf8
        )
        #expect(try CodexSSEParser.parse(completedResponse) == "Final result")

        #expect(codexParserError(for: Data("data: malformed\n".utf8)) == .emptyResponse)
    }

    @Test func codexHTTPStatusMappingDoesNotExposeResponseBodies() {
        #expect(CodexOAuthClient.error(forHTTPStatus: 401) == .unauthorized)
        #expect(CodexOAuthClient.error(forHTTPStatus: 403) == .unauthorized)
        #expect(CodexOAuthClient.error(forHTTPStatus: 429) == .rateLimited)
        #expect(CodexOAuthClient.error(forHTTPStatus: 503) == .serverError)
        #expect(CodexOAuthClient.error(forHTTPStatus: 418) == .httpError(418))
    }

    @Test func codexOAuthClientSendsPrivateStreamingRequest() async throws {
        let capturedRequest = LockedBox<URLRequest?>(nil)
        let session = MockHTTPSession { request in
            capturedRequest.value = request
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let data = Data(
                "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Polished\"}\n\n".utf8
            )
            return (response, data)
        }

        let client = CodexOAuthClient(session: session)
        let result = try await client.enhance(
            formattedText: "Raw transcript",
            instructions: "Clean it up",
            model: "gpt-5.6-luna",
            accessToken: "test-access-token",
            timeout: 12
        )

        #expect(result == "Polished")
        let request = try #require(capturedRequest.value)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
        #expect(request.timeoutInterval == 12)

        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["model"] as? String == "gpt-5.6-luna")
        #expect(body["stream"] as? Bool == true)
        #expect(body["store"] as? Bool == false)
    }

    @Test func codexOAuthClientMapsHTTPAndNetworkFailures() async {
        for (statusCode, expectedError) in [
            (401, CodexOAuthClientError.unauthorized),
            (403, CodexOAuthClientError.unauthorized),
            (429, CodexOAuthClientError.rateLimited),
            (500, CodexOAuthClientError.serverError),
            (503, CodexOAuthClientError.serverError),
        ] {
            let session = MockHTTPSession { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data("sensitive backend response".utf8))
            }
            let client = CodexOAuthClient(session: session)

            do {
                _ = try await client.enhance(
                    formattedText: "Raw",
                    instructions: "Clean",
                    model: "gpt-5.6-luna",
                    accessToken: "token",
                    timeout: 1
                )
                #expect(Bool(false), "Expected HTTP \(statusCode) to fail")
            } catch let error as CodexOAuthClientError {
                #expect(error == expectedError)
                #expect(error.localizedDescription.contains("sensitive backend response") == false)
            } catch {
                #expect(Bool(false), "Unexpected error type: \(type(of: error))")
            }
        }

        for expectedCode in [URLError.timedOut, .notConnectedToInternet] {
            let session = MockHTTPSession { _ in throw URLError(expectedCode) }
            let client = CodexOAuthClient(session: session)

            do {
                _ = try await client.enhance(
                    formattedText: "Raw",
                    instructions: "Clean",
                    model: "gpt-5.6-luna",
                    accessToken: "token",
                    timeout: 1
                )
                #expect(Bool(false), "Expected URL error \(expectedCode.rawValue)")
            } catch let error as URLError {
                #expect(error.code == expectedCode)
            } catch {
                #expect(Bool(false), "Unexpected error type: \(type(of: error))")
            }
        }
    }

    @Test func codexTokenRefreshIsInjectableAndSanitizesFailures() async throws {
        let capturedRequest = LockedBox<URLRequest?>(nil)
        let successSession = MockHTTPSession { request in
            capturedRequest.value = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(
                "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"expires_in\":3600}".utf8
            )
            return (response, data)
        }

        let tokens = try await CodexAuth.refreshAccessToken(
            refreshToken: "old+refresh",
            session: successSession
        )
        #expect(tokens.accessToken == "new-access")
        #expect(tokens.refreshToken == "new-refresh")
        #expect(tokens.expiresAt > Date())

        let request = try #require(capturedRequest.value)
        let formBody = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(formBody.contains("grant_type=refresh_token"))
        #expect(formBody.contains("refresh_token=old%2Brefresh"))

        let failureSession = MockHTTPSession { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("sensitive raw backend response".utf8))
        }

        do {
            _ = try await CodexAuth.refreshAccessToken(refreshToken: "secret", session: failureSession)
            #expect(Bool(false), "Expected refresh failure")
        } catch let error as CodexAuthError {
            #expect(error.localizedDescription.contains("sensitive raw backend response") == false)
            #expect(error.localizedDescription == "Token refresh failed: HTTP 401")
        }
    }

    @MainActor
    @Test func callbackServerCleansUpAfterTimeoutAndCancellation() async {
        let timeoutServer = CodexCallbackServer(timeoutSeconds: 0.02, port: 0)
        do {
            _ = try await timeoutServer.start(expectedState: "timeout-state")
            #expect(Bool(false), "Expected callback timeout")
        } catch let error as CallbackServerError {
            #expect(error == .timeout)
        } catch {
            #expect(Bool(false), "Unexpected timeout error type: \(type(of: error))")
        }
        #expect(timeoutServer.isListening == false)

        let cancellationServer = CodexCallbackServer(timeoutSeconds: 10, port: 0)
        let task = Task { @MainActor in
            try await cancellationServer.start(expectedState: "cancel-state")
        }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            #expect(Bool(false), "Expected callback cancellation")
        } catch let error as CallbackServerError {
            #expect(error == .cancelled)
        } catch {
            #expect(Bool(false), "Unexpected cancellation error type: \(type(of: error))")
        }
        #expect(cancellationServer.isListening == false)
    }

    @MainActor
    @Test func callbackServerRejectsInvalidRequestsThenCompletesOnce() async throws {
        let server = CodexCallbackServer(timeoutSeconds: 2, port: 0)
        let callbackTask = Task { @MainActor in
            try await server.start(expectedState: "expected-state")
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(server.isListening)
        let listeningPort = try #require(server.listeningPort)

        let wrongMethodResponse = try await sendCallbackRequest(
            method: "POST",
            path: "/auth/callback?code=wrong&state=expected-state",
            port: listeningPort
        )
        #expect(wrongMethodResponse.statusCode == 405)
        #expect(server.isListening)

        let wrongPathResponse = try await sendCallbackRequest(
            method: "GET",
            path: "/wrong?code=wrong&state=expected-state",
            port: listeningPort
        )
        #expect(wrongPathResponse.statusCode == 404)
        #expect(server.isListening)

        let wrongStateResponse = try await sendCallbackRequest(
            method: "GET",
            path: "/auth/callback?code=wrong&state=unexpected",
            port: listeningPort
        )
        #expect(wrongStateResponse.statusCode == 400)
        #expect(server.isListening)

        let successResponse = try await sendCallbackRequest(
            method: "GET",
            path: "/auth/callback?code=valid-code&state=expected-state",
            port: listeningPort
        )
        #expect(successResponse.statusCode == 200)
        #expect(try await callbackTask.value == "valid-code")
        #expect(server.isListening == false)
    }

    @Test func newOpenAIModePrefersOAuthAndLunaWithoutChangingAPIModel() {
        let snapshot = ModeFormWarmupSnapshot(
            connectedAIProviders: [.openAI],
            aiModelsByProvider: [.openAI: ["gpt-5.4-mini"]],
            selectedAIModelsByProvider: [.openAI: "gpt-5.4-mini"],
            configuredOpenAIAuthModes: [.oauth, .apiKey],
            openAIModelsByAuthMode: [
                .oauth: CodexModels.sortedForPicker.map(\.id),
                .apiKey: ["gpt-5.4-mini"],
            ],
            selectedOpenAIModelsByAuthMode: [
                .oauth: "gpt-5.5",
                .apiKey: "gpt-5.4-mini",
            ],
            defaultOpenAIModelsByAuthMode: [
                .oauth: "gpt-5.6-luna",
                .apiKey: "gpt-5.4-mini",
            ],
            preferredOpenAIAuthMode: .oauth,
            usableTranscriptionModels: [],
            allTranscriptionModels: [],
            prompts: []
        )
        var draft = ModeConfigDraft(mode: .add, modeManager: .shared)
        draft.selectedAIProvider = AIProvider.openAI.rawValue
        draft.selectedAIModel = "gpt-5.4-mini"
        draft.selectedOpenAIOAuthModel = "gpt-5.5"

        draft.applyAddModeDefaults(snapshot: snapshot)

        #expect(draft.selectedOpenAIAuthMode == OpenAIAuthMode.oauth.rawValue)
        #expect(draft.selectedOpenAIOAuthModel == "gpt-5.6-luna")
        #expect(draft.selectedAIModel == "gpt-5.4-mini")
    }

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

        let aiService = AIService(oauthTokenStore: InMemoryOAuthTokenStore())
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
        #expect(resolvedPrompt.contains("# System Instructions"))
        #expect(resolvedPrompt.contains("<TASK_INSTRUCTIONS>"))
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

private func callbackError(for request: String) -> CallbackServerError? {
    do {
        _ = try CodexCallbackRequestParser.authorizationCode(from: request, expectedState: "expected")
        return nil
    } catch let error as CallbackServerError {
        return error
    } catch {
        return .invalidRequest
    }
}

private func codexParserError(for data: Data) -> CodexOAuthClientError? {
    do {
        _ = try CodexSSEParser.parse(data)
        return nil
    } catch let error as CodexOAuthClientError {
        return error
    } catch {
        return .invalidResponse
    }
}

private func sendCallbackRequest(
    method: String,
    path: String,
    port: UInt16
) async throws -> HTTPURLResponse {
    var request = URLRequest(
        url: URL(string: "http://127.0.0.1:\(port)\(path)")!
    )
    request.httpMethod = method
    request.timeoutInterval = 1
    let (_, response) = try await URLSession.shared.data(for: request)
    return try #require(response as? HTTPURLResponse)
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private final class MockHTTPSession: OAuthHTTPSessionProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (response, data) = try handler(request)
        return (data, response)
    }
}

private final class InMemoryOAuthTokenStore: OAuthTokenStore {
    private var tokens: OAuthTokens?

    init(tokens: OAuthTokens? = nil) {
        self.tokens = tokens
    }

    func saveOAuthTokens(_ tokens: OAuthTokens) throws {
        self.tokens = tokens
    }

    func retrieveOAuthTokens() throws -> OAuthTokens? {
        tokens
    }

    func deleteOAuthTokens() throws {
        tokens = nil
    }
}
