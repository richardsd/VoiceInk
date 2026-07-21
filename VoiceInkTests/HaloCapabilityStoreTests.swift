import Foundation
import Testing
@testable import VoiceInk

@MainActor
struct HaloCapabilityStoreTests {
    @Test func registeredDefaultsStayAlignedWithRecommendedCapabilities() {
        let registered = AppDefaults.registeredDefaults
        let recommended = HaloCapabilityStore.recommendedDefaults

        #expect(
            registered[HaloCapabilitySettingsKeys.spokenRefinementEnabled] as? Bool
                == recommended.spokenRefinementEnabled
        )
        #expect(
            registered[HaloCapabilitySettingsKeys.typedRefinementEnabled] as? Bool
                == recommended.typedRefinementEnabled
        )
        #expect(
            registered[HaloCapabilitySettingsKeys.voiceCommandsEnabled] as? Bool
                == recommended.voiceCommandsEnabled
        )
        #expect(
            registered[HaloCapabilitySettingsKeys.anotherTakeEnabled] as? Bool
                == recommended.anotherTakeEnabled
        )
        #expect(
            registered[HaloCapabilitySettingsKeys.parallelComparisonEnabled] as? Bool
                == recommended.parallelComparisonEnabled
        )
        #expect(
            registered[HaloCapabilitySettingsKeys.guidedRecoveryEnabled] as? Bool
                == recommended.guidedRecoveryEnabled
        )
        #expect(
            registered[HaloCapabilitySettingsKeys.positionBehavior] as? String
                == recommended.positionBehavior.rawValue
        )
        #expect(
            registered[HaloCapabilitySettingsKeys.timeShiftEnabled] as? Bool
                == recommended.timeShiftEnabled
        )
    }

    @Test func missingValuesUseRecommendedDefaults() throws {
        let defaults = try makeDefaults()
        let store = HaloCapabilityStore(userDefaults: defaults)

        #expect(store.snapshot == HaloCapabilityStore.recommendedDefaults)
    }

    @Test func changesPersistAndRoundTrip() throws {
        let defaults = try makeDefaults()
        let store = HaloCapabilityStore(userDefaults: defaults)

        store.spokenRefinementEnabled = false
        store.typedRefinementEnabled = false
        store.voiceCommandsEnabled = false
        store.anotherTakeEnabled = false
        store.parallelComparisonEnabled = true
        store.guidedRecoveryEnabled = false
        store.positionBehavior = .followOriginalCaret
        store.timeShiftEnabled = true

        let restored = HaloCapabilityStore(userDefaults: defaults)
        #expect(restored.snapshot == store.snapshot)
    }

    @Test func partialBackupApplicationPreservesMissingValues() throws {
        let defaults = try makeDefaults()
        let store = HaloCapabilityStore(userDefaults: defaults)

        store.apply(
            spokenRefinementEnabled: nil,
            typedRefinementEnabled: false,
            voiceCommandsEnabled: nil,
            anotherTakeEnabled: nil,
            parallelComparisonEnabled: true,
            guidedRecoveryEnabled: nil,
            positionBehaviorRawValue: HaloPositionBehavior.followOriginalCaret.rawValue,
            timeShiftEnabled: nil
        )

        #expect(store.spokenRefinementEnabled)
        #expect(!store.typedRefinementEnabled)
        #expect(store.voiceCommandsEnabled)
        #expect(store.parallelComparisonEnabled)
        #expect(store.positionBehavior == .followOriginalCaret)
        #expect(!store.timeShiftEnabled)
    }

    @Test func importedDisableImmediatelyRequestsTimeShiftCleanup() throws {
        let defaults = try makeDefaults()
        let store = HaloCapabilityStore(userDefaults: defaults)
        let recorder = TimeShiftDisableNotificationRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .haloTimeShiftDisableRequested,
            object: store,
            queue: nil
        ) { _ in
            recorder.record()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.timeShiftEnabled = true
        store.apply(
            spokenRefinementEnabled: nil,
            typedRefinementEnabled: nil,
            voiceCommandsEnabled: nil,
            anotherTakeEnabled: nil,
            parallelComparisonEnabled: nil,
            guidedRecoveryEnabled: nil,
            positionBehaviorRawValue: nil,
            timeShiftEnabled: false
        )

        #expect(!store.timeShiftEnabled)
        #expect(!defaults.bool(forKey: HaloCapabilitySettingsKeys.timeShiftEnabled))
        #expect(recorder.count == 1)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "HaloCapabilityStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

private final class TimeShiftDisableNotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCount
    }

    func record() {
        lock.lock()
        recordedCount += 1
        lock.unlock()
    }
}
