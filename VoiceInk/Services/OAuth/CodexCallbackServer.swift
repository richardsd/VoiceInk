//
//  CodexCallbackServer.swift
//  VoiceInk
//
//  HTTP server for handling OAuth callback from OpenAI
//

import Foundation
import Darwin
import os

private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CodexCallbackServer")

enum CallbackServerError: LocalizedError, Equatable {
    case portInUse
    case timeout
    case cancelled
    case invalidRequest
    case unsupportedMethod
    case invalidPath
    case invalidState
    case authorizationDenied
    case missingCode
    
    var errorDescription: String? {
        switch self {
        case .portInUse:
            return "Port \(CodexConstants.redirectPort) is already in use. Close other applications using this port."
        case .timeout:
            return "Authorization timed out. Please try again."
        case .cancelled:
            return "Authorization was cancelled"
        case .invalidRequest:
            return "Invalid OAuth callback request"
        case .unsupportedMethod:
            return "Unsupported OAuth callback method"
        case .invalidPath:
            return "Invalid OAuth callback path"
        case .invalidState:
            return "Invalid OAuth state parameter"
        case .authorizationDenied:
            return "Authorization was denied"
        case .missingCode:
            return "Authorization code not received"
        }
    }
}

struct CodexCallbackRequestParser {
    static func authorizationCode(from request: String, expectedState: String) throws -> String {
        guard let firstLine = request.split(separator: "\r\n").first else {
            throw CallbackServerError.invalidRequest
        }

        let requestParts = firstLine.split(separator: " ", maxSplits: 2)
        guard requestParts.count == 3 else {
            throw CallbackServerError.invalidRequest
        }
        guard requestParts[0] == "GET" else {
            throw CallbackServerError.unsupportedMethod
        }

        let requestTarget = String(requestParts[1])
        guard let components = URLComponents(string: "http://localhost\(requestTarget)") else {
            throw CallbackServerError.invalidRequest
        }
        guard components.path == "/auth/callback" else {
            throw CallbackServerError.invalidPath
        }

        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            parameters[item.name] = item.value ?? ""
        }

        guard let receivedState = parameters["state"],
              !receivedState.isEmpty,
              receivedState == expectedState else {
            throw CallbackServerError.invalidState
        }

        if parameters["error"] != nil {
            throw CallbackServerError.authorizationDenied
        }

        guard let code = parameters["code"], !code.isEmpty else {
            throw CallbackServerError.missingCode
        }
        return code
    }
}

@MainActor
class CodexCallbackServer: ObservableObject {
    @Published var isListening = false

    private static let maximumRequestSize = 65_536
    private let timeoutSeconds: TimeInterval
    private var listeningSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var clientBuffers: [Int32: Data] = [:]
    private var expectedState: String?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(timeoutSeconds: TimeInterval = CodexConstants.callbackTimeoutSeconds) {
        self.timeoutSeconds = timeoutSeconds
    }
    
    func start(
        expectedState: String,
        onListening: @MainActor () throws -> Void = {}
    ) async throws -> String {
        guard !isListening else {
            throw CallbackServerError.portInUse
        }
        
        self.expectedState = expectedState
        
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation

                do {
                    try setupListener()
                    try onListening()
                    startTimeout()
                } catch {
                    self.continuation = nil
                    cleanupListener()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
    }
    
    func stop() {
        logger.debug("Stopping callback server")
        let pendingContinuation = continuation
        continuation = nil
        cleanupListener()

        pendingContinuation?.resume(throwing: CallbackServerError.cancelled)
    }

    private func cleanupListener() {
        timeoutTask?.cancel()
        timeoutTask = nil

        acceptSource?.cancel()
        acceptSource = nil
        if listeningSocket >= 0 {
            Darwin.shutdown(listeningSocket, SHUT_RDWR)
            Darwin.close(listeningSocket)
            listeningSocket = -1
        }

        for socket in Array(clientSources.keys) {
            closeClient(socket)
        }

        isListening = false
        expectedState = nil
    }

    private func setupListener() throws {
        guard let port = UInt16(exactly: CodexConstants.redirectPort) else {
            throw CallbackServerError.portInUse
        }

        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            logger.error("Failed to create callback listener socket")
            throw CallbackServerError.portInUse
        }

        var reuseAddress: Int32 = 1
        guard Darwin.setsockopt(
            socket,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            Darwin.close(socket)
            throw CallbackServerError.portInUse
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port.bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    socket,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }

        guard bindResult == 0, Darwin.listen(socket, SOMAXCONN) == 0 else {
            let bindError = errno
            Darwin.close(socket)
            if bindError == EADDRINUSE {
                logger.warning("OAuth callback port is already in use")
            } else {
                logger.error("Failed to bind the OAuth callback listener to loopback")
            }
            throw CallbackServerError.portInUse
        }

        let currentFlags = Darwin.fcntl(socket, F_GETFL, 0)
        _ = Darwin.fcntl(socket, F_SETFL, currentFlags | O_NONBLOCK)

        listeningSocket = socket
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections()
        }
        acceptSource = source
        source.resume()

        isListening = true
        logger.debug("Callback server started on the IPv4 loopback interface")
    }

    private func acceptPendingConnections() {
        guard listeningSocket >= 0 else { return }

        while true {
            var peerAddress = sockaddr_in()
            var peerAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientSocket = withUnsafeMutablePointer(to: &peerAddress) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.accept(listeningSocket, socketAddress, &peerAddressLength)
                }
            }

            if clientSocket < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    logger.warning("Failed to accept an OAuth callback connection")
                }
                return
            }

            guard peerAddress.sin_family == sa_family_t(AF_INET),
                  peerAddress.sin_addr.s_addr == inet_addr("127.0.0.1") else {
                Darwin.close(clientSocket)
                logger.warning("Rejected a non-loopback OAuth callback connection")
                continue
            }

            var noSigPipe: Int32 = 1
            _ = Darwin.setsockopt(
                clientSocket,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            )

            let source = DispatchSource.makeReadSource(fileDescriptor: clientSocket, queue: .main)
            source.setEventHandler { [weak self] in
                self?.readRequest(from: clientSocket)
            }
            clientBuffers[clientSocket] = Data()
            clientSources[clientSocket] = source
            source.resume()
        }
    }

    private func readRequest(from socket: Int32) {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let byteCount = Darwin.recv(socket, &bytes, bytes.count, 0)

        guard byteCount > 0 else {
            closeClient(socket)
            return
        }

        clientBuffers[socket, default: Data()].append(contentsOf: bytes.prefix(byteCount))
        guard let requestData = clientBuffers[socket] else {
            closeClient(socket)
            return
        }

        guard requestData.count <= Self.maximumRequestSize else {
            sendResponse(to: socket, statusCode: 400, body: "Invalid request")
            return
        }

        let headerTerminator = Data([13, 10, 13, 10])
        guard requestData.range(of: headerTerminator) != nil else { return }

        guard let requestString = String(data: requestData, encoding: .utf8) else {
            sendResponse(to: socket, statusCode: 400, body: "Invalid request")
            return
        }

        handleHTTPRequest(requestString, socket: socket)
    }

    private func handleHTTPRequest(_ requestString: String, socket: Int32) {
        logger.debug("Received HTTP request")

        do {
            let code = try CodexCallbackRequestParser.authorizationCode(
                from: requestString,
                expectedState: expectedState ?? ""
            )
            logger.debug("Successfully received authorization code")
            sendSuccessResponse(to: socket)
            completeWithCode(code)
        } catch let error as CallbackServerError {
            switch error {
            case .unsupportedMethod:
                sendResponse(to: socket, statusCode: 405, body: "Method not allowed")
            case .invalidPath:
                sendResponse(to: socket, statusCode: 404, body: "Not found")
            case .invalidState:
                logger.warning("Rejected OAuth callback with invalid state")
                sendResponse(to: socket, statusCode: 400, body: "Invalid state parameter")
            case .authorizationDenied:
                logger.warning("OAuth authorization was denied")
                sendResponse(to: socket, statusCode: 400, body: "Authorization failed")
                completeWithError(error)
            case .missingCode:
                logger.warning("OAuth callback did not contain an authorization code")
                sendResponse(to: socket, statusCode: 400, body: "Missing authorization code")
                completeWithError(error)
            default:
                sendResponse(to: socket, statusCode: 400, body: "Invalid request")
            }
        } catch {
            sendResponse(to: socket, statusCode: 400, body: "Invalid request")
        }
    }

    private func sendResponse(to socket: Int32, statusCode: Int, body: String) {
        let response =
            "HTTP/1.1 \(statusCode) \(httpStatusText(statusCode))\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
            + body
        writeResponse(response, to: socket)
    }

    private func sendSuccessResponse(to socket: Int32) {
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

        let response =
            "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
            + html
        writeResponse(response, to: socket)
    }

    private func writeResponse(_ response: String, to socket: Int32) {
        guard let data = response.data(using: .utf8) else {
            closeClient(socket)
            return
        }

        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var totalSent = 0

            while totalSent < rawBuffer.count {
                let sent = Darwin.send(
                    socket,
                    baseAddress.advanced(by: totalSent),
                    rawBuffer.count - totalSent,
                    0
                )
                guard sent > 0 else { break }
                totalSent += sent
            }
        }

        closeClient(socket)
    }

    private func closeClient(_ socket: Int32) {
        clientSources.removeValue(forKey: socket)?.cancel()
        clientBuffers.removeValue(forKey: socket)
        Darwin.shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
    }
    
    private func httpStatusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
    
    private func startTimeout() {
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            
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
        cleanupListener()
        continuation.resume(returning: code)
    }
    
    private func completeWithError(_ error: Error) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        cleanupListener()
        continuation.resume(throwing: error)
    }
    
    deinit {
        acceptSource?.cancel()
        if listeningSocket >= 0 {
            Darwin.close(listeningSocket)
        }
        for socket in clientSources.keys {
            Darwin.close(socket)
        }
        timeoutTask?.cancel()
    }
}
