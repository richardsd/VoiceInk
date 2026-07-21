import AppKit
import Carbon.HIToolbox
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

    @MainActor
    @Test func restoringSchemaTwoLeavesCurrentHaloCapabilitiesAndShortcutsUntouched() throws {
        let data = Data(
            #"{"schemaVersion":2,"version":"2.0","customPrompts":[],"modeConfigs":[],"generalSettings":{"enableAnnouncements":true}}"#.utf8
        )
        let backup = try JSONDecoder().decode(BackupFile.self, from: data)
        let general = try #require(backup.generalSettings)
        let defaultsSuite = "BackupSchemaCompatibilityTests.v2.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let capabilities = HaloCapabilityStore(userDefaults: defaults)
        capabilities.spokenRefinementEnabled = false
        capabilities.positionBehavior = .followOriginalCaret
        capabilities.timeShiftEnabled = true
        let before = capabilities.snapshot
        var restoredActions: [ShortcutAction] = []

        BackupImporter.restoreHaloConfiguration(
            from: general,
            haloCapabilityStore: capabilities,
            shortcutWriter: { _, action in restoredActions.append(action) }
        )

        #expect(capabilities.snapshot == before)
        #expect(restoredActions.isEmpty)
    }

    @Test func schemaThreeRoundTripsHaloPreferencesAndBothTimeShiftShortcuts() throws {
        let toggleShortcut = Shortcut.key(
            keyCode: UInt16(kVK_F18),
            modifierFlags: []
        )
        let captureShortcut = Shortcut.key(
            keyCode: UInt16(kVK_F19),
            modifierFlags: []
        )
        let data = try schemaThreeData(
            toggleShortcut: toggleShortcut,
            captureShortcut: captureShortcut
        )

        let decoded = try JSONDecoder().decode(BackupFile.self, from: data)
        let general = try #require(decoded.generalSettings)
        let halo = try #require(general.haloPreferences)

        #expect(decoded.schemaVersion == 3)
        #expect(general.toggleTimeShiftShortcut?.shortcut == toggleShortcut)
        #expect(general.captureTimeShiftShortcut?.shortcut == captureShortcut)
        #expect(halo.spokenRefinementEnabled == false)
        #expect(halo.typedRefinementEnabled == true)
        #expect(halo.voiceCommandsEnabled == false)
        #expect(halo.anotherTakeEnabled == false)
        #expect(halo.parallelComparisonEnabled == true)
        #expect(halo.guidedRecoveryEnabled == false)
        #expect(halo.positionBehaviorRawValue == HaloPositionBehavior.followOriginalCaret.rawValue)
        #expect(halo.timeShiftEnabled == false)

        let roundTripped = try JSONDecoder().decode(
            BackupFile.self,
            from: JSONEncoder().encode(decoded)
        )
        #expect(roundTripped.generalSettings?.toggleTimeShiftShortcut?.shortcut == toggleShortcut)
        #expect(roundTripped.generalSettings?.captureTimeShiftShortcut?.shortcut == captureShortcut)
        #expect(
            roundTripped.generalSettings?.haloPreferences?.positionBehaviorRawValue
                == HaloPositionBehavior.followOriginalCaret.rawValue
        )
    }

    @MainActor
    @Test func restoringSchemaThreeReconcilesCapabilitiesAndTimeShiftShortcutsImmediately() throws {
        let toggleShortcut = Shortcut.key(
            keyCode: UInt16(kVK_F18),
            modifierFlags: []
        )
        let captureShortcut = Shortcut.key(
            keyCode: UInt16(kVK_F19),
            modifierFlags: []
        )
        let backup = try JSONDecoder().decode(
            BackupFile.self,
            from: schemaThreeData(
                toggleShortcut: toggleShortcut,
                captureShortcut: captureShortcut
            )
        )
        let general = try #require(backup.generalSettings)
        let defaultsSuite = "BackupSchemaCompatibilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        let capabilities = HaloCapabilityStore(userDefaults: defaults)
        capabilities.timeShiftEnabled = true
        var restoredShortcuts: [ShortcutAction: Shortcut] = [:]
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        BackupImporter.restoreHaloConfiguration(
            from: general,
            haloCapabilityStore: capabilities,
            shortcutWriter: { shortcut, action in
                restoredShortcuts[action] = shortcut
            }
        )

        #expect(capabilities.snapshot == HaloCapabilitySnapshot(
            spokenRefinementEnabled: false,
            typedRefinementEnabled: true,
            voiceCommandsEnabled: false,
            anotherTakeEnabled: false,
            parallelComparisonEnabled: true,
            guidedRecoveryEnabled: false,
            positionBehavior: .followOriginalCaret,
            timeShiftEnabled: false
        ))
        #expect(restoredShortcuts[.toggleTimeShift] == toggleShortcut)
        #expect(restoredShortcuts[.captureTimeShift] == captureShortcut)
    }

    private func schemaThreeData(
        toggleShortcut: Shortcut,
        captureShortcut: Shortcut
    ) throws -> Data {
        let encoder = JSONEncoder()
        let toggleObject = try JSONSerialization.jsonObject(
            with: encoder.encode(ShortcutBackup(toggleShortcut))
        )
        let captureObject = try JSONSerialization.jsonObject(
            with: encoder.encode(ShortcutBackup(captureShortcut))
        )
        let object: [String: Any] = [
            "schemaVersion": 3,
            "version": "3.0",
            "customPrompts": [],
            "modeConfigs": [],
            "generalSettings": [
                "toggleTimeShiftShortcut": toggleObject,
                "captureTimeShiftShortcut": captureObject,
                "haloPreferences": [
                    "spokenRefinementEnabled": false,
                    "typedRefinementEnabled": true,
                    "voiceCommandsEnabled": false,
                    "anotherTakeEnabled": false,
                    "parallelComparisonEnabled": true,
                    "guidedRecoveryEnabled": false,
                    "positionBehaviorRawValue": HaloPositionBehavior.followOriginalCaret.rawValue,
                    "timeShiftEnabled": false,
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
