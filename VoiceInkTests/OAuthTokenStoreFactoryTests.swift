import Foundation
import Testing
@testable import VoiceInk

@Suite("OAuth token store factory")
struct OAuthTokenStoreFactoryTests {
    @Test func appHostedTestsUseAnIsolatedEphemeralStore() throws {
        let firstStore = OAuthTokenStoreFactory.applicationDefault(
            environment: ["XCTestConfigurationFilePath": "/tmp/VoiceInk.xctestconfiguration"]
        )
        let secondStore = OAuthTokenStoreFactory.applicationDefault(
            environment: ["XCTestConfigurationFilePath": "/tmp/VoiceInk.xctestconfiguration"]
        )
        let tokens = OAuthTokens(
            accessToken: "test-access-token",
            refreshToken: "test-refresh-token",
            expiresIn: 3_600,
            accountId: "test-account"
        )

        try firstStore.saveOAuthTokens(tokens)

        let retrieved = try #require(try firstStore.retrieveOAuthTokens())
        #expect(retrieved.accessToken == tokens.accessToken)
        #expect(retrieved.refreshToken == tokens.refreshToken)
        #expect(retrieved.accountId == tokens.accountId)
        #expect(try secondStore.retrieveOAuthTokens() == nil)

        try firstStore.deleteOAuthTokens()
        #expect(try firstStore.retrieveOAuthTokens() == nil)
    }

    @Test func normalApplicationLaunchUsesThePersistentKeychainStore() {
        let store = OAuthTokenStoreFactory.applicationDefault(environment: [:])

        #expect(store is OAuthKeychainManager)
    }
}
