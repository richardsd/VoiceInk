import Combine
import Foundation

enum HaloPositionBehavior: String, CaseIterable, Codable, Identifiable, Sendable {
    case stableAnchor
    case followOriginalCaret

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stableAnchor:
            return String(localized: "Stable Anchor")
        case .followOriginalCaret:
            return String(localized: "Follow Original Caret")
        }
    }
}

enum HaloCapabilitySettingsKeys {
    static let spokenRefinementEnabled = "HaloSpokenRefinementEnabled"
    static let typedRefinementEnabled = "HaloTypedRefinementEnabled"
    static let voiceCommandsEnabled = "HaloVoiceCommandsEnabled"
    static let anotherTakeEnabled = "HaloAnotherTakeEnabled"
    static let parallelComparisonEnabled = "HaloParallelComparisonEnabled"
    static let guidedRecoveryEnabled = "HaloGuidedRecoveryEnabled"
    static let positionBehavior = "HaloPositionBehavior"
    static let timeShiftEnabled = "HaloTimeShiftEnabled"
}

struct HaloCapabilitySnapshot: Equatable, Sendable {
    let spokenRefinementEnabled: Bool
    let typedRefinementEnabled: Bool
    let voiceCommandsEnabled: Bool
    let anotherTakeEnabled: Bool
    let parallelComparisonEnabled: Bool
    let guidedRecoveryEnabled: Bool
    let positionBehavior: HaloPositionBehavior
    let timeShiftEnabled: Bool
}

@MainActor
final class HaloCapabilityStore: ObservableObject {
    static let recommendedDefaults = HaloCapabilitySnapshot(
        spokenRefinementEnabled: true,
        typedRefinementEnabled: true,
        voiceCommandsEnabled: true,
        anotherTakeEnabled: true,
        parallelComparisonEnabled: false,
        guidedRecoveryEnabled: true,
        positionBehavior: .stableAnchor,
        timeShiftEnabled: false
    )

    @Published var spokenRefinementEnabled: Bool {
        didSet { persist(spokenRefinementEnabled, key: HaloCapabilitySettingsKeys.spokenRefinementEnabled) }
    }

    @Published var typedRefinementEnabled: Bool {
        didSet { persist(typedRefinementEnabled, key: HaloCapabilitySettingsKeys.typedRefinementEnabled) }
    }

    @Published var voiceCommandsEnabled: Bool {
        didSet { persist(voiceCommandsEnabled, key: HaloCapabilitySettingsKeys.voiceCommandsEnabled) }
    }

    @Published var anotherTakeEnabled: Bool {
        didSet { persist(anotherTakeEnabled, key: HaloCapabilitySettingsKeys.anotherTakeEnabled) }
    }

    @Published var parallelComparisonEnabled: Bool {
        didSet { persist(parallelComparisonEnabled, key: HaloCapabilitySettingsKeys.parallelComparisonEnabled) }
    }

    @Published var guidedRecoveryEnabled: Bool {
        didSet { persist(guidedRecoveryEnabled, key: HaloCapabilitySettingsKeys.guidedRecoveryEnabled) }
    }

    @Published var positionBehavior: HaloPositionBehavior {
        didSet { persist(positionBehavior.rawValue, key: HaloCapabilitySettingsKeys.positionBehavior) }
    }

    @Published var timeShiftEnabled: Bool {
        didSet {
            persist(timeShiftEnabled, key: HaloCapabilitySettingsKeys.timeShiftEnabled)
            if !timeShiftEnabled {
                NotificationCenter.default.post(name: .haloTimeShiftDisableRequested, object: self)
            }
        }
    }

    private let userDefaults: UserDefaults
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let defaults = Self.recommendedDefaults
        spokenRefinementEnabled = Self.bool(
            in: userDefaults,
            key: HaloCapabilitySettingsKeys.spokenRefinementEnabled,
            fallback: defaults.spokenRefinementEnabled
        )
        typedRefinementEnabled = Self.bool(
            in: userDefaults,
            key: HaloCapabilitySettingsKeys.typedRefinementEnabled,
            fallback: defaults.typedRefinementEnabled
        )
        voiceCommandsEnabled = Self.bool(
            in: userDefaults,
            key: HaloCapabilitySettingsKeys.voiceCommandsEnabled,
            fallback: defaults.voiceCommandsEnabled
        )
        anotherTakeEnabled = Self.bool(
            in: userDefaults,
            key: HaloCapabilitySettingsKeys.anotherTakeEnabled,
            fallback: defaults.anotherTakeEnabled
        )
        parallelComparisonEnabled = Self.bool(
            in: userDefaults,
            key: HaloCapabilitySettingsKeys.parallelComparisonEnabled,
            fallback: defaults.parallelComparisonEnabled
        )
        guidedRecoveryEnabled = Self.bool(
            in: userDefaults,
            key: HaloCapabilitySettingsKeys.guidedRecoveryEnabled,
            fallback: defaults.guidedRecoveryEnabled
        )
        positionBehavior = userDefaults.string(forKey: HaloCapabilitySettingsKeys.positionBehavior)
            .flatMap(HaloPositionBehavior.init(rawValue:)) ?? defaults.positionBehavior
        timeShiftEnabled = Self.bool(
            in: userDefaults,
            key: HaloCapabilitySettingsKeys.timeShiftEnabled,
            fallback: defaults.timeShiftEnabled
        )
    }

    var snapshot: HaloCapabilitySnapshot {
        HaloCapabilitySnapshot(
            spokenRefinementEnabled: spokenRefinementEnabled,
            typedRefinementEnabled: typedRefinementEnabled,
            voiceCommandsEnabled: voiceCommandsEnabled,
            anotherTakeEnabled: anotherTakeEnabled,
            parallelComparisonEnabled: parallelComparisonEnabled,
            guidedRecoveryEnabled: guidedRecoveryEnabled,
            positionBehavior: positionBehavior,
            timeShiftEnabled: timeShiftEnabled
        )
    }

    func apply(
        spokenRefinementEnabled: Bool?,
        typedRefinementEnabled: Bool?,
        voiceCommandsEnabled: Bool?,
        anotherTakeEnabled: Bool?,
        parallelComparisonEnabled: Bool?,
        guidedRecoveryEnabled: Bool?,
        positionBehaviorRawValue: String?,
        timeShiftEnabled: Bool?
    ) {
        if let spokenRefinementEnabled { self.spokenRefinementEnabled = spokenRefinementEnabled }
        if let typedRefinementEnabled { self.typedRefinementEnabled = typedRefinementEnabled }
        if let voiceCommandsEnabled { self.voiceCommandsEnabled = voiceCommandsEnabled }
        if let anotherTakeEnabled { self.anotherTakeEnabled = anotherTakeEnabled }
        if let parallelComparisonEnabled { self.parallelComparisonEnabled = parallelComparisonEnabled }
        if let guidedRecoveryEnabled { self.guidedRecoveryEnabled = guidedRecoveryEnabled }
        if let positionBehaviorRawValue,
            let behavior = HaloPositionBehavior(rawValue: positionBehaviorRawValue)
        {
            positionBehavior = behavior
        }
        if let timeShiftEnabled { self.timeShiftEnabled = timeShiftEnabled }
    }

    private func persist(_ value: Any, key: String) {
        userDefaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .haloCapabilitiesDidChange, object: self)
    }

    private static func bool(in defaults: UserDefaults, key: String, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}
