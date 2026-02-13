//
//  OAuthKeychainManager.swift
//  VoiceInk
//
//  Keychain manager for OAuth tokens with ACL to prevent password prompts
//

import Foundation
import Security
import os

class OAuthKeychainManager {
    static let shared = OAuthKeychainManager()
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "OAuthKeychainManager")
    
    private init() {}
    
    // MARK: - Access Control
    
    /// Creates an Access Control List (ACL) that trusts only this app.
    /// This prevents keychain password prompts by explicitly allowing our app to access items.
    private func createAccessControl() throws -> SecAccess {
        var access: SecAccess?
        
        // Create trusted application for this app (nil = current application)
        var trustedApp: SecTrustedApplication?
        let appStatus = SecTrustedApplicationCreateFromPath(nil, &trustedApp)
        guard appStatus == errSecSuccess, let trustedApp = trustedApp else {
            throw KeychainError.failedToCreateAccess(appStatus)
        }
        
        // Create access control with the trusted app
        let trustedAppList = [trustedApp] as CFArray
        let status = SecAccessCreate(
            "VoiceInk OAuth Tokens" as CFString,
            trustedAppList,
            &access
        )
        
        guard status == errSecSuccess, let access = access else {
            throw KeychainError.failedToCreateAccess(status)
        }
        
        return access
    }
    
    enum KeychainError: LocalizedError {
        case failedToSave(OSStatus)
        case failedToRead(OSStatus)
        case failedToDelete(OSStatus)
        case noDataFound
        case failedToCreateAccess(OSStatus)
        
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
            case .failedToCreateAccess(let status):
                return "Failed to create access control: \(status)"
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
        
        // Create access control that trusts this app (eliminates password prompts)
        let access = try createAccessControl()
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.prakashjoshipax.voiceink.oauth",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrAccess as String: access  // ACL that allows our app without prompts
        ]
        
        // Try to delete existing first
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
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
            kSecMatchLimit as String: kSecMatchLimitOne
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
