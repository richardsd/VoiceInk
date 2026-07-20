import Foundation

enum BackupCategory: String, CaseIterable, Hashable {
    case general
    case enhancement
    case transcription
    case prompts
    case modes
    case dictionary
    case customModels

    var title: String {
        switch self {
        case .general:
            return String(localized: "General Settings")
        case .enhancement:
            return String(localized: "AI Enhancement")
        case .transcription:
            return String(localized: "Transcription")
        case .prompts:
            return String(localized: "Custom Prompts")
        case .modes:
            return String(localized: "Modes")
        case .dictionary:
            return String(localized: "Dictionary")
        case .customModels:
            return String(localized: "Custom Model Definitions")
        }
    }
}

struct BackupMetadata: Codable {
    let schemaVersion: Int
    let createdAt: Date
    let appVersion: String
    let bundleIdentifier: String

    init(
        schemaVersion: Int = BackupFile.currentSchemaVersion,
        createdAt: Date = Date(),
        appVersion: String,
        bundleIdentifier: String
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.bundleIdentifier = bundleIdentifier
    }
}

struct CustomModelBackup: Codable {
    let id: UUID
    let name: String
    let displayName: String
    let description: String
    let apiEndpoint: String
    let modelName: String
    let isMultilingualModel: Bool
    let supportedLanguages: [String: String]
    /// Legacy decode-only field. Configuration backups never export or restore API keys.
    let apiKey: String?

    init(model: CustomCloudModel) {
        self.id = model.id
        self.name = model.name
        self.displayName = model.displayName
        self.description = model.description
        self.apiEndpoint = model.apiEndpoint
        self.modelName = model.modelName
        self.isMultilingualModel = model.isMultilingualModel
        self.supportedLanguages = model.supportedLanguages
        self.apiKey = nil
    }

    func makeModel() -> CustomCloudModel {
        CustomCloudModel(
            id: id,
            name: name,
            displayName: displayName,
            description: description,
            apiEndpoint: apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            isMultilingual: isMultilingualModel,
            supportedLanguages: supportedLanguages
        )
    }
}

struct GeneralBackup: Codable {
    let hasCompletedOnboarding: Bool?
    let enableAnnouncements: Bool?
    let autoUpdateCheck: Bool?
    let primaryRecordingShortcut: ShortcutBackup?
    let secondaryRecordingShortcut: ShortcutBackup?
    let pasteLastTranscriptionShortcut: ShortcutBackup?
    let pasteLastEnhancementShortcut: ShortcutBackup?
    let retryLastTranscriptionShortcut: ShortcutBackup?
    let cancelRecorderShortcut: ShortcutBackup?
    let openHistoryWindowShortcut: ShortcutBackup?
    let quickAddToDictionaryShortcut: ShortcutBackup?
    let toggleTimeShiftShortcut: ShortcutBackup?
    let captureTimeShiftShortcut: ShortcutBackup?
    let primaryRecordingShortcutRawValue: String?
    let secondaryRecordingShortcutRawValue: String?
    let primaryRecordingShortcutModeRawValue: String?
    let secondaryRecordingShortcutModeRawValue: String?
    let isMiddleClickToggleEnabled: Bool?
    let middleClickActivationDelay: Int?
    let launchAtLoginEnabled: Bool?
    let isMenuBarOnly: Bool?
    let recorderType: String?
    let appAppearancePreference: String?
    let appLanguagePreference: String?
    let powerModeUIFlag: Bool?
    let powerModePersistConfig: Bool?
    let isTranscriptionCleanupEnabled: Bool?
    let transcriptionRetentionMinutes: Int?
    let isAudioCleanupEnabled: Bool?
    let audioRetentionPeriod: Int?
    let isSoundFeedbackEnabled: Bool?
    let isSystemMuteEnabled: Bool?
    let isPauseMediaEnabled: Bool?
    let audioResumptionDelay: Double?
    let isTextFormattingEnabled: Bool?
    let punctuationCleanupMode: PunctuationCleanupMode?
    let removePunctuation: Bool?
    let lowercaseTranscription: Bool?
    let isExperimentalFeaturesEnabled: Bool?
    let restoreClipboardAfterPaste: Bool?
    let clipboardRestoreDelay: Double?
    let useAppleScriptPaste: Bool?
    let audioInputModeRawValue: String?
    let selectedAudioDeviceUID: String?
    let prioritizedDevices: Data?
    let audioPlaybackRate: Float?
    let isUsingCustomStartSound: Bool?
    let customStartSoundFilename: String?
    let isUsingCustomStopSound: Bool?
    let customStopSoundFilename: String?
    let haloPreferences: HaloPreferencesBackup?
}

struct HaloPreferencesBackup: Codable {
    let spokenRefinementEnabled: Bool?
    let typedRefinementEnabled: Bool?
    let voiceCommandsEnabled: Bool?
    let anotherTakeEnabled: Bool?
    let parallelComparisonEnabled: Bool?
    let guidedRecoveryEnabled: Bool?
    let positionBehaviorRawValue: String?
    let timeShiftEnabled: Bool?
}

struct EnhancementSettingsBackup: Codable {
    let isEnabled: Bool?
    let useClipboardContext: Bool?
    let useScreenCaptureContext: Bool?
    let selectedPromptId: UUID?
    let selectedProviderRawValue: String?
    let selectedModelByProvider: [String: String]?
    let openAIAuthModeRawValue: String?
    let openAIOAuthModel: String?
    let ollamaBaseURL: String?
    let ollamaSelectedModel: String?
    let customProviderBaseURL: String?
    let customProviderModel: String?
    let openRouterModels: [String]?
    let localCLISelectedTemplateRawValue: String?
    let localCLICommandTemplate: String?
    let localCLITimeoutSeconds: Double?
    let skipShortEnhancement: Bool?
    let shortEnhancementWordThreshold: Int?
    let enhancementTimeoutSeconds: Int?
    let enhancementRetryOnTimeout: Bool?
}

struct TranscriptionSettingsBackup: Codable {
    let currentTranscriptionModelName: String?
    let selectedLanguage: String?
    let transcriptionPrompt: String?
    let customLanguagePrompts: [String: String]?
    let isTextFormattingEnabled: Bool?
    let removePunctuation: Bool?
    let lowercaseTranscription: Bool?
    let isVADEnabled: Bool?
    let appendTrailingSpace: Bool?
    let prewarmModelOnWake: Bool?
    let showLiveTextPreview: Bool?
    let removeFillerWords: Bool?
    let fillerWords: [String]?
    let streamingEnabledByModelName: [String: Bool]?
}

struct PowerModeSettingsBackup: Codable {
    let activeConfigurationId: UUID?
    let isPowerModeUIEnabled: Bool?
    let persistConfiguredPreferences: Bool?
}

struct WordBackup: Codable {
    let word: String

    init(word: String) {
        self.word = word
    }
}

struct BackupFile: Codable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let metadata: BackupMetadata?
    let version: String
    let customPrompts: [CustomPrompt]
    let modeConfigs: [ModeConfig]
    let modeShortcuts: [String: ShortcutBackup]?
    let vocabularyWords: [WordBackup]?
    let wordReplacements: [String: String]?
    let generalSettings: GeneralBackup?
    let enhancementSettings: EnhancementSettingsBackup?
    let transcriptionSettings: TranscriptionSettingsBackup?
    let powerModeSettings: PowerModeSettingsBackup?
    let customEmojis: [String]?
    let customCloudModels: [CustomModelBackup]?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, metadata, version, customPrompts, modeConfigs, modeShortcuts, vocabularyWords, wordReplacements
        case generalSettings, enhancementSettings, transcriptionSettings, powerModeSettings, customEmojis, customCloudModels
        case legacyModeConfigs = "powerModeConfigs"
        case legacyModeShortcuts = "powerModeShortcuts"
    }

    init(
        schemaVersion: Int = BackupFile.currentSchemaVersion,
        metadata: BackupMetadata?,
        version: String,
        customPrompts: [CustomPrompt],
        modeConfigs: [ModeConfig],
        modeShortcuts: [String: ShortcutBackup]?,
        vocabularyWords: [WordBackup]?,
        wordReplacements: [String: String]?,
        generalSettings: GeneralBackup?,
        enhancementSettings: EnhancementSettingsBackup?,
        transcriptionSettings: TranscriptionSettingsBackup?,
        powerModeSettings: PowerModeSettingsBackup?,
        customEmojis: [String]?,
        customCloudModels: [CustomModelBackup]?
    ) {
        self.schemaVersion = schemaVersion
        self.metadata = metadata
        self.version = version
        self.customPrompts = customPrompts
        self.modeConfigs = modeConfigs
        self.modeShortcuts = modeShortcuts
        self.vocabularyWords = vocabularyWords
        self.wordReplacements = wordReplacements
        self.generalSettings = generalSettings
        self.enhancementSettings = enhancementSettings
        self.transcriptionSettings = transcriptionSettings
        self.powerModeSettings = powerModeSettings
        self.customEmojis = customEmojis
        self.customCloudModels = customCloudModels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        metadata = try container.decodeIfPresent(BackupMetadata.self, forKey: .metadata)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? metadata?.appVersion ?? "0.0.0"
        customPrompts = try container.decodeIfPresent([CustomPrompt].self, forKey: .customPrompts) ?? []
        modeConfigs = try container.decodeIfPresent([ModeConfig].self, forKey: .modeConfigs)
            ?? container.decodeIfPresent([ModeConfig].self, forKey: .legacyModeConfigs)
            ?? []
        modeShortcuts = try container.decodeIfPresent([String: ShortcutBackup].self, forKey: .modeShortcuts)
            ?? container.decodeIfPresent([String: ShortcutBackup].self, forKey: .legacyModeShortcuts)
        vocabularyWords = try container.decodeIfPresent([WordBackup].self, forKey: .vocabularyWords)
        wordReplacements = try container.decodeIfPresent([String: String].self, forKey: .wordReplacements)
        generalSettings = try container.decodeIfPresent(GeneralBackup.self, forKey: .generalSettings)
        enhancementSettings = try container.decodeIfPresent(EnhancementSettingsBackup.self, forKey: .enhancementSettings)
        transcriptionSettings = try container.decodeIfPresent(TranscriptionSettingsBackup.self, forKey: .transcriptionSettings)
        powerModeSettings = try container.decodeIfPresent(PowerModeSettingsBackup.self, forKey: .powerModeSettings)
        customEmojis = try container.decodeIfPresent([String].self, forKey: .customEmojis)
        customCloudModels = try container.decodeIfPresent([CustomModelBackup].self, forKey: .customCloudModels)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encode(version, forKey: .version)
        try container.encode(customPrompts, forKey: .customPrompts)
        try container.encode(modeConfigs, forKey: .modeConfigs)
        try container.encodeIfPresent(modeShortcuts, forKey: .modeShortcuts)
        try container.encodeIfPresent(vocabularyWords, forKey: .vocabularyWords)
        try container.encodeIfPresent(wordReplacements, forKey: .wordReplacements)
        try container.encodeIfPresent(generalSettings, forKey: .generalSettings)
        try container.encodeIfPresent(enhancementSettings, forKey: .enhancementSettings)
        try container.encodeIfPresent(transcriptionSettings, forKey: .transcriptionSettings)
        try container.encodeIfPresent(powerModeSettings, forKey: .powerModeSettings)
        try container.encodeIfPresent(customEmojis, forKey: .customEmojis)
        try container.encodeIfPresent(customCloudModels, forKey: .customCloudModels)
    }
}
