import Foundation
import Testing
@testable import VoiceInk

@MainActor
struct HaloCapabilityStoreTests {
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

    private func makeDefaults() throws -> UserDefaults {
        let suite = "HaloCapabilityStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
