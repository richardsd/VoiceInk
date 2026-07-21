//
//  OAuthKeychainManager.swift
//  VoiceInk
//
//  Keychain manager for OAuth tokens with ACL to prevent password prompts
//

import Foundation
import Security
import os

protocol OAuthTokenStore {
    func saveOAuthTokens(_ tokens: OAuthTokens) throws
    func retrieveOAuthTokens() throws -> OAuthTokens?
    func deleteOAuthTokens() throws
}

/// Chooses the persistent application store without exposing a user's real
/// ChatGPT session to an app-hosted XCTest process.
enum OAuthTokenStoreFactory {
    static func applicationDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any OAuthTokenStore {
        guard environment["XCTestConfigurationFilePath"] == nil else {
            return EphemeralOAuthTokenStore()
        }
        return OAuthKeychainManager.shared
    }
}

private final class EphemeralOAuthTokenStore: OAuthTokenStore {
    private let lock = NSLock()
    private var tokens: OAuthTokens?

    func saveOAuthTokens(_ tokens: OAuthTokens) throws {
        lock.lock()
        self.tokens = tokens
        lock.unlock()
    }

    func retrieveOAuthTokens() throws -> OAuthTokens? {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    func deleteOAuthTokens() throws {
        lock.lock()
        tokens = nil
        lock.unlock()
    }
}

class OAuthKeychainManager: OAuthTokenStore {
    static let shared = OAuthKeychainManager()
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "OAuthKeychainManager")
    
    private init() {}
    
    enum KeychainError: LocalizedError {
        case failedToSave(OSStatus)
        case failedToRead(OSStatus)
        case failedToDelete(OSStatus)
        case noDataFound
        
        var errorDescription: String? {
            switch self {
            case .failedToSave(let status):
                return "Failed to save to Keychain: \(status)"
            case .failedToRead(let status):
                return "Failed to read from Keychain: \(status)"
            case .failedToDelete(let status):
                return "Failed to delete from Keychain: \(status)"
            case .noDataFound:
                return "No data found in Keychain"
            }
        }
    }
    
    // MARK: - Save
    
    func save(_ value: String, forKey key: String) throws {
        guard !value.isEmpty else {
            try delete(forKey: key)
            return
        }
        
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.failedToSave(-1)
        }
        
        let itemIdentity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.prakashjoshipax.voiceink.oauth",
        ]
        let itemToAdd: [String: Any] = itemIdentity.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]) { _, new in new }
        
        // Match only by the stable service/account identifiers so sessions written
        // with the legacy accessibility policy can be replaced in place.
        SecItemDelete(itemIdentity as CFDictionary)
        
        let status = SecItemAdd(itemToAdd as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("Failed to save keychain item for key: \(key), status: \(status)")
            throw KeychainError.failedToSave(status)
        }
        
        logger.info("Successfully saved keychain item for key: \(key)")
    }
    
    // MARK: - Read
    
    func retrieve(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.prakashjoshipax.voiceink.oauth",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Session discovery runs during application startup. Never let a
            // Keychain authorization prompt block launch (or an XCTest host)
            // before VoiceInk can present its own reconnect state.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound {
            return nil
        }
        
        guard status == errSecSuccess else {
            logger.error("Failed to retrieve keychain item for key: \(key), status: \(status)")
            throw KeychainError.failedToRead(status)
        }
        
        guard let data = result as? Data else {
            throw KeychainError.noDataFound
        }
        
        return String(data: data, encoding: .utf8)
    }
    
    // MARK: - Delete
    
    func delete(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.prakashjoshipax.voiceink.oauth"
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Failed to delete keychain item for key: \(key), status: \(status)")
            throw KeychainError.failedToDelete(status)
        }
        
        if status == errSecSuccess {
            logger.info("Successfully deleted keychain item for key: \(key)")
        }
    }
    
    // MARK: - OAuth Token Management
    
    func saveOAuthTokens(_ tokens: OAuthTokens) throws {
        try save(tokens.accessToken, forKey: "codex_access_token")
        try save(tokens.refreshToken, forKey: "codex_refresh_token")
        
        let expiresAtString = String(tokens.expiresAt.timeIntervalSince1970)
        try save(expiresAtString, forKey: "codex_expires_at")
        
        if let accountId = tokens.accountId {
            try save(accountId, forKey: "codex_account_id")
        }
    }
    
    func retrieveOAuthTokens() throws -> OAuthTokens? {
        guard let accessToken = try retrieve(forKey: "codex_access_token"),
              let refreshToken = try retrieve(forKey: "codex_refresh_token"),
              let expiresAtString = try retrieve(forKey: "codex_expires_at"),
              let expiresAtTimestamp = TimeInterval(expiresAtString) else {
            return nil
        }
        
        let expiresAt = Date(timeIntervalSince1970: expiresAtTimestamp)
        let accountId = try? retrieve(forKey: "codex_account_id")
        
        return OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            accountId: accountId
        )
    }
    
    func deleteOAuthTokens() throws {
        try? delete(forKey: "codex_access_token")
        try? delete(forKey: "codex_refresh_token")
        try? delete(forKey: "codex_expires_at")
        try? delete(forKey: "codex_account_id")
    }
}
