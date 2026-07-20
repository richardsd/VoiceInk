import Foundation
import Testing
@testable import VoiceInk

struct BackupSchemaCompatibilityTests {
    @Test func schemaThreeEncodesVersionAndMetadata() throws {
        let metadata = BackupMetadata(
            appVersion: "9.9.9",
            bundleIdentifier: "com.example.voiceink-tests"
        )
        let backup = BackupFile(
            metadata: metadata,
            version: "9.9.9",
            customPrompts: [],
            modeConfigs: [],
            modeShortcuts: nil,
            vocabularyWords: nil,
            wordReplacements: nil,
            generalSettings: nil,
            enhancementSettings: nil,
            transcriptionSettings: nil,
            powerModeSettings: nil,
            customEmojis: nil,
            customCloudModels: nil
        )

        let data = try JSONEncoder().encode(backup)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["schemaVersion"] as? Int == 3)
        #expect((object["metadata"] as? [String: Any])?["bundleIdentifier"] as? String == "com.example.voiceink-tests")
    }

    @Test func legacyBackupWithoutSchemaOrMetadataStillDecodesAsVersionOne() throws {
        let data = Data(#"{"version":"1.0","customPrompts":[],"modeConfigs":[]}"#.utf8)
        let backup = try JSONDecoder().decode(BackupFile.self, from: data)

        #expect(backup.schemaVersion == 1)
        #expect(backup.metadata == nil)
    }

    @Test func schemaTwoBackupWithoutHaloPreferencesKeepsThemAbsent() throws {
        let data = Data(
            #"{"schemaVersion":2,"version":"2.0","customPrompts":[],"modeConfigs":[],"generalSettings":{"enableAnnouncements":true}}"#.utf8
        )
        let backup = try JSONDecoder().decode(BackupFile.self, from: data)

        #expect(backup.schemaVersion == 2)
        #expect(backup.generalSettings?.haloPreferences == nil)
        #expect(backup.generalSettings?.toggleTimeShiftShortcut == nil)
        #expect(backup.generalSettings?.captureTimeShiftShortcut == nil)
    }
}
