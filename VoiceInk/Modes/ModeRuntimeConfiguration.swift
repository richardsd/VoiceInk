import Foundation

struct TranscriptionRuntimeConfiguration {
    let mode: ModeConfig
    let model: any TranscriptionModel
    let language: String
    let isRealtimeEnabled: Bool
    /// Request-scoped values are captured when the recording configuration is
    /// resolved. Keeping this stored prevents a Halo voice instruction from
    /// observing a later global language or prompt change while review is open.
    let requestContext: TranscriptionRequestContext

    init(
        mode: ModeConfig?,
        model: any TranscriptionModel,
        language: String,
        isRealtimeEnabled: Bool,
        requestContext: TranscriptionRequestContext? = nil
    ) {
        self.mode = mode
        self.model = model
        self.language = language
        self.isRealtimeEnabled = isRealtimeEnabled
        self.requestContext = requestContext ?? TranscriptionRequestContext(
            language: language,
            prompt: model.provider == .whisper
                ? UserDefaults.standard.string(forKey: "TranscriptionPrompt")
                : nil
        )
    }

    var metadata: (name: String?, emoji: String?) {
        guard mode.isEnabled else {
            return (nil, nil)
        }
        return (mode.name, mode.icon.value)
    }

}

struct TranscriptionFormattingConfiguration {
    let mode: ModeConfig?
    let isTextFormattingEnabled: Bool
    let punctuationCleanupMode: PunctuationCleanupMode
    let lowercaseTranscription: Bool
}

struct EnhancementRuntimeConfiguration {
    let mode: ModeConfig?
    let isEnabled: Bool
    let prompt: CustomPrompt?
    let provider: AIProvider?
    let modelName: String?
    let openAIAuthMode: OpenAIAuthMode?
    let useClipboardContext: Bool
    let useSelectedTextContext: Bool
    let useScreenCaptureContext: Bool

    func replacingPrompt(_ prompt: CustomPrompt) -> EnhancementRuntimeConfiguration {
        EnhancementRuntimeConfiguration(
            mode: mode,
            isEnabled: true,
            prompt: prompt,
            provider: provider,
            modelName: modelName,
            openAIAuthMode: openAIAuthMode,
            useClipboardContext: useClipboardContext,
            useSelectedTextContext: useSelectedTextContext,
            useScreenCaptureContext: useScreenCaptureContext
        )
    }
}

struct OutputRuntimeConfiguration {
    let mode: ModeConfig?
    let outputMode: ModeOutputMode
    let haloDeliveryPolicy: HaloDeliveryPolicy
    let autoSendKey: AutoSendKey
    let customCommand: ModeCustomCommand?

    init(
        mode: ModeConfig?,
        outputMode: ModeOutputMode,
        haloDeliveryPolicy: HaloDeliveryPolicy = .alwaysReview,
        autoSendKey: AutoSendKey,
        customCommand: ModeCustomCommand?
    ) {
        self.mode = mode
        self.outputMode = outputMode
        self.haloDeliveryPolicy = haloDeliveryPolicy
        self.autoSendKey = autoSendKey
        self.customCommand = customCommand
    }
}

enum ModeTranscriptionModelResolution {
    case noMode
    case noSelection(mode: ModeConfig)
    case modelNotFound(mode: ModeConfig)
    case unavailable(mode: ModeConfig, model: any TranscriptionModel)
    case available(mode: ModeConfig, model: any TranscriptionModel)
}

@MainActor
enum ModeRuntimeResolver {
    static func transcriptionModelResolution(
        mode: ModeConfig? = nil,
        transcriptionModelManager: TranscriptionModelManager
    ) -> ModeTranscriptionModelResolution {
        guard let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration else {
            return .noMode
        }

        guard let modelName = mode.selectedTranscriptionModelName,
            !modelName.isEmpty
        else {
            return .noSelection(mode: mode)
        }

        guard
            let model = transcriptionModelManager.allAvailableModels.first(where: {
                $0.name == modelName
            })
        else {
            return .modelNotFound(mode: mode)
        }

        guard transcriptionModelManager.usableModels.contains(where: { $0.name == modelName }) else {
            return .unavailable(mode: mode, model: model)
        }

        return .available(mode: mode, model: model)
    }

    static func transcriptionConfiguration(
        mode: ModeConfig? = nil,
        transcriptionModelManager: TranscriptionModelManager
    ) -> TranscriptionRuntimeConfiguration? {
        transcriptionConfiguration(
            from: transcriptionModelResolution(
                mode: mode,
                transcriptionModelManager: transcriptionModelManager
            )
        )
    }

    static func transcriptionConfiguration(
        from resolution: ModeTranscriptionModelResolution
    ) -> TranscriptionRuntimeConfiguration? {
        guard
            case .available(let mode, let model) = resolution
        else {
            return nil
        }

        let language = TranscriptionLanguageSupport.validLanguageOrFallback(
            mode.selectedLanguage,
            for: model,
            realtimeEnabled: mode.isRealtimeTranscriptionEnabled
        )

        return TranscriptionRuntimeConfiguration(
            mode: mode,
            model: model,
            language: language,
            isRealtimeEnabled: TranscriptionRealtimeSupport.isEnabled(
                for: model, modeValue: mode.isRealtimeTranscriptionEnabled)
        )
    }

    static func transcriptionFormattingConfiguration(mode: ModeConfig? = nil) -> TranscriptionFormattingConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration

        return TranscriptionFormattingConfiguration(
            mode: mode,
            isTextFormattingEnabled: mode?.isTextFormattingEnabled ?? UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled"),
            punctuationCleanupMode: mode?.punctuationCleanupMode ?? PunctuationCleanupMode.current(),
            lowercaseTranscription: mode?.lowercaseTranscription ?? UserDefaults.standard.bool(forKey: "LowercaseTranscription")
        )
    }

    static func currentEnhancementConfiguration(
        mode: ModeConfig? = nil,
        enhancementService: AIEnhancementService,
        aiService: AIService
    ) -> EnhancementRuntimeConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration
        let provider = resolvedProvider(
            providerName: mode?.selectedAIProvider,
            connectedProviders: aiService.connectedProviders
        )
        let openAIAuthMode = resolvedOpenAIAuthMode(
            provider: provider,
            mode: mode,
            aiService: aiService
        )
        let prompt =
            provider == .voiceInkRefine
            ? nil
            : resolvedPrompt(
                promptId: mode?.selectedPrompt,
                enhancementService: enhancementService
            )
        let modelName = resolvedEnhancementModelName(
            provider: provider,
            configuredModelName: resolvedConfiguredModelName(
                provider: provider,
                mode: mode,
                openAIAuthMode: openAIAuthMode
            ),
            openAIAuthMode: openAIAuthMode,
            aiService: aiService
        )

        return EnhancementRuntimeConfiguration(
            mode: mode,
            isEnabled: mode?.isAIEnhancementEnabled ?? false,
            prompt: prompt,
            provider: provider,
            modelName: modelName,
            openAIAuthMode: openAIAuthMode,
            useClipboardContext: provider == .voiceInkRefine ? false : mode?.useClipboardContext ?? false,
            useSelectedTextContext: provider == .voiceInkRefine ? false : mode?.useSelectedTextContext ?? true,
            useScreenCaptureContext: provider == .voiceInkRefine ? false : mode?.useScreenCapture ?? false
        )
    }

    static func outputConfiguration(mode: ModeConfig? = nil) -> OutputRuntimeConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration

        return OutputRuntimeConfiguration(
            mode: mode,
            outputMode: mode?.outputMode ?? .paste,
            haloDeliveryPolicy: mode?.haloDeliveryPolicy ?? .alwaysReview,
            autoSendKey: mode?.autoSendKey ?? .none,
            customCommand: mode?.customCommand
        )
    }

    private static func resolvedPrompt(
        promptId: String?,
        enhancementService: AIEnhancementService
    ) -> CustomPrompt? {
        guard let promptId,
            let uuid = UUID(uuidString: promptId)
        else {
            return nil
        }

        return enhancementService.allPrompts.first { $0.id == uuid }
    }

    static func resolvedProvider(
        providerName: String?,
        connectedProviders: [AIProvider]
    ) -> AIProvider? {
        if let providerName,
            let provider = AIProvider(rawValue: providerName),
            provider.supportsEnhancement
        {
            return provider
        }

        return connectedProviders.first
    }

    private static func resolvedOpenAIAuthMode(
        provider: AIProvider?,
        mode: ModeConfig?,
        aiService: AIService
    ) -> OpenAIAuthMode? {
        guard provider == .openAI else { return nil }

        if let rawMode = mode?.selectedOpenAIAuthMode,
           let authMode = OpenAIAuthMode(rawValue: rawMode) {
            return authMode
        }

        return aiService.openAIAuthMode
    }

    private static func resolvedConfiguredModelName(
        provider: AIProvider?,
        mode: ModeConfig?,
        openAIAuthMode: OpenAIAuthMode?
    ) -> String? {
        guard provider == .openAI, openAIAuthMode == .oauth else {
            return mode?.selectedAIModel
        }

        if let oauthModel = mode?.selectedOpenAIOAuthModel, !oauthModel.isEmpty {
            return oauthModel
        }

        return mode?.selectedAIModel
    }

    private static func resolvedEnhancementModelName(
        provider: AIProvider?,
        configuredModelName: String?,
        openAIAuthMode: OpenAIAuthMode?,
        aiService: AIService
    ) -> String? {
        guard let provider else { return nil }

        if provider == .localCLI {
            return nil
        }

        if provider == .voiceInkRefine {
            return provider.defaultModel
        }

        let models = aiService.models(for: provider, authMode: openAIAuthMode)
        return resolvedModelName(
            configuredModelName: configuredModelName,
            availableModels: models,
            defaultModel: aiService.defaultModel(for: provider, authMode: openAIAuthMode)
        )
    }

    static func resolvedModelName(
        configuredModelName: String?,
        availableModels: [String],
        defaultModel: String
    ) -> String {
        if let configuredModelName,
            !configuredModelName.isEmpty
        {
            return configuredModelName
        }

        if let firstModel = availableModels.first {
            return firstModel
        }

        return defaultModel
    }
}
