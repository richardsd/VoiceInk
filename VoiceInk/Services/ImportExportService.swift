import Foundation
import AppKit
import UniformTypeIdentifiers
import LaunchAtLogin
import SwiftData

private final class BackupOptions: NSObject {
    let view: NSView

    private let allButton: NSButton
    private let individualButton: NSButton
    private let categoryButtons: [BackupCategory: NSButton]

    override init() {
        let viewHeight = CGFloat(132 + (BackupCategory.allCases.count * 24))
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: viewHeight))
        self.allButton = NSButton(radioButtonWithTitle: String(localized: "All"), target: nil, action: nil)
        self.individualButton = NSButton(radioButtonWithTitle: String(localized: "Individual categories"), target: nil, action: nil)

        var buttons: [BackupCategory: NSButton] = [:]
        for category in BackupCategory.allCases {
            let button = NSButton(checkboxWithTitle: category.title, target: nil, action: nil)
            button.state = .on
            button.isEnabled = false
            buttons[category] = button
        }
        self.categoryButtons = buttons

        super.init()

        allButton.state = .on
        individualButton.state = .off
        allButton.target = self
        allButton.action = #selector(modeChanged(_:))
        individualButton.target = self
        individualButton.action = #selector(modeChanged(_:))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let categoryStack = NSStackView()
        categoryStack.orientation = .vertical
        categoryStack.alignment = .leading
        categoryStack.spacing = 6
        categoryStack.translatesAutoresizingMaskIntoConstraints = false

        for category in BackupCategory.allCases {
            guard let button = categoryButtons[category] else { continue }
            button.target = self
            button.action = #selector(categoryChanged(_:))
            categoryStack.addArrangedSubview(button)
        }

        view.addSubview(stack)
        view.addSubview(categoryStack)
        stack.addArrangedSubview(allButton)
        stack.addArrangedSubview(individualButton)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            categoryStack.topAnchor.constraint(equalTo: individualButton.bottomAnchor, constant: 6),
            categoryStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            categoryStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            categoryStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
        ])
    }

    var selectedCategories: Set<BackupCategory> {
        if allButton.state == .on {
            return Set(BackupCategory.allCases)
        }

        return Set(categoryButtons.compactMap { category, button in
            button.state == .on ? category : nil
        })
    }

    @objc private func modeChanged(_ sender: NSButton) {
        let useAll = sender == allButton
        allButton.state = useAll ? .on : .off
        individualButton.state = useAll ? .off : .on
        setCategoryButtonsEnabled(!useAll)
    }

    @objc private func categoryChanged(_ sender: NSButton) {
        guard individualButton.state != .on else { return }
        allButton.state = .off
        individualButton.state = .on
        setCategoryButtonsEnabled(true)
    }

    private func setCategoryButtonsEnabled(_ isEnabled: Bool) {
        for button in categoryButtons.values {
            button.isEnabled = isEnabled
        }
    }
}

class ImportExportService {
    static let shared = ImportExportService()
    private let currentSettingsVersion: String

    private let keyIsTextFormattingEnabled = "IsTextFormattingEnabled"
    private let keyRemovePunctuation = "RemovePunctuation"
    private let keyLowercaseTranscription = "LowercaseTranscription"

    private init() {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            self.currentSettingsVersion = version
        } else {
            self.currentSettingsVersion = "0.0.0"
        }
    }

    @MainActor
    func exportSettings(
        enhancementService: AIEnhancementService,
        recordingShortcutManager: RecordingShortcutManager,
        menuBarManager: MenuBarManager,
        mediaController: MediaController,
        playbackController: PlaybackController,
        recorderUIManager: RecorderUIManager,
        modelContext: ModelContext,
        transcriptionModelManager: TranscriptionModelManager
    ) {
        let exportedSettings = makeBackupFile(
            enhancementService: enhancementService,
            recordingShortcutManager: recordingShortcutManager,
            menuBarManager: menuBarManager,
            mediaController: mediaController,
            playbackController: playbackController,
            recorderUIManager: recorderUIManager,
            modelContext: modelContext,
            transcriptionModelManager: transcriptionModelManager
        )

        do {
            let jsonData = try makeEncoder().encode(exportedSettings)

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [backupContentType, .json]
            savePanel.nameFieldStringValue = defaultBackupFilename(prefix: "VoiceInk-Configuration")
            savePanel.title = "Create VoiceInk Configuration Backup"
            savePanel.message = "Choose a location to save your configuration. API keys, OAuth tokens, recordings, history, logs, caches, custom sound files, and downloaded models are not included."

            if savePanel.runModal() == .OK, let url = savePanel.url {
                do {
                    try jsonData.write(to: url)
                    showAlert(title: "Backup Created", message: "Your configuration backup was saved to \(url.lastPathComponent).")
                } catch {
                    showAlert(title: "Backup Error", message: "Could not save backup: \(error.localizedDescription)")
                }
            }
        } catch {
            showAlert(title: "Backup Error", message: "Could not encode backup: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func makeBackupFile(
        enhancementService: AIEnhancementService,
        recordingShortcutManager: RecordingShortcutManager,
        menuBarManager: MenuBarManager,
        mediaController: MediaController,
        playbackController: PlaybackController,
        recorderUIManager: RecorderUIManager,
        modelContext: ModelContext,
        transcriptionModelManager: TranscriptionModelManager
    ) -> BackupFile {
        let modeManager = ModeManager.shared
        let emojiManager = EmojiManager.shared
        let aiService = enhancementService.getAIService()
        let defaults = UserDefaults.standard

        let modeConfigs = modeManager.configurations
        let modeShortcuts = Dictionary(uniqueKeysWithValues: modeConfigs.compactMap { config -> (String, ShortcutBackup)? in
            guard let shortcut = ShortcutStore.shortcut(for: .mode(config.id)) else { return nil }
            return (config.id.uuidString, ShortcutBackup(shortcut))
        })

        let vocabularyWords = fetchVocabularyWords(from: modelContext)
        let wordReplacements = fetchWordReplacements(from: modelContext)
        let customModels = CustomCloudModelManager.shared.customModels.map { CustomModelBackup(model: $0) }

        let metadata = BackupMetadata(
            appVersion: currentSettingsVersion,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown"
        )

        let punctuationCleanupMode = PunctuationCleanupMode.current()
        let generalSettingsToExport = GeneralBackup(
            hasCompletedOnboarding: defaults.bool(forKey: "hasCompletedOnboarding"),
            enableAnnouncements: defaults.bool(forKey: "enableAnnouncements"),
            autoUpdateCheck: defaults.bool(forKey: "autoUpdateCheck"),
            primaryRecordingShortcut: ShortcutStore.shortcut(for: .primaryRecording).map(ShortcutBackup.init),
            secondaryRecordingShortcut: ShortcutStore.shortcut(for: .secondaryRecording).map(ShortcutBackup.init),
            pasteLastTranscriptionShortcut: ShortcutStore.shortcut(for: .pasteLastTranscription).map(ShortcutBackup.init),
            pasteLastEnhancementShortcut: ShortcutStore.shortcut(for: .pasteLastEnhancement).map(ShortcutBackup.init),
            retryLastTranscriptionShortcut: ShortcutStore.shortcut(for: .retryLastTranscription).map(ShortcutBackup.init),
            cancelRecorderShortcut: ShortcutStore.shortcut(for: .cancelRecorder).map(ShortcutBackup.init),
            openHistoryWindowShortcut: ShortcutStore.shortcut(for: .openHistoryWindow).map(ShortcutBackup.init),
            quickAddToDictionaryShortcut: ShortcutStore.shortcut(for: .quickAddToDictionary).map(ShortcutBackup.init),
            primaryRecordingShortcutRawValue: recordingShortcutManager.primaryRecordingShortcut.rawValue,
            secondaryRecordingShortcutRawValue: recordingShortcutManager.secondaryRecordingShortcut.rawValue,
            primaryRecordingShortcutModeRawValue: recordingShortcutManager.primaryRecordingShortcutMode.rawValue,
            secondaryRecordingShortcutModeRawValue: recordingShortcutManager.secondaryRecordingShortcutMode.rawValue,
            isMiddleClickToggleEnabled: recordingShortcutManager.isMiddleClickToggleEnabled,
            middleClickActivationDelay: recordingShortcutManager.middleClickActivationDelay,
            launchAtLoginEnabled: LaunchAtLogin.isEnabled,
            isMenuBarOnly: menuBarManager.isMenuBarOnly,
            recorderType: recorderUIManager.recorderPanelStyle.rawValue,
            appAppearancePreference: AppAppearancePreference.stored.rawValue,
            appLanguagePreference: AppLanguagePreference.storedRawValue,
            powerModeUIFlag: defaults.bool(forKey: "powerModeUIFlag"),
            powerModePersistConfig: defaults.bool(forKey: "powerModePersistConfig"),
            isTranscriptionCleanupEnabled: defaults.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled),
            transcriptionRetentionMinutes: defaults.integer(forKey: CleanupSettingsKeys.transcriptionRetentionMinutes),
            isAudioCleanupEnabled: defaults.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled),
            audioRetentionPeriod: defaults.integer(forKey: CleanupSettingsKeys.audioRetentionPeriod),
            isSoundFeedbackEnabled: CustomSoundManager.shared.hasAnyRecordingSoundEnabled,
            isSystemMuteEnabled: mediaController.isSystemMuteEnabled,
            isPauseMediaEnabled: playbackController.isPauseMediaEnabled,
            audioResumptionDelay: mediaController.audioResumptionDelay,
            isTextFormattingEnabled: defaults.bool(forKey: keyIsTextFormattingEnabled),
            punctuationCleanupMode: punctuationCleanupMode,
            removePunctuation: punctuationCleanupMode == .removeAll,
            lowercaseTranscription: defaults.bool(forKey: keyLowercaseTranscription),
            isExperimentalFeaturesEnabled: defaults.bool(forKey: "isExperimentalFeaturesEnabled"),
            restoreClipboardAfterPaste: defaults.bool(forKey: "restoreClipboardAfterPaste"),
            clipboardRestoreDelay: defaults.double(forKey: "clipboardRestoreDelay"),
            useAppleScriptPaste: PasteMethod.current(in: defaults) == .appleScript,
            audioInputModeRawValue: defaults.audioInputModeRawValue,
            selectedAudioDeviceUID: defaults.selectedAudioDeviceUID,
            prioritizedDevices: defaults.prioritizedDevicesData,
            audioPlaybackRate: optionalFloat(forKey: "audioPlaybackRate"),
            isUsingCustomStartSound: defaults.string(forKey: CustomSoundManager.SoundType.start.selectionKey) == "custom",
            customStartSoundFilename: defaults.string(forKey: CustomSoundManager.SoundType.start.filenameKey),
            isUsingCustomStopSound: defaults.string(forKey: CustomSoundManager.SoundType.stop.selectionKey) == "custom",
            customStopSoundFilename: defaults.string(forKey: CustomSoundManager.SoundType.stop.filenameKey)
        )

        let currentMode = modeManager.currentEffectiveConfiguration
        let selectedPromptId = currentMode?.selectedPrompt.flatMap(UUID.init(uuidString:))
        let enhancementSettings = EnhancementSettingsBackup(
            isEnabled: currentMode?.isAIEnhancementEnabled,
            useClipboardContext: currentMode?.useClipboardContext,
            useScreenCaptureContext: currentMode?.useScreenCapture,
            selectedPromptId: selectedPromptId,
            selectedProviderRawValue: aiService?.selectedProvider.rawValue,
            selectedModelByProvider: aiService.map { selectedModelsByProvider(from: $0) },
            openAIAuthModeRawValue: aiService?.openAIAuthMode.rawValue,
            openAIOAuthModel: aiService?.openAIOAuthModel,
            ollamaBaseURL: defaults.string(forKey: "ollamaBaseURL"),
            ollamaSelectedModel: defaults.string(forKey: "ollamaSelectedModel"),
            customProviderBaseURL: defaults.string(forKey: "customProviderBaseURL"),
            customProviderModel: defaults.string(forKey: "customProviderModel"),
            openRouterModels: defaults.array(forKey: "openRouterModels") as? [String],
            localCLISelectedTemplateRawValue: aiService?.localCLITemplateSelection.rawValue,
            localCLICommandTemplate: aiService?.localCLICommandTemplate,
            localCLITimeoutSeconds: aiService?.localCLITimeoutSeconds,
            skipShortEnhancement: defaults.bool(forKey: "SkipShortEnhancement"),
            shortEnhancementWordThreshold: defaults.integer(forKey: "ShortEnhancementWordThreshold"),
            enhancementTimeoutSeconds: defaults.integer(forKey: "EnhancementTimeoutSeconds"),
            enhancementRetryOnTimeout: defaults.bool(forKey: "EnhancementRetryOnTimeout")
        )

        let transcriptionSettings = TranscriptionSettingsBackup(
            currentTranscriptionModelName: transcriptionModelManager.currentTranscriptionModel?.name ?? defaults.string(forKey: "CurrentTranscriptionModel"),
            selectedLanguage: defaults.string(forKey: "SelectedLanguage"),
            transcriptionPrompt: defaults.string(forKey: "TranscriptionPrompt"),
            customLanguagePrompts: defaults.dictionary(forKey: "CustomLanguagePrompts") as? [String: String],
            isTextFormattingEnabled: defaults.bool(forKey: keyIsTextFormattingEnabled),
            removePunctuation: punctuationCleanupMode == .removeAll,
            lowercaseTranscription: defaults.bool(forKey: keyLowercaseTranscription),
            isVADEnabled: defaults.bool(forKey: "IsVADEnabled"),
            appendTrailingSpace: defaults.bool(forKey: "AppendTrailingSpace"),
            prewarmModelOnWake: defaults.bool(forKey: "PrewarmModelOnWake"),
            showLiveTextPreview: defaults.bool(forKey: "showLiveTextPreview"),
            removeFillerWords: defaults.bool(forKey: "RemoveFillerWords"),
            fillerWords: FillerWordManager.shared.fillerWords,
            streamingEnabledByModelName: streamingSettings(from: transcriptionModelManager)
        )

        let powerModeSettings = PowerModeSettingsBackup(
            activeConfigurationId: modeManager.activeConfiguration?.id,
            isPowerModeUIEnabled: defaults.bool(forKey: "powerModeUIFlag"),
            persistConfiguredPreferences: defaults.bool(forKey: "powerModePersistConfig")
        )

        return BackupFile(
            metadata: metadata,
            version: currentSettingsVersion,
            customPrompts: enhancementService.customPrompts,
            modeConfigs: modeConfigs,
            modeShortcuts: modeShortcuts.isEmpty ? nil : modeShortcuts,
            vocabularyWords: vocabularyWords,
            wordReplacements: wordReplacements,
            generalSettings: generalSettingsToExport,
            enhancementSettings: enhancementSettings,
            transcriptionSettings: transcriptionSettings,
            powerModeSettings: powerModeSettings,
            customEmojis: emojiManager.customEmojis,
            customCloudModels: customModels
        )
    }

    @MainActor
    func importSettings(
        enhancementService: AIEnhancementService,
        recordingShortcutManager: RecordingShortcutManager,
        menuBarManager: MenuBarManager,
        mediaController: MediaController,
        playbackController: PlaybackController,
        recorderUIManager: RecorderUIManager,
        modelContext: ModelContext,
        transcriptionModelManager: TranscriptionModelManager
    ) {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [backupContentType, .json]
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.title = String(localized: "Restore VoiceInk Configuration")
        openPanel.message = String(localized: "Choose a VoiceInk configuration backup. API keys, OAuth tokens, recordings, history, logs, caches, custom sound files, and downloaded models are not restored.")

        guard openPanel.runModal() == .OK else {
            showAlert(title: String(localized: "Restore Canceled"), message: String(localized: "The configuration restore operation was canceled."))
            return
        }

        guard let url = openPanel.url else {
            showAlert(title: String(localized: "Restore Error"), message: String(localized: "Could not get the file URL from the open panel."))
            return
        }

        do {
            let jsonData = try Data(contentsOf: url)
            let decoder = makeDecoder()
            let backup = try decoder.decode(BackupFile.self, from: jsonData)

            guard presentImportPreviewDialog(backup: backup, fileName: url.lastPathComponent) else {
                showAlert(title: String(localized: "Restore Canceled"), message: String(localized: "No settings were restored."))
                return
            }

            guard let selectedCategories = presentImportSelectionDialog() else {
                showAlert(title: String(localized: "Restore Canceled"), message: String(localized: "No settings were restored."))
                return
            }

            guard !selectedCategories.isEmpty else {
                showAlert(title: String(localized: "Restore Error"), message: String(localized: "Select at least one category to restore."))
                return
            }

            let preRestoreBackupURL = try createPreRestoreBackup(
                enhancementService: enhancementService,
                recordingShortcutManager: recordingShortcutManager,
                menuBarManager: menuBarManager,
                mediaController: mediaController,
                playbackController: playbackController,
                recorderUIManager: recorderUIManager,
                modelContext: modelContext,
                transcriptionModelManager: transcriptionModelManager
            )

            try BackupImporter.apply(
                backup,
                categories: selectedCategories,
                enhancementService: enhancementService,
                recordingShortcutManager: recordingShortcutManager,
                menuBarManager: menuBarManager,
                mediaController: mediaController,
                playbackController: playbackController,
                recorderUIManager: recorderUIManager,
                modelContext: modelContext,
                transcriptionModelManager: transcriptionModelManager
            )

            showImportSuccessAlert(
                message: String(
                    format: String(localized: "Configuration restored from %@.\n\nRestored: %@.\n\nA pre-restore backup was saved as %@."),
                    url.lastPathComponent,
                    categorySummary(for: selectedCategories),
                    preRestoreBackupURL.lastPathComponent
                ),
                needsAPIKeyReminder: needsAPIKeyReminder(for: selectedCategories)
            )
        } catch {
            showAlert(
                title: String(localized: "Restore Error"),
                message: String(format: String(localized: "Error restoring configuration: %@. The file might be corrupted or not in the correct format."), error.localizedDescription)
            )
        }
    }

    private func presentImportPreviewDialog(backup: BackupFile, fileName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Restore Configuration?"
        alert.informativeText = importPreviewText(for: backup, fileName: fileName)
        alert.alertStyle = backupHasBundleMismatch(backup) ? .warning : .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentImportSelectionDialog() -> Set<BackupCategory>? {
        let accessory = BackupOptions()
        let alert = NSAlert()
        alert.messageText = String(localized: "Restore Configuration")
        alert.informativeText = String(localized: "Choose what to restore from this backup.")
        alert.alertStyle = .informational
        alert.accessoryView = accessory.view
        alert.addButton(withTitle: String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return nil
        }

        return accessory.selectedCategories
    }

    private func categorySummary(for categories: Set<BackupCategory>) -> String {
        if categories == Set(BackupCategory.allCases) {
            return String(localized: "All settings")
        }

        return BackupCategory.allCases
            .filter { categories.contains($0) }
            .map(\.title)
            .joined(separator: ", ")
    }

    private func needsAPIKeyReminder(for categories: Set<BackupCategory>) -> Bool {
        !categories.isDisjoint(with: [.enhancement, .prompts, .modes, .customModels])
    }

    private var backupContentType: UTType {
        UTType(filenameExtension: "voiceinkbackup") ?? .json
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func fetchVocabularyWords(from modelContext: ModelContext) -> [WordBackup]? {
        let descriptor = FetchDescriptor<VocabularyWord>()
        guard let items = try? modelContext.fetch(descriptor), !items.isEmpty else {
            return nil
        }
        return items.map { WordBackup(word: $0.word) }
    }

    private func fetchWordReplacements(from modelContext: ModelContext) -> [String: String]? {
        let descriptor = FetchDescriptor<WordReplacement>()
        guard let replacements = try? modelContext.fetch(descriptor), !replacements.isEmpty else {
            return nil
        }
        return Dictionary(replacements.map { ($0.originalText, $0.replacementText) }, uniquingKeysWith: { _, last in last })
    }

    private func selectedModelsByProvider(from aiService: AIService) -> [String: String] {
        Dictionary(uniqueKeysWithValues: AIProvider.allCases.compactMap { provider in
            let model = aiService.selectedModel(for: provider, authMode: provider == .openAI ? .apiKey : nil)
            return model.isEmpty ? nil : (provider.rawValue, model)
        })
    }

    @MainActor
    private func streamingSettings(from transcriptionModelManager: TranscriptionModelManager) -> [String: Bool]? {
        let defaults = UserDefaults.standard
        let settings = Dictionary(uniqueKeysWithValues: transcriptionModelManager.allAvailableModels.compactMap { model -> (String, Bool)? in
            let key = "streaming-enabled-\(model.name)"
            guard defaults.object(forKey: key) != nil else { return nil }
            return (model.name, defaults.bool(forKey: key))
        })
        return settings.isEmpty ? nil : settings
    }

    private func optionalFloat(forKey key: String) -> Float? {
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.float(forKey: key)
    }

    @MainActor
    private func createPreRestoreBackup(
        enhancementService: AIEnhancementService,
        recordingShortcutManager: RecordingShortcutManager,
        menuBarManager: MenuBarManager,
        mediaController: MediaController,
        playbackController: PlaybackController,
        recorderUIManager: RecorderUIManager,
        modelContext: ModelContext,
        transcriptionModelManager: TranscriptionModelManager
    ) throws -> URL {
        let backup = makeBackupFile(
            enhancementService: enhancementService,
            recordingShortcutManager: recordingShortcutManager,
            menuBarManager: menuBarManager,
            mediaController: mediaController,
            playbackController: playbackController,
            recorderUIManager: recorderUIManager,
            modelContext: modelContext,
            transcriptionModelManager: transcriptionModelManager
        )
        let directory = try backupsDirectory()
        let url = directory.appendingPathComponent(defaultBackupFilename(prefix: "VoiceInk-PreRestore"))
        try makeEncoder().encode(backup).write(to: url)
        return url
    }

    private func backupsDirectory() throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "VoiceInkBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Application Support directory is unavailable."])
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "VoiceInk"
        let directory = appSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func defaultBackupFilename(prefix: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return "\(prefix)-\(formatter.string(from: Date())).voiceinkbackup"
    }

    private func importPreviewText(for backup: BackupFile, fileName: String) -> String {
        var lines = [
            "File: \(fileName)",
            "Schema: v\(backup.schemaVersion)",
            "App version: \(backup.version)",
            "Bundle ID: \(backup.metadata?.bundleIdentifier ?? "Unknown")",
            "Custom prompts: \(backup.customPrompts.count)",
            "Modes: \(backup.modeConfigs.count)",
            "Vocabulary words: \(backup.vocabularyWords?.count ?? 0)",
            "Word replacements: \(backup.wordReplacements?.count ?? 0)",
            "Custom model definitions: \(backup.customCloudModels?.count ?? 0)"
        ]

        if backup.version != currentSettingsVersion {
            lines.append("")
            lines.append("This backup was created by a different app version. VoiceInk will try to restore compatible settings.")
        }

        if backupHasBundleMismatch(backup) {
            lines.append("")
            lines.append("Warning: this backup was created by a different bundle ID than the app currently running.")
        }

        lines.append("")
        lines.append("API keys, OAuth tokens, recordings, history, logs, caches, custom sound files, and downloaded models are not restored.")
        lines.append("VoiceInk will create a pre-restore backup before applying changes.")

        return lines.joined(separator: "\n")
    }

    private func backupHasBundleMismatch(_ backup: BackupFile) -> Bool {
        guard let backupBundleIdentifier = backup.metadata?.bundleIdentifier,
              backupBundleIdentifier != "unknown",
              let currentBundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }
        return backupBundleIdentifier != currentBundleIdentifier
    }

    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
        }
    }

    private func showImportSuccessAlert(message: String, needsAPIKeyReminder: Bool) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = String(localized: "Restore Successful")
            var informativeText = message
            if needsAPIKeyReminder {
                informativeText += "\n\n" + String(localized: "IMPORTANT: If you were using AI enhancement features, please make sure to reconfigure your API keys in the AI Models section.")
            }
            informativeText += "\n\n" + String(localized: "It is recommended to restart VoiceInk for all changes to take full effect.")
            alert.informativeText = informativeText
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "OK"))
            if needsAPIKeyReminder {
                alert.addButton(withTitle: String(localized: "Configure API Keys"))
            }

            let response = alert.runModal()
            if needsAPIKeyReminder && response == .alertSecondButtonReturn {
                NotificationCenter.default.post(
                    name: .navigateToDestination,
                    object: nil,
                    userInfo: ["destination": "AI Models"]
                )
            }
        }
    }
}
