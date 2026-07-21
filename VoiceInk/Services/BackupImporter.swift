import Foundation
import SwiftData

enum BackupImportError: LocalizedError {
    case saveFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let item, let error):
            return String(format: String(localized: "Failed to save imported %@: %@"), item, error.localizedDescription)
        }
    }
}

enum BackupImporter {
    private static let keyIsTextFormattingEnabled = "IsTextFormattingEnabled"
    private static let keyRemovePunctuation = "RemovePunctuation"
    private static let keyLowercaseTranscription = "LowercaseTranscription"

    @MainActor
    static func apply(
        _ backup: BackupFile, categories: Set<BackupCategory>, enhancementService: AIEnhancementService,
        recordingShortcutManager: RecordingShortcutManager, menuBarManager: MenuBarManager,
        mediaController: MediaController, playbackController: PlaybackController, recorderUIManager: RecorderUIManager,
        haloCapabilityStore: HaloCapabilityStore, modelContext: ModelContext,
        transcriptionModelManager: TranscriptionModelManager
    ) throws {
        var shouldRepairModePromptSelections = false

        if categories.contains(.dictionary) {
            try importDictionary(from: backup, modelContext: modelContext)
        }

        if categories.contains(.general) {
            importGeneral(
                backup.generalSettings,
                recordingShortcutManager: recordingShortcutManager,
                menuBarManager: menuBarManager,
                mediaController: mediaController,
                playbackController: playbackController,
                recorderUIManager: recorderUIManager,
                haloCapabilityStore: haloCapabilityStore
            )
        }

        if categories.contains(.prompts) {
            importPrompts(from: backup, enhancementService: enhancementService)
            shouldRepairModePromptSelections = true
        }

        if categories.contains(.modes) {
            importModes(from: backup)
            shouldRepairModePromptSelections = true
        }

        if shouldRepairModePromptSelections {
            enhancementService.repairModePromptSelections()
        }

        if categories.contains(.customModels) {
            importCustomModels(backup.customCloudModels, transcriptionModelManager: transcriptionModelManager)
        }

        if categories.contains(.enhancement) {
            importEnhancement(from: backup, enhancementService: enhancementService)
        }

        if categories.contains(.transcription) {
            importTranscription(from: backup, transcriptionModelManager: transcriptionModelManager)
        }
    }

    @MainActor
    private static func importGeneral(
        _ general: GeneralBackup?, recordingShortcutManager: RecordingShortcutManager, menuBarManager: MenuBarManager,
        mediaController: MediaController, playbackController: PlaybackController, recorderUIManager: RecorderUIManager,
        haloCapabilityStore: HaloCapabilityStore
    ) {
        guard let general else {
            print("No general settings found in the imported file.")
            return
        }

        if let shortcut = general.primaryRecordingShortcut {
            ShortcutStore.setShortcut(shortcut.shortcut, for: .primaryRecording)
            recordingShortcutManager.primaryRecordingShortcut = .custom
        }
        if let shortcut2 = general.secondaryRecordingShortcut {
            ShortcutStore.setShortcut(shortcut2.shortcut, for: .secondaryRecording)
            recordingShortcutManager.secondaryRecordingShortcut = .custom
        }
        if let pasteShortcut = general.pasteLastTranscriptionShortcut {
            ShortcutStore.setShortcut(pasteShortcut.shortcut, for: .pasteLastTranscription)
        }
        if let pasteEnhancementShortcut = general.pasteLastEnhancementShortcut {
            ShortcutStore.setShortcut(pasteEnhancementShortcut.shortcut, for: .pasteLastEnhancement)
        }
        if let retryShortcut = general.retryLastTranscriptionShortcut {
            ShortcutStore.setShortcut(retryShortcut.shortcut, for: .retryLastTranscription)
        }
        if let cancelShortcut = general.cancelRecorderShortcut {
            ShortcutStore.setShortcut(cancelShortcut.shortcut, for: .cancelRecorder)
        }
        if let historyShortcut = general.openHistoryWindowShortcut {
            ShortcutStore.setShortcut(historyShortcut.shortcut, for: .openHistoryWindow)
        }
        if let dictionaryShortcut = general.quickAddToDictionaryShortcut {
            ShortcutStore.setShortcut(dictionaryShortcut.shortcut, for: .quickAddToDictionary)
        }
        restoreHaloConfiguration(
            from: general,
            haloCapabilityStore: haloCapabilityStore
        )

        if let shortcutRawValue = general.primaryRecordingShortcutRawValue,
            let shortcut = RecordingShortcutManager.ShortcutSelection(rawValue: shortcutRawValue)
        {
            recordingShortcutManager.primaryRecordingShortcut = shortcut
        }
        if let secondaryShortcutRawValue = general.secondaryRecordingShortcutRawValue,
            let secondaryShortcut = RecordingShortcutManager.ShortcutSelection(rawValue: secondaryShortcutRawValue)
        {
            recordingShortcutManager.secondaryRecordingShortcut = secondaryShortcut
        }
        if let modeRawValue = general.primaryRecordingShortcutModeRawValue,
            let mode = RecordingShortcutManager.Mode(rawValue: modeRawValue)
        {
            recordingShortcutManager.primaryRecordingShortcutMode = mode
        }
        if let secondaryModeRawValue = general.secondaryRecordingShortcutModeRawValue,
            let secondaryMode = RecordingShortcutManager.Mode(rawValue: secondaryModeRawValue)
        {
            recordingShortcutManager.secondaryRecordingShortcutMode = secondaryMode
        }
        if let middleClickEnabled = general.isMiddleClickToggleEnabled {
            recordingShortcutManager.isMiddleClickToggleEnabled = middleClickEnabled
        }
        if let middleClickDelay = general.middleClickActivationDelay {
            recordingShortcutManager.middleClickActivationDelay = middleClickDelay
        }
        if let launch = general.launchAtLoginEnabled {
            LaunchAtLoginManager.shared.setEnabled(launch)
        }
        if let menuOnly = general.isMenuBarOnly {
            menuBarManager.isMenuBarOnly = menuOnly
        }
        if let recType = general.recorderType {
            recorderUIManager.recorderType = recType
        }
        if let rawAppearancePreference = general.appAppearancePreference,
            let appearancePreference = AppAppearancePreference(rawValue: rawAppearancePreference)
        {
            UserDefaults.standard.set(appearancePreference.rawValue, forKey: AppAppearancePreference.userDefaultsKey)
            appearancePreference.apply()
        }
        if let rawLanguagePreference = general.appLanguagePreference {
            let languagePreference = AppLanguagePreference.normalizedRawValue(rawLanguagePreference)
            UserDefaults.standard.set(languagePreference, forKey: AppLanguagePreference.userDefaultsKey)
            AppLanguagePreference.apply(rawValue: languagePreference)
        }
        if let hasCompletedOnboarding = general.hasCompletedOnboarding {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
        }
        if let enableAnnouncements = general.enableAnnouncements {
            UserDefaults.standard.set(enableAnnouncements, forKey: "enableAnnouncements")
        }
        if let autoUpdateCheck = general.autoUpdateCheck {
            UserDefaults.standard.set(autoUpdateCheck, forKey: "autoUpdateCheck")
        }
        if let powerModeUIFlag = general.powerModeUIFlag {
            UserDefaults.standard.set(powerModeUIFlag, forKey: "powerModeUIFlag")
        }
        if let powerModePersistConfig = general.powerModePersistConfig {
            UserDefaults.standard.set(powerModePersistConfig, forKey: "powerModePersistConfig")
        }

        if let transcriptionCleanup = general.isTranscriptionCleanupEnabled {
            UserDefaults.standard.set(transcriptionCleanup, forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled)
        }
        if let transcriptionMinutes = general.transcriptionRetentionMinutes {
            UserDefaults.standard.set(transcriptionMinutes, forKey: CleanupSettingsKeys.transcriptionRetentionMinutes)
        }
        if let audioCleanup = general.isAudioCleanupEnabled {
            UserDefaults.standard.set(audioCleanup, forKey: CleanupSettingsKeys.isAudioCleanupEnabled)
        }
        if let audioRetention = general.audioRetentionPeriod {
            UserDefaults.standard.set(audioRetention, forKey: CleanupSettingsKeys.audioRetentionPeriod)
        }
        if let soundFeedbackEnabled = general.isSoundFeedbackEnabled {
            UserDefaults.standard.set(soundFeedbackEnabled, forKey: "isSoundFeedbackEnabled")
        }

        if let muteSystem = general.isSystemMuteEnabled {
            mediaController.isSystemMuteEnabled = muteSystem
        }
        if let pauseMedia = general.isPauseMediaEnabled {
            playbackController.isPauseMediaEnabled = pauseMedia
        }
        if let audioDelay = general.audioResumptionDelay {
            mediaController.audioResumptionDelay = audioDelay
        }
        if let experimentalEnabled = general.isExperimentalFeaturesEnabled {
            UserDefaults.standard.set(experimentalEnabled, forKey: "isExperimentalFeaturesEnabled")
            if experimentalEnabled == false {
                playbackController.isPauseMediaEnabled = false
            }
        }
        if let textFormattingEnabled = general.isTextFormattingEnabled {
            UserDefaults.standard.set(textFormattingEnabled, forKey: keyIsTextFormattingEnabled)
        }
        if let punctuationCleanupMode = general.punctuationCleanupMode {
            PunctuationCleanupMode.setCurrent(punctuationCleanupMode)
        } else if let removePunctuation = general.removePunctuation {
            PunctuationCleanupMode.setCurrent(removePunctuation ? .removeAll : .keep)
        }
        if let lowercaseTranscription = general.lowercaseTranscription {
            UserDefaults.standard.set(lowercaseTranscription, forKey: keyLowercaseTranscription)
        }
        if let restoreClipboard = general.restoreClipboardAfterPaste {
            UserDefaults.standard.set(restoreClipboard, forKey: "restoreClipboardAfterPaste")
        }
        if let clipboardDelay = general.clipboardRestoreDelay {
            UserDefaults.standard.set(clipboardDelay, forKey: "clipboardRestoreDelay")
        }
        if let appleScriptPaste = general.useAppleScriptPaste {
            PasteMethod.setCurrent(appleScriptPaste ? .appleScript : .standard)
        }
        if let audioInputMode = general.audioInputModeRawValue {
            UserDefaults.standard.audioInputModeRawValue = audioInputMode
        }
        if let selectedAudioDeviceUID = general.selectedAudioDeviceUID {
            UserDefaults.standard.selectedAudioDeviceUID = selectedAudioDeviceUID
        }
        if let prioritizedDevices = general.prioritizedDevices {
            UserDefaults.standard.prioritizedDevicesData = prioritizedDevices
        }
        if let audioPlaybackRate = general.audioPlaybackRate {
            UserDefaults.standard.set(audioPlaybackRate, forKey: "audioPlaybackRate")
        }
        if let isUsingCustomStartSound = general.isUsingCustomStartSound {
            UserDefaults.standard.set(isUsingCustomStartSound ? "custom" : "builtIn", forKey: CustomSoundManager.SoundType.start.selectionKey)
        }
        if let customStartSoundFilename = general.customStartSoundFilename {
            UserDefaults.standard.set(customStartSoundFilename, forKey: CustomSoundManager.SoundType.start.filenameKey)
        }
        if let isUsingCustomStopSound = general.isUsingCustomStopSound {
            UserDefaults.standard.set(isUsingCustomStopSound ? "custom" : "builtIn", forKey: CustomSoundManager.SoundType.stop.selectionKey)
        }
        if let customStopSoundFilename = general.customStopSoundFilename {
            UserDefaults.standard.set(customStopSoundFilename, forKey: CustomSoundManager.SoundType.stop.filenameKey)
        }

        print("Successfully imported general settings.")
    }

    /// Restores the Halo-specific v3 payload through the same observable store
    /// and shortcut storage used by the live settings UI. Keeping this slice
    /// independently testable protects immediate capability reconciliation
    /// without constructing the unrelated application managers.
    @MainActor
    static func restoreHaloConfiguration(
        from general: GeneralBackup,
        haloCapabilityStore: HaloCapabilityStore,
        shortcutWriter: (Shortcut, ShortcutAction) -> Void = { shortcut, action in
            ShortcutStore.setShortcut(shortcut, for: action)
        }
    ) {
        if let toggleTimeShiftShortcut = general.toggleTimeShiftShortcut {
            shortcutWriter(toggleTimeShiftShortcut.shortcut, .toggleTimeShift)
        }
        if let captureTimeShiftShortcut = general.captureTimeShiftShortcut {
            shortcutWriter(captureTimeShiftShortcut.shortcut, .captureTimeShift)
        }

        guard let halo = general.haloPreferences else { return }
        haloCapabilityStore.apply(
            spokenRefinementEnabled: halo.spokenRefinementEnabled,
            typedRefinementEnabled: halo.typedRefinementEnabled,
            voiceCommandsEnabled: halo.voiceCommandsEnabled,
            anotherTakeEnabled: halo.anotherTakeEnabled,
            parallelComparisonEnabled: halo.parallelComparisonEnabled,
            guidedRecoveryEnabled: halo.guidedRecoveryEnabled,
            positionBehaviorRawValue: halo.positionBehaviorRawValue,
            timeShiftEnabled: halo.timeShiftEnabled
        )
    }

    @MainActor
    private static func importPrompts(from backup: BackupFile, enhancementService: AIEnhancementService) {
        enhancementService.customPrompts = backup.customPrompts
        restoreSelectedPrompt(from: backup, enhancementService: enhancementService)
        print("Successfully imported \(backup.customPrompts.count) custom prompts.")
    }

    @MainActor
    private static func importEnhancement(from backup: BackupFile, enhancementService: AIEnhancementService) {
        guard let settings = backup.enhancementSettings else {
            print("No AI enhancement settings found in the imported file.")
            return
        }

        let defaults = UserDefaults.standard
        applyEnhancementSettingsToCurrentMode(settings, enhancementService: enhancementService)

        if let aiService = enhancementService.getAIService() {
            if let rawValue = settings.openAIAuthModeRawValue,
               let authMode = OpenAIAuthMode(rawValue: rawValue) {
                aiService.openAIAuthMode = authMode
            }
            if let oauthModel = settings.openAIOAuthModel, !oauthModel.isEmpty {
                aiService.openAIOAuthModel = oauthModel
            }
            if let baseURL = settings.ollamaBaseURL {
                defaults.set(baseURL, forKey: "ollamaBaseURL")
            }
            if let ollamaModel = settings.ollamaSelectedModel {
                defaults.set(ollamaModel, forKey: "ollamaSelectedModel")
                aiService.selectModel(ollamaModel, for: .ollama)
            }
            if let customBaseURL = settings.customProviderBaseURL {
                aiService.customBaseURL = customBaseURL
            }
            if let customModel = settings.customProviderModel {
                aiService.customModel = customModel
            }
            if let openRouterModels = settings.openRouterModels {
                defaults.set(openRouterModels, forKey: "openRouterModels")
            }
            if let selectedModels = settings.selectedModelByProvider {
                for (providerRawValue, model) in selectedModels {
                    guard let provider = AIProvider(rawValue: providerRawValue) else { continue }
                    aiService.selectModel(model, for: provider, authMode: provider == .openAI ? .apiKey : nil)
                }
            }
            if let providerRawValue = settings.selectedProviderRawValue,
               let provider = AIProvider(rawValue: providerRawValue) {
                aiService.selectedProvider = provider
            }
            if let templateRawValue = settings.localCLISelectedTemplateRawValue {
                defaults.set(templateRawValue, forKey: LocalCLIService.selectedTemplateKey)
            }
            if let commandTemplate = settings.localCLICommandTemplate {
                aiService.updateLocalCLICommandTemplate(commandTemplate)
            }
            if let timeout = settings.localCLITimeoutSeconds {
                aiService.updateLocalCLITimeoutSeconds(timeout)
            }
        }

        if let skipShortEnhancement = settings.skipShortEnhancement {
            defaults.set(skipShortEnhancement, forKey: "SkipShortEnhancement")
        }
        if let threshold = settings.shortEnhancementWordThreshold {
            defaults.set(threshold, forKey: "ShortEnhancementWordThreshold")
        }
        if let timeout = settings.enhancementTimeoutSeconds {
            defaults.set(timeout, forKey: "EnhancementTimeoutSeconds")
        }
        if let retryOnTimeout = settings.enhancementRetryOnTimeout {
            defaults.set(retryOnTimeout, forKey: "EnhancementRetryOnTimeout")
        }

        restoreSelectedPrompt(from: backup, enhancementService: enhancementService)
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        print("Successfully imported AI enhancement settings.")
    }

    @MainActor
    private static func applyEnhancementSettingsToCurrentMode(_ settings: EnhancementSettingsBackup, enhancementService: AIEnhancementService) {
        let modeManager = ModeManager.shared
        guard var mode = modeManager.currentEffectiveConfiguration ?? modeManager.configurations.first else {
            return
        }

        if let isEnabled = settings.isEnabled {
            mode.isAIEnhancementEnabled = isEnabled
        }
        if let useClipboardContext = settings.useClipboardContext {
            mode.useClipboardContext = useClipboardContext
        }
        if let useScreenCaptureContext = settings.useScreenCaptureContext {
            mode.useScreenCapture = useScreenCaptureContext
        }
        if let selectedPromptId = settings.selectedPromptId,
           enhancementService.allPrompts.contains(where: { $0.id == selectedPromptId }) {
            mode.selectedPrompt = selectedPromptId.uuidString
        }

        modeManager.updateConfiguration(mode)
        if modeManager.activeConfiguration?.id == mode.id {
            modeManager.setActiveConfiguration(mode)
        }
    }

    @MainActor
    private static func importTranscription(from backup: BackupFile, transcriptionModelManager: TranscriptionModelManager) {
        guard let settings = backup.transcriptionSettings else {
            print("No transcription settings found in the imported file.")
            return
        }

        let defaults = UserDefaults.standard
        if let modelName = settings.currentTranscriptionModelName, !modelName.isEmpty {
            if let model = transcriptionModelManager.allAvailableModels.first(where: { $0.name == modelName }) {
                transcriptionModelManager.setDefaultTranscriptionModel(model)
            } else {
                defaults.set(modelName, forKey: "CurrentTranscriptionModel")
            }
        }
        if let selectedLanguage = settings.selectedLanguage {
            defaults.set(selectedLanguage, forKey: "SelectedLanguage")
            NotificationCenter.default.post(name: .languageDidChange, object: nil)
        }
        if let transcriptionPrompt = settings.transcriptionPrompt {
            defaults.set(transcriptionPrompt, forKey: "TranscriptionPrompt")
            NotificationCenter.default.post(name: .promptDidChange, object: nil)
        }
        if let customLanguagePrompts = settings.customLanguagePrompts {
            defaults.set(customLanguagePrompts, forKey: "CustomLanguagePrompts")
        }
        if let isTextFormattingEnabled = settings.isTextFormattingEnabled {
            defaults.set(isTextFormattingEnabled, forKey: keyIsTextFormattingEnabled)
        }
        if let removePunctuation = settings.removePunctuation {
            defaults.set(removePunctuation, forKey: keyRemovePunctuation)
        }
        if let lowercaseTranscription = settings.lowercaseTranscription {
            defaults.set(lowercaseTranscription, forKey: keyLowercaseTranscription)
        }
        if let isVADEnabled = settings.isVADEnabled {
            defaults.set(isVADEnabled, forKey: "IsVADEnabled")
        }
        if let appendTrailingSpace = settings.appendTrailingSpace {
            defaults.set(appendTrailingSpace, forKey: "AppendTrailingSpace")
        }
        if let prewarmModelOnWake = settings.prewarmModelOnWake {
            defaults.set(prewarmModelOnWake, forKey: "PrewarmModelOnWake")
        }
        if let showLiveTextPreview = settings.showLiveTextPreview {
            defaults.set(showLiveTextPreview, forKey: "showLiveTextPreview")
        }
        if let removeFillerWords = settings.removeFillerWords {
            defaults.set(removeFillerWords, forKey: "RemoveFillerWords")
        }
        if let fillerWords = settings.fillerWords {
            FillerWordManager.shared.fillerWords = fillerWords
        }
        if let streamingSettings = settings.streamingEnabledByModelName {
            for (modelName, isEnabled) in streamingSettings {
                defaults.set(isEnabled, forKey: "streaming-enabled-\(modelName)")
            }
        }

        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        print("Successfully imported transcription settings.")
    }

    @MainActor
    private static func importModes(from backup: BackupFile) {
        let modeManager = ModeManager.shared
        for config in modeManager.configurations {
            ShortcutStore.removeShortcutStorage(for: .mode(config.id))
        }

        modeManager.configurations = backup.modeConfigs
        let importedModeIds = Set(backup.modeConfigs.map(\.id))

        if let shortcuts = backup.modeShortcuts {
            for (idString, shortcutBackup) in shortcuts {
                guard
                    let id = UUID(uuidString: idString),
                    importedModeIds.contains(id)
                else {
                    continue
                }

                ShortcutStore.setShortcut(shortcutBackup.shortcut, for: .mode(id))
            }
        }

        modeManager.saveConfigurations()

        if let customEmojis = backup.customEmojis {
            let emojiManager = EmojiManager.shared
            for emoji in customEmojis {
                _ = emojiManager.addCustomEmoji(emoji)
            }
        }

        if let powerModeSettings = backup.powerModeSettings {
            if let isEnabled = powerModeSettings.isPowerModeUIEnabled {
                UserDefaults.standard.set(isEnabled, forKey: "powerModeUIFlag")
            }
            if let persist = powerModeSettings.persistConfiguredPreferences {
                UserDefaults.standard.set(persist, forKey: "powerModePersistConfig")
            }
            if let activeId = powerModeSettings.activeConfigurationId,
               let activeConfig = modeManager.configurations.first(where: { $0.id == activeId }) {
                modeManager.setActiveConfiguration(activeConfig)
            } else {
                modeManager.setActiveConfiguration(nil)
            }
        }

        print("Successfully imported \(backup.modeConfigs.count) Mode configurations.")
    }

    @MainActor
    private static func importDictionary(from backup: BackupFile, modelContext: ModelContext) throws {
        var insertedWords = 0
        var insertedReplacements = 0
        var skippedInvalidReplacements = 0

        if let words = backup.vocabularyWords {
            let descriptor = FetchDescriptor<VocabularyWord>()
            let existingWords = try modelContext.fetch(descriptor)
            var existingWordsSet = Set(existingWords.map { $0.word.lowercased() })

            for item in words {
                let word = item.word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty else { continue }

                let lowercasedWord = word.lowercased()
                if !existingWordsSet.contains(lowercasedWord) {
                    modelContext.insert(VocabularyWord(word: word))
                    existingWordsSet.insert(lowercasedWord)
                    insertedWords += 1
                }
            }
        } else {
            print("No vocabulary words found in the imported file. Existing items remain unchanged.")
        }

        if let replacements = backup.wordReplacements {
            let descriptor = FetchDescriptor<WordReplacement>()
            let existingReplacements = try modelContext.fetch(descriptor)

            var existingKeys = Set<String>()
            for existing in existingReplacements {
                existingKeys.formUnion(tokens(from: existing.originalText))
            }

            for (original, replacement) in replacements {
                let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                let importTokens = tokens(from: trimmedOriginal)
                guard !importTokens.isEmpty, !trimmedReplacement.isEmpty else {
                    skippedInvalidReplacements += 1
                    continue
                }

                let hasConflict = importTokens.contains { existingKeys.contains($0) }

                if !hasConflict {
                    modelContext.insert(
                        WordReplacement(originalText: trimmedOriginal, replacementText: trimmedReplacement))
                    existingKeys.formUnion(importTokens)
                    insertedReplacements += 1
                }
            }
        } else {
            print("No word replacements found in the imported file. Existing replacements remain unchanged.")
        }

        guard insertedWords > 0 || insertedReplacements > 0 else {
            print("No new dictionary entries were imported.")
            if skippedInvalidReplacements > 0 {
                print("Skipped \(skippedInvalidReplacements) invalid word replacements from the imported file.")
            }
            DictionaryService.removeExactDuplicateContent(context: modelContext, source: "settings import")
            return
        }

        do {
            try modelContext.save()
            print(
                "Successfully imported \(insertedWords) vocabulary words and \(insertedReplacements) word replacements to SwiftData."
            )
            if skippedInvalidReplacements > 0 {
                print("Skipped \(skippedInvalidReplacements) invalid word replacements from the imported file.")
            }
            DictionaryService.removeExactDuplicateContent(context: modelContext, source: "settings import")
        } catch {
            modelContext.rollback()
            throw BackupImportError.saveFailed("dictionary entries", error)
        }
    }

    @MainActor
    private static func importCustomModels(
        _ models: [CustomModelBackup]?, transcriptionModelManager: TranscriptionModelManager
    ) {
        guard let models else {
            print("No custom models found in the imported file.")
            return
        }

        let customModelManager = CustomCloudModelManager.shared
        customModelManager.customModels = models.map { $0.makeModel() }
        customModelManager.saveCustomModels()
        transcriptionModelManager.refreshAllAvailableModels()
        print("Successfully imported \(models.count) custom model definitions.")
    }

    @MainActor
    private static func restoreSelectedPrompt(from backup: BackupFile, enhancementService: AIEnhancementService) {
        let candidateId = backup.enhancementSettings?.selectedPromptId

        guard let candidateId,
              enhancementService.allPrompts.contains(where: { $0.id == candidateId }) else {
            enhancementService.repairModePromptSelections()
            return
        }

        applyEnhancementSettingsToCurrentMode(
            EnhancementSettingsBackup(
                isEnabled: nil,
                useClipboardContext: nil,
                useScreenCaptureContext: nil,
                selectedPromptId: candidateId,
                selectedProviderRawValue: nil,
                selectedModelByProvider: nil,
                openAIAuthModeRawValue: nil,
                openAIOAuthModel: nil,
                ollamaBaseURL: nil,
                ollamaSelectedModel: nil,
                customProviderBaseURL: nil,
                customProviderModel: nil,
                openRouterModels: nil,
                localCLISelectedTemplateRawValue: nil,
                localCLICommandTemplate: nil,
                localCLITimeoutSeconds: nil,
                skipShortEnhancement: nil,
                shortEnhancementWordThreshold: nil,
                enhancementTimeoutSeconds: nil,
                enhancementRetryOnTimeout: nil
            ),
            enhancementService: enhancementService
        )
    }

    private static func tokens(from text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}
