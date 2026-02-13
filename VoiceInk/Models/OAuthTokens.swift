//
//  OAuthTokens.swift
//  VoiceInk
//
//  Data structure for OAuth tokens
//

import Foundation

struct OAuthTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let accountId: String?
    
    var isExpired: Bool {
        Date() >= expiresAt
    }
    
    var isExpiringSoon: Bool {
        // Consider expired if less than 5 minutes remaining
        Date().addingTimeInterval(5 * 60) >= expiresAt
    }
    
    init(accessToken: String, refreshToken: String, expiresIn: TimeInterval, accountId: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = Date().addingTimeInterval(expiresIn)
        self.accountId = accountId
    }
    
    init(accessToken: String, refreshToken: String, expiresAt: Date, accountId: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountId = accountId
    }
}

// Token response from OAuth endpoints
struct CodexTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let expiresIn: TimeInterval?
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}

// JWT Claims structure for parsing ID token
struct CodexIdTokenClaims: Codable {
    let chatgptAccountId: String?
    let organizations: [Organization]?
    let email: String?
    let customClaims: CustomClaims?
    
    struct Organization: Codable {
        let id: String
    }
    
    struct CustomClaims: Codable {
        let chatgptAccountId: String?
        
        enum CodingKeys: String, CodingKey {
            case chatgptAccountId = "chatgpt_account_id"
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case chatgptAccountId = "chatgpt_account_id"
        case organizations
        case email
        case customClaims = "https://api.openai.com/auth"
    }
}
