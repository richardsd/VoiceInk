import Foundation

enum OnboardingV2Migration {
    private static let legacyCompletedKey = "hasCompletedOnboarding"
    private static let completedKey = "hasCompletedOnboardingV2"
    private static let preparedKey = "hasPreparedOnboardingV2"
    private static let legacyModeConfigurationsKey = "powerModeConfigurationsV2"
    private static let modeConfigurationsKey = "modeConfigurationsV2"
    private static let activeConfigurationIdKey = "activeConfigurationId"
    private static let legacyDefaultModeIdKey = "legacyDefaultModeConfigurationId"

    static func prepareIfNeeded(defaults: UserDefaults = .standard) {
        let completedLegacyOnboarding = defaults.bool(forKey: legacyCompletedKey)
        let completedV2Onboarding = defaults.bool(forKey: completedKey)
        let preparedV2Onboarding = defaults.bool(forKey: preparedKey)

        guard !completedV2Onboarding,
              !preparedV2Onboarding else {
            if completedLegacyOnboarding {
                defaults.removeObject(forKey: legacyCompletedKey)
            }
            return
        }

        if completedLegacyOnboarding || hasMigratableLegacyConfiguration(defaults: defaults) {
            preserveLegacyConfiguration(defaults: defaults)
            defaults.set(true, forKey: completedKey)
            defaults.set(true, forKey: preparedKey)
            defaults.removeObject(forKey: legacyCompletedKey)
            return
        }

        defaults.removeObject(forKey: legacyCompletedKey)
        clearModeStorage(defaults: defaults)
        OnboardingStorageKeys.onboardingKeys.forEach {
            defaults.removeObject(forKey: $0)
        }
        defaults.set(true, forKey: preparedKey)
    }

    private static func clearModeStorage(defaults: UserDefaults) {
        let modeIds = modeConfigurationIds(forKey: modeConfigurationsKey, defaults: defaults)
            .union(modeConfigurationIds(forKey: legacyModeConfigurationsKey, defaults: defaults))
            .union(StarterModeCatalog.ids)

        for id in modeIds {
            ShortcutStore.removeShortcutStorage(for: .mode(id))
            removeLegacyPowerModeShortcutStorage(for: id, defaults: defaults)
        }

        defaults.removeObject(forKey: modeConfigurationsKey)
        defaults.removeObject(forKey: legacyModeConfigurationsKey)
        defaults.removeObject(forKey: activeConfigurationIdKey)
    }

    private static func modeConfigurationIds(forKey key: String, defaults: UserDefaults) -> Set<UUID> {
        guard let data = defaults.data(forKey: key) else {
            return []
        }

        if let configs = try? JSONDecoder().decode([ModeConfig].self, from: data) {
            return Set(configs.map(\.id))
        }

        guard
            let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }

        return Set(
            objects.compactMap { object in
                (object["id"] as? String).flatMap(UUID.init(uuidString:))
            })
    }

    private static func removeLegacyPowerModeShortcutStorage(for id: UUID, defaults: UserDefaults) {
        let key = "Shortcut_powerMode_\(id.uuidString)"
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: "\(key)_cleared")
    }

    private static func hasMigratableLegacyConfiguration(defaults: UserDefaults) -> Bool {
        hasStoredModeConfigurations(forKey: modeConfigurationsKey, defaults: defaults) ||
        hasStoredModeConfigurations(forKey: legacyModeConfigurationsKey, defaults: defaults) ||
        defaults.data(forKey: "customPrompts") != nil ||
        defaults.string(forKey: "selectedPromptId") != nil ||
        defaults.object(forKey: "isAIEnhancementEnabled") != nil ||
        defaults.string(forKey: "selectedAIProvider") != nil ||
        defaults.string(forKey: "CurrentTranscriptionModel") != nil
    }

    private static func preserveLegacyConfiguration(defaults: UserDefaults) {
        copyLegacyModeConfigurationsIfNeeded(defaults: defaults)
        ensureLegacyDefaultModeIfNeeded(defaults: defaults)
    }

    private static func copyLegacyModeConfigurationsIfNeeded(defaults: UserDefaults) {
        guard !hasStoredModeConfigurations(forKey: modeConfigurationsKey, defaults: defaults),
              let legacyData = defaults.data(forKey: legacyModeConfigurationsKey) else {
            return
        }

        defaults.set(legacyData, forKey: modeConfigurationsKey)
    }

    private static func ensureLegacyDefaultModeIfNeeded(defaults: UserDefaults) {
        guard !hasStoredModeConfigurations(forKey: modeConfigurationsKey, defaults: defaults) else {
            return
        }

        let isEnhancementEnabled = defaults.bool(forKey: "isAIEnhancementEnabled")
        let selectedPrompt = legacySelectedPrompt(defaults: defaults, enhancementEnabled: isEnhancementEnabled)
        ensureSeedPromptIfNeeded(selectedPrompt: selectedPrompt, defaults: defaults)

        let provider = defaults.string(forKey: "selectedAIProvider")
        let selectedModel = provider.flatMap { defaults.string(forKey: "\($0)SelectedModel") }
        let id = legacyDefaultModeId(defaults: defaults)
        let mode = ModeConfig(
            id: id,
            name: isEnhancementEnabled ? "Enhancement" : "Dictation",
            icon: .symbol(isEnhancementEnabled ? "sparkles" : "mic.fill"),
            isAIEnhancementEnabled: isEnhancementEnabled,
            selectedPrompt: selectedPrompt,
            selectedTranscriptionModelName: defaults.string(forKey: "CurrentTranscriptionModel") ?? StarterModeFactory.transcriptionModelName,
            isRealtimeTranscriptionEnabled: true,
            selectedLanguage: defaults.string(forKey: "SelectedLanguage") ?? "en",
            useClipboardContext: defaults.bool(forKey: "useClipboardContext"),
            useSelectedTextContext: legacySelectedTextContext(defaults: defaults),
            useScreenCapture: defaults.bool(forKey: "useScreenCaptureContext"),
            isTextFormattingEnabled: defaults.bool(forKey: "IsTextFormattingEnabled"),
            punctuationCleanupMode: PunctuationCleanupMode.current(in: defaults),
            lowercaseTranscription: defaults.bool(forKey: "LowercaseTranscription"),
            selectedAIProvider: provider,
            selectedAIModel: selectedModel,
            selectedOpenAIAuthMode: defaults.string(forKey: "openAIAuthMode"),
            selectedOpenAIOAuthModel: defaults.string(forKey: "openAIOAuthModel"),
            outputMode: .paste,
            autoSendKey: .none,
            isEnabled: true,
            isDefault: true
        )

        if let data = try? JSONEncoder().encode([mode]) {
            defaults.set(data, forKey: modeConfigurationsKey)
            if defaults.string(forKey: activeConfigurationIdKey) == nil {
                defaults.set(id.uuidString, forKey: activeConfigurationIdKey)
            }
        }
    }

    private static func hasStoredModeConfigurations(forKey key: String, defaults: UserDefaults) -> Bool {
        guard let data = defaults.data(forKey: key) else {
            return false
        }

        if let configs = try? JSONDecoder().decode([ModeConfig].self, from: data) {
            return !configs.isEmpty
        }

        if let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return !objects.isEmpty
        }

        return true
    }

    private static func legacyDefaultModeId(defaults: UserDefaults) -> UUID {
        if let idString = defaults.string(forKey: legacyDefaultModeIdKey),
           let id = UUID(uuidString: idString) {
            return id
        }

        let id = UUID()
        defaults.set(id.uuidString, forKey: legacyDefaultModeIdKey)
        return id
    }

    private static func legacySelectedPrompt(defaults: UserDefaults, enhancementEnabled: Bool) -> String? {
        if let selectedPrompt = defaults.string(forKey: "selectedPromptId"),
           UUID(uuidString: selectedPrompt) != nil {
            return selectedPrompt
        }

        guard enhancementEnabled else {
            return nil
        }

        if let firstPromptId = firstStoredPromptId(defaults: defaults) {
            return firstPromptId.uuidString
        }

        return PromptTemplates.defaultPromptId.uuidString
    }

    private static func legacySelectedTextContext(defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: "useSelectedTextContext") != nil else {
            return true
        }

        return defaults.bool(forKey: "useSelectedTextContext")
    }

    private static func firstStoredPromptId(defaults: UserDefaults) -> UUID? {
        guard let data = defaults.data(forKey: "customPrompts"),
              let prompts = try? JSONDecoder().decode([CustomPrompt].self, from: data) else {
            return nil
        }

        return prompts.first?.id
    }

    private static func ensureSeedPromptIfNeeded(selectedPrompt: String?, defaults: UserDefaults) {
        guard let selectedPrompt,
              let selectedPromptId = UUID(uuidString: selectedPrompt),
              let seedPrompt = PromptTemplates.seedPrompts.first(where: { $0.id == selectedPromptId }) else {
            return
        }

        var prompts: [CustomPrompt]
        if let data = defaults.data(forKey: "customPrompts") {
            guard let decodedPrompts = try? JSONDecoder().decode([CustomPrompt].self, from: data) else {
                return
            }
            prompts = decodedPrompts
        } else {
            prompts = []
        }

        guard !prompts.contains(where: { $0.id == selectedPromptId }) else {
            return
        }

        prompts.append(seedPrompt)
        if let data = try? JSONEncoder().encode(prompts) {
            defaults.set(data, forKey: "customPrompts")
        }
    }
}
