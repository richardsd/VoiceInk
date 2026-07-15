import Foundation

protocol OAuthHTTPSessionProtocol {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: OAuthHTTPSessionProtocol {}

protocol CodexOAuthClientProtocol {
    func enhance(
        formattedText: String,
        instructions: String,
        model: String,
        accessToken: String,
        timeout: TimeInterval
    ) async throws -> String
}

enum CodexOAuthClientError: Error, Equatable {
    case unauthorized
    case rateLimited
    case serverError
    case httpError(Int)
    case invalidResponse
    case emptyResponse
}

struct CodexSSEParser {
    static func parse(_ data: Data) throws -> String {
        guard let payload = String(data: data, encoding: .utf8) else {
            throw CodexOAuthClientError.invalidResponse
        }

        var outputText = ""

        for line in payload.split(whereSeparator: { $0.isNewline }) {
            guard line.hasPrefix("data:") else { continue }

            let jsonString = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard jsonString != "[DONE]",
                  let jsonData = jsonString.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { continue }

            switch event["type"] as? String {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String {
                    outputText += delta
                }
            case "response.output_text.done":
                if let completeText = event["text"] as? String {
                    outputText = completeText
                }
            default:
                continue
            }
        }

        let result = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw CodexOAuthClientError.emptyResponse
        }
        return result
    }
}

final class CodexOAuthClient: CodexOAuthClientProtocol {
    private let session: any OAuthHTTPSessionProtocol
    private let endpoint: URL

    init(
        session: any OAuthHTTPSessionProtocol = URLSession.shared,
        endpoint: URL = URL(string: CodexConstants.responsesEndpoint)!
    ) {
        self.session = session
        self.endpoint = endpoint
    }

    func enhance(
        formattedText: String,
        instructions: String,
        model: String,
        accessToken: String,
        timeout: TimeInterval
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        let requestBody: [String: Any] = [
            "model": model,
            "input": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": formattedText]
                    ],
                ]
            ],
            "instructions": instructions,
            "stream": true,
            "store": false,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexOAuthClientError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw Self.error(forHTTPStatus: httpResponse.statusCode)
        }

        return try CodexSSEParser.parse(data)
    }

    static func error(forHTTPStatus statusCode: Int) -> CodexOAuthClientError {
        switch statusCode {
        case 401, 403:
            return .unauthorized
        case 429:
            return .rateLimited
        case 500...599:
            return .serverError
        default:
            return .httpError(statusCode)
        }
    }
}
