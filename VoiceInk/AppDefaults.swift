import Foundation

enum CleanupSettingsKeys {
    static let isTranscriptionCleanupEnabled = "IsTranscriptionCleanupEnabled"
    static let transcriptionRetentionMinutes = "TranscriptionRetentionMinutes"
    static let isAudioCleanupEnabled = "IsAudioCleanupEnabled"
    static let audioRetentionPeriod = "AudioRetentionPeriod"
    static let lastAutomaticAudioCleanupDate = "AudioCleanupLastAutomaticCleanupDate"
}

enum RecorderDisplaySettingsKeys {
    static let showLiveTranscript = "ShowLiveTranscript"
}

enum AppDefaults {
    /// The complete registered-default domain. Keeping this value observable
    /// to the test target prevents Halo's product defaults from drifting away
    /// from `HaloCapabilityStore.recommendedDefaults`.
    static let registeredDefaults: [String: Any] = [
        // Onboarding & General
        "hasCompletedOnboardingV2": false,
        "hasPreparedOnboardingV2": false,
        "enableAnnouncements": true,

        // Clipboard
        "restoreClipboardAfterPaste": true,
        "clipboardRestoreDelay": 2.0,
        "useAppleScriptPaste": false,

        // Audio & Media
        "isSystemMuteEnabled": true,
        "audioResumptionDelay": 0.0,
        "isPauseMediaEnabled": false,
        CustomSoundManager.SoundType.start.builtInSoundKey: CustomSoundManager.SoundType.start.defaultBuiltInSound
            .rawValue,
        CustomSoundManager.SoundType.stop.builtInSoundKey: CustomSoundManager.SoundType.stop.defaultBuiltInSound
            .rawValue,

        // Recording & Transcription
        "IsTextFormattingEnabled": true,
        "IsVADEnabled": true,
        "SelectedLanguage": "en",
        "AppendTrailingSpace": true,
        "RecorderType": "mini",
        RecorderDisplaySettingsKeys.showLiveTranscript: true,

        // Halo capabilities
        HaloCapabilitySettingsKeys.spokenRefinementEnabled: true,
        HaloCapabilitySettingsKeys.typedRefinementEnabled: true,
        HaloCapabilitySettingsKeys.voiceCommandsEnabled: true,
        HaloCapabilitySettingsKeys.anotherTakeEnabled: true,
        HaloCapabilitySettingsKeys.parallelComparisonEnabled: false,
        HaloCapabilitySettingsKeys.guidedRecoveryEnabled: true,
        HaloCapabilitySettingsKeys.positionBehavior: HaloPositionBehavior.stableAnchor.rawValue,
        HaloCapabilitySettingsKeys.timeShiftEnabled: false,

        // Cleanup
        CleanupSettingsKeys.isTranscriptionCleanupEnabled: false,
        CleanupSettingsKeys.transcriptionRetentionMinutes: 1440,
        CleanupSettingsKeys.isAudioCleanupEnabled: false,
        CleanupSettingsKeys.audioRetentionPeriod: 7,

        // UI & Behavior
        "IsMenuBarOnly": false,
        AppAppearancePreference.userDefaultsKey: AppAppearancePreference.system.rawValue,
        AppLanguagePreference.userDefaultsKey: AppLanguagePreference.systemValue,
        // Shortcuts
        "isMiddleClickToggleEnabled": false,
        "middleClickActivationDelay": 200,

        // Enhancement
        "SkipShortEnhancement": true,
        "ShortEnhancementWordThreshold": 3,
        "EnhancementTimeoutSeconds": 7,
        "EnhancementRetryOnTimeout": true,

        // Model
        "PrewarmModelOnWake": true,

    ]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: registeredDefaults)

        PasteMethod.migrateLegacyUserDefaultIfNeeded()
    }
}
