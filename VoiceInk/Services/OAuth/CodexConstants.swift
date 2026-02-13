//
//  CodexConstants.swift
//  VoiceInk
//
//  OpenAI Codex OAuth configuration constants
//

import Foundation

enum CodexConstants {
    // OAuth Client Configuration
    static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let issuer = "https://auth.openai.com"
    
    // Redirect Configuration
    static let redirectPort = 1455  // Required by OpenAI
    static let redirectUri = "http://localhost:\(redirectPort)/auth/callback"
    
    // OAuth Scopes
    static let scopes = "openid profile email offline_access"
    
    // API Configuration
    static let authClaimsUrl = "https://api.openai.com/auth"
    
    // Codex API Endpoint (for OAuth requests)
    static let responsesEndpoint = "https://chatgpt.com/backend-api/codex/responses"
    
    // Timeout Configuration
    static let callbackTimeoutSeconds: TimeInterval = 5 * 60  // 5 minutes
}
