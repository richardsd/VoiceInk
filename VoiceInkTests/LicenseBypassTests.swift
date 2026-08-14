import Foundation
import Testing
@testable import VoiceInk

@MainActor
struct LicenseBypassTests {
    @Test
    func unrestrictedPolicyNeverExposesTrialState() throws {
        let defaultsName = "LicenseBypassTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let licenseViewModel = LicenseViewModel(
            polarService: LicenseBypassPolarService(),
            licenseManager: LicenseBypassStore(
                state: StoredLicenseState(
                    licenseKey: nil,
                    activationId: nil,
                    trialStartDate: now
                )
            ),
            userDefaults: defaults,
            now: { now },
            bypassesLicenseEnforcement: true
        )

        #expect(licenseViewModel.licenseState == .licensed)
        #expect(licenseViewModel.isLicensed)
        #expect(licenseViewModel.hasVerifiedLicense)
        #expect(licenseViewModel.canUseApp)
        #expect(licenseViewModel.usageRestrictionMessage == nil)
    }
}

private struct LicenseBypassStore: LicenseStoring {
    let state: StoredLicenseState

    func loadStoredState() -> LicenseStorageLoadResult {
        .loaded(state)
    }

    func storeLicense(key: String, activationId: String?) -> Bool {
        true
    }

    func startTrialIfNeeded(at date: Date) -> TrialStartResult {
        .existing(state.trialStartDate ?? date)
    }

    func resetTrial(at date: Date) -> Bool {
        true
    }

    func removeStoredLicense() -> Bool {
        true
    }
}

private struct LicenseBypassPolarService: PolarServicing {
    func checkLicenseRequiresActivation(_ key: String) async throws -> (
        isValid: Bool,
        requiresActivation: Bool,
        activationsLimit: Int?
    ) {
        (true, false, nil)
    }

    func activateLicenseKey(_ key: String) async throws -> (
        activationId: String,
        activationsLimit: Int
    ) {
        ("activation", 1)
    }

    func deactivateLicenseKey(_ key: String, activationId: String) async throws {}

    func validateLicenseKeyWithActivation(_ key: String, activationId: String) async throws -> Bool {
        true
    }
}
