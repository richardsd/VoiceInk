//
//  CodexAuth.swift
//  VoiceInk
//
//  OAuth utilities for OpenAI Codex authentication
//

import Foundation
import CryptoKit
import os

private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CodexAuth")

enum CodexAuthError: LocalizedError {
    case invalidState
    case missingCode
    case authenticationInProgress
    case browserLaunchFailed
    case tokenExchangeFailed(String)
    case tokenRefreshFailed(String)
    case invalidToken
    
    var errorDescription: String? {
        switch self {
        case .invalidState:
            return "OAuth state validation failed"
        case .missingCode:
            return "Authorization code not received"
        case .authenticationInProgress:
            return "A ChatGPT sign-in is already in progress"
        case .browserLaunchFailed:
            return "Could not open the ChatGPT sign-in page"
        case .tokenExchangeFailed(let message):
            return "Token exchange failed: \(message)"
        case .tokenRefreshFailed(let message):
            return "Token refresh failed: \(message)"
        case .invalidToken:
            return "Invalid token format"
        }
    }
}

struct CodexPkceCodes {
    let verifier: String
    let challenge: String
}

class CodexAuth {
    
    // MARK: - PKCE Generation
    
    static func generatePkce() -> CodexPkceCodes {
        let verifier = generateRandomString(length: 43)
        let challenge = generateChallenge(from: verifier)
        return CodexPkceCodes(verifier: verifier, challenge: challenge)
    }
    
    private static func generateRandomString(length: Int) -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        var random = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in
            chars.randomElement(using: &random)!
        })
    }
    
    private static func generateChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else {
            fatalError("Failed to encode verifier")
        }
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncodedString()
    }
    
    // MARK: - State Generation
    
    static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
    
    // MARK: - Authorization URL
    
    static func buildAuthorizeUrl(pkce: CodexPkceCodes, state: String) -> URL {
        var components = URLComponents(string: "\(CodexConstants.issuer)/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: CodexConstants.clientId),
            URLQueryItem(name: "redirect_uri", value: CodexConstants.redirectUri),
            URLQueryItem(name: "scope", value: CodexConstants.scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: "voiceink-macos")
        ]
        return components.url!
    }
    
    // MARK: - Token Exchange
    
    static func exchangeCodeForTokens(
        code: String,
        pkceVerifier: String,
        session: any OAuthHTTPSessionProtocol = URLSession.shared
    ) async throws -> OAuthTokens {
        let url = URL(string: "\(CodexConstants.issuer)/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": CodexConstants.redirectUri,
            "client_id": CodexConstants.clientId,
            "code_verifier": pkceVerifier
        ]
        
        request.httpBody = body.formURLEncoded()
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CodexAuthError.tokenExchangeFailed("Invalid response")
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                logger.error("Token exchange failed with HTTP \(httpResponse.statusCode)")
                throw CodexAuthError.tokenExchangeFailed("HTTP \(httpResponse.statusCode)")
            }
            
            let tokenResponse = try JSONDecoder().decode(CodexTokenResponse.self, from: data)
            
            // Extract account ID from ID token if available
            let accountId = tokenResponse.idToken.flatMap { parseJwtClaims(token: $0) }
            
            return OAuthTokens(
                accessToken: tokenResponse.accessToken,
                refreshToken: tokenResponse.refreshToken,
                expiresIn: tokenResponse.expiresIn ?? 3600,
                accountId: accountId
            )
            
        } catch let error as CodexAuthError {
            throw error
        } catch {
            logger.error("Token exchange request failed")
            throw CodexAuthError.tokenExchangeFailed(
                "The authentication server returned an invalid response"
            )
        }
    }
    
    // MARK: - Token Refresh
    
    static func refreshAccessToken(
        refreshToken: String,
        session: any OAuthHTTPSessionProtocol = URLSession.shared
    ) async throws -> OAuthTokens {
        let url = URL(string: "\(CodexConstants.issuer)/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": CodexConstants.clientId
        ]
        
        request.httpBody = body.formURLEncoded()
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CodexAuthError.tokenRefreshFailed("Invalid response")
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                logger.error("Token refresh failed with HTTP \(httpResponse.statusCode)")
                throw CodexAuthError.tokenRefreshFailed("HTTP \(httpResponse.statusCode)")
            }
            
            let tokenResponse = try JSONDecoder().decode(CodexTokenResponse.self, from: data)
            
            // Extract account ID from ID token if available
            let accountId = tokenResponse.idToken.flatMap { parseJwtClaims(token: $0) }
            
            return OAuthTokens(
                accessToken: tokenResponse.accessToken,
                refreshToken: tokenResponse.refreshToken,
                expiresIn: tokenResponse.expiresIn ?? 3600,
                accountId: accountId
            )
            
        } catch let error as CodexAuthError {
            throw error
        } catch {
            logger.error("Token refresh request failed")
            throw CodexAuthError.tokenRefreshFailed(
                "The authentication server returned an invalid response"
            )
        }
    }
    
    // MARK: - JWT Parsing
    
    static func parseJwtClaims(token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else {
            logger.warning("Invalid JWT format")
            return nil
        }
        
        guard let payloadData = Data(base64URLEncoded: String(parts[1])) else {
            logger.warning("Failed to decode JWT payload")
            return nil
        }
        
        do {
            let claims = try JSONDecoder().decode(CodexIdTokenClaims.self, from: payloadData)
            return extractAccountId(from: claims)
        } catch {
            logger.warning("Failed to parse JWT claims: \(error.localizedDescription)")
            return nil
        }
    }
    
    private static func extractAccountId(from claims: CodexIdTokenClaims) -> String? {
        // Try multiple sources for account ID
        if let accountId = claims.chatgptAccountId {
            return accountId
        }
        if let accountId = claims.customClaims?.chatgptAccountId {
            return accountId
        }
        if let orgId = claims.organizations?.first?.id {
            return orgId
        }
        return claims.email
    }
}

// MARK: - Helper Extensions

extension Dictionary where Key == String, Value == String {
    func formURLEncoded() -> Data? {
        let pairs = map { key, value in
            let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._*"))
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        return pairs.joined(separator: "&").data(using: .utf8)
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        // Add padding if needed
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        
        self.init(base64Encoded: base64)
    }
}
