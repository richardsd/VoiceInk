//
//  CodexCallbackServer.swift
//  VoiceInk
//
//  HTTP server for handling OAuth callback from OpenAI
//

import Foundation
import Network
import os

private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CodexCallbackServer")

enum CallbackServerError: LocalizedError {
    case portInUse
    case timeout
    case cancelled
    case invalidState
    case authorizationDenied(String)
    case missingCode
    
    var errorDescription: String? {
        switch self {
        case .portInUse:
            return "Port \(CodexConstants.redirectPort) is already in use. Close other applications using this port."
        case .timeout:
            return "Authorization timed out. Please try again."
        case .cancelled:
            return "Authorization was cancelled"
        case .invalidState:
            return "Invalid OAuth state parameter"
        case .authorizationDenied(let message):
            return "Authorization denied: \(message)"
        case .missingCode:
            return "Authorization code not received"
        }
    }
}

@MainActor
class CodexCallbackServer: ObservableObject {
    @Published var isListening = false
    
    private var listener: NWListener?
    private var expectedState: String?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    
    func start(expectedState: String) async throws -> String {
        guard !isListening else {
            throw CallbackServerError.portInUse
        }
        
        self.expectedState = expectedState
        
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            
            do {
                try setupListener()
                startTimeout()
            } catch {
                self.continuation = nil
                continuation.resume(throwing: error)
            }
        }
    }
    
    func stop() {
        logger.debug("Stopping callback server")
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil
        isListening = false
        expectedState = nil
        
        if let continuation = continuation {
            self.continuation = nil
            continuation.resume(throwing: CallbackServerError.cancelled)
        }
    }
    
    private func setupListener() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        // Enable SO_REUSEADDR and SO_REUSEPORT for better development experience
        let options = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
        options?.enableKeepalive = false
        options?.connectionTimeout = 10
        
        guard let port = NWEndpoint.Port(rawValue: UInt16(CodexConstants.redirectPort)) else {
            throw CallbackServerError.portInUse
        }
        
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch let error as NSError {
            // Provide more detailed error message
            logger.error("Failed to create listener on port \(CodexConstants.redirectPort): \(error.localizedDescription)")
            if error.domain == NSPOSIXErrorDomain && error.code == Int(EADDRINUSE) {
                logger.error("Port \(CodexConstants.redirectPort) is already in use. Close other VoiceInk instances or apps using this port.")
            }
            throw CallbackServerError.portInUse
        }
        
        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleStateChange(state)
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }
        
        listener?.start(queue: .main)
        isListening = true
        logger.debug("Callback server started on port \(CodexConstants.redirectPort)")
    }
    
    private func handleStateChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.debug("Listener ready")
        case .failed(let error):
            logger.error("Listener failed: \(error.localizedDescription)")
            completeWithError(CallbackServerError.portInUse)
        case .cancelled:
            logger.debug("Listener cancelled")
        default:
            break
        }
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                logger.warning("Connection failed: \(error.localizedDescription)")
            }
        }
        
        connection.start(queue: .main)
        
        receiveRequest(from: connection)
    }
    
    private func receiveRequest(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }
                
                if let error = error {
                    logger.error("Receive error: \(error.localizedDescription)")
                    self.sendResponse(to: connection, statusCode: 500, body: "Internal error")
                    return
                }
                
                guard let data = data, let requestString = String(data: data, encoding: .utf8) else {
                    self.sendResponse(to: connection, statusCode: 400, body: "Invalid request")
                    return
                }
                
                self.handleHTTPRequest(requestString, connection: connection)
            }
        }
    }
    
    private func handleHTTPRequest(_ requestString: String, connection: NWConnection) {
        logger.debug("Received HTTP request")
        
        // Parse the request line
        guard let firstLine = requestString.split(separator: "\r\n").first,
              let urlPart = firstLine.split(separator: " ").dropFirst().first else {
            sendResponse(to: connection, statusCode: 400, body: "Invalid request format")
            return
        }
        
        // Parse query parameters
        let urlString = String(urlPart)
        guard let components = URLComponents(string: "http://localhost\(urlString)") else {
            sendResponse(to: connection, statusCode: 400, body: "Invalid URL")
            return
        }
        
        // Check if this is the callback path
        guard components.path == "/auth/callback" else {
            sendResponse(to: connection, statusCode: 404, body: "Not found")
            return
        }
        
        let queryItems = components.queryItems ?? []
        let params = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        
        // Check for error
        if let error = params["error"] {
            let errorDescription = params["error_description"] ?? error
            logger.error("OAuth error: \(errorDescription)")
            sendResponse(to: connection, statusCode: 400, body: "Authorization failed")
            completeWithError(CallbackServerError.authorizationDenied(errorDescription))
            return
        }
        
        // Validate state
        guard let receivedState = params["state"], !receivedState.isEmpty else {
            logger.error("Missing state parameter")
            sendResponse(to: connection, statusCode: 400, body: "Missing state parameter")
            completeWithError(CallbackServerError.invalidState)
            return
        }
        
        guard receivedState == self.expectedState else {
            let expected = self.expectedState ?? "nil"
            logger.error("State mismatch: expected \(expected), got \(receivedState)")
            sendResponse(to: connection, statusCode: 400, body: "Invalid state parameter")
            completeWithError(CallbackServerError.invalidState)
            return
        }
        
        // Get authorization code
        guard let code = params["code"], !code.isEmpty else {
            logger.error("Missing authorization code")
            sendResponse(to: connection, statusCode: 400, body: "Missing authorization code")
            completeWithError(CallbackServerError.missingCode)
            return
        }
        
        logger.debug("Successfully received authorization code")
        sendSuccessResponse(to: connection)
        completeWithCode(code)
    }
    
    private func sendResponse(to connection: NWConnection, statusCode: Int, body: String) {
        let response = """
        HTTP/1.1 \(statusCode) \(httpStatusText(statusCode))
        Content-Type: text/plain
        Content-Length: \(body.utf8.count)
        Connection: close
        
        \(body)
        """
        
        guard let data = response.data(using: .utf8) else { return }
        
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func sendSuccessResponse(to connection: NWConnection) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Authorization Successful</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    height: 100vh;
                    margin: 0;
                    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                }
                .container {
                    background: white;
                    padding: 3rem;
                    border-radius: 1rem;
                    box-shadow: 0 10px 40px rgba(0,0,0,0.2);
                    text-align: center;
                }
                h1 { color: #333; margin-bottom: 1rem; }
                p { color: #666; }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>✓ Authorization Successful</h1>
                <p>You can close this window and return to VoiceInk.</p>
            </div>
            <script>setTimeout(() => window.close(), 2000)</script>
        </body>
        </html>
        """
        
        let response = """
        HTTP/1.1 200 OK
        Content-Type: text/html
        Content-Length: \(html.utf8.count)
        Connection: close
        
        \(html)
        """
        
        guard let data = response.data(using: .utf8) else { return }
        
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func httpStatusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
    
    private func startTimeout() {
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(CodexConstants.callbackTimeoutSeconds))
            
            if !Task.isCancelled {
                await MainActor.run {
                    logger.warning("Callback server timed out")
                    completeWithError(CallbackServerError.timeout)
                }
            }
        }
    }
    
    private func completeWithCode(_ code: String) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        
        timeoutTask?.cancel()
        timeoutTask = nil
        
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                stop()
            }
        }
        
        continuation.resume(returning: code)
    }
    
    private func completeWithError(_ error: Error) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        
        timeoutTask?.cancel()
        timeoutTask = nil
        
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                stop()
            }
        }
        
        continuation.resume(throwing: error)
    }
    
    deinit {
        listener?.cancel()
        timeoutTask?.cancel()
    }
}
