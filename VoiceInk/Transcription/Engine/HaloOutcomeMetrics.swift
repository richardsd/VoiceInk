import Foundation

enum HaloOutcomeMetric: String, CaseIterable, Codable, Sendable {
    case directPaste
    case reviewShown
    case apply
    case cancel
    case copy
    case expiry
    case destinationMismatch
    case retry
    case refinementSuccess
    case refinementFailure
    case useOriginal
    case manualEdit
}

enum HaloReviewCancellationReason: Equatable, Sendable {
    case user
    case expiry
}

struct HaloOutcomeMetricsSnapshot: Equatable, Sendable {
    private let counts: [HaloOutcomeMetric: Int]

    init(counts: [HaloOutcomeMetric: Int] = [:]) {
        self.counts = counts
    }

    subscript(metric: HaloOutcomeMetric) -> Int {
        counts[metric, default: 0]
    }

    var total: Int {
        counts.values.reduce(0, +)
    }
}

@MainActor
protocol HaloOutcomeRecording: AnyObject {
    func record(_ metric: HaloOutcomeMetric)
    func snapshot() -> HaloOutcomeMetricsSnapshot
    func reset()
}

/// Fixed-key, aggregate-only product evidence. No method accepts text or any
/// recording, application, provider, model, prompt, or destination identity.
@MainActor
final class HaloOutcomeMetricsStore: HaloOutcomeRecording {
    static let shared = HaloOutcomeMetricsStore()

    private static let storageKey = "HaloOutcomeMetrics.v1"
    private static let maximumCount = 1_000_000_000

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(_ metric: HaloOutcomeMetric) {
        var stored = storedCounts()
        stored[metric.rawValue] = min(
            Self.maximumCount,
            stored[metric.rawValue, default: 0] + 1
        )
        defaults.set(stored, forKey: Self.storageKey)
    }

    func snapshot() -> HaloOutcomeMetricsSnapshot {
        let stored = storedCounts()
        let counts = Dictionary(uniqueKeysWithValues: HaloOutcomeMetric.allCases.map {
            ($0, stored[$0.rawValue, default: 0])
        })
        return HaloOutcomeMetricsSnapshot(counts: counts)
    }

    func reset() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func storedCounts() -> [String: Int] {
        guard let raw = defaults.dictionary(forKey: Self.storageKey) else {
            return [:]
        }

        var bounded: [String: Int] = [:]
        for metric in HaloOutcomeMetric.allCases {
            guard let value = raw[metric.rawValue] as? NSNumber else { continue }
            bounded[metric.rawValue] = min(
                Self.maximumCount,
                max(0, value.intValue)
            )
        }
        return bounded
    }
}
