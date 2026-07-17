import Foundation
import Testing
@testable import VoiceInk

@MainActor
struct HaloOutcomeMetricsTests {
    @Test func recordsOnlyFixedAggregateCountersAndResets() throws {
        let suiteName = "HaloOutcomeMetricsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = HaloOutcomeMetricsStore(defaults: defaults)

        store.record(.reviewShown)
        store.record(.reviewShown)
        store.record(.apply)

        let snapshot = store.snapshot()
        #expect(snapshot[.reviewShown] == 2)
        #expect(snapshot[.apply] == 1)
        #expect(snapshot[.directPaste] == 0)
        #expect(snapshot.total == 3)

        store.reset()
        #expect(store.snapshot().total == 0)
    }

    @Test func ignoresUnknownAndInvalidStoredValues() throws {
        let suiteName = "HaloOutcomeMetricsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [
                HaloOutcomeMetric.copy.rawValue: -8,
                HaloOutcomeMetric.retry.rawValue: 4,
                "transcript text": 99,
            ],
            forKey: "HaloOutcomeMetrics.v1"
        )
        let store = HaloOutcomeMetricsStore(defaults: defaults)

        let snapshot = store.snapshot()
        #expect(snapshot[.copy] == 0)
        #expect(snapshot[.retry] == 4)
        #expect(snapshot.total == 4)
    }
}
