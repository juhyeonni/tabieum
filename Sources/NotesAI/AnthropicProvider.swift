import Foundation
import NotesCore

public struct AnthropicProvider: AIProvider {
    private let config: AIConfig
    private let consent: HostConsent
    private let session: URLSession

    public init(config: AIConfig, consent: HostConsent, session: URLSession = .shared) {
        self.config = config
        self.consent = consent
        self.session = session
    }

    public func chat(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n")
                    let body = Body(model: config.chatModel, system: system.isEmpty ? nil : system,
                                    messages: messages.filter { $0.role != .system })
                    let request = try makeRequest(body)
                    let (bytes, response) = try await session.bytes(for: request)
                    if let error = try await AIHTTP.httpError(response, body: { try await Data(collecting: bytes) }) { throw error }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let event = try? JSONDecoder().decode(Event.self, from: Data(payload.utf8)) else {
                            throw AIError.badResponse
                        }
                        if event.type == "message_stop" { break }
                        if event.type == "error" { throw AIError.stream(event.error?.message ?? "") }
                        if event.type == "content_block_delta", event.delta?.type == "text_delta",
                           let text = event.delta?.text, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIHTTP.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        throw AIError.embeddingsUnavailable
    }

    private func makeRequest(_ body: Body) throws -> URLRequest {
        var headers = [("anthropic-version", "2023-06-01")]
        if let key = config.apiKey { headers += [("x-api-key", key), ("Authorization", "Bearer \(key)")] }
        return try AIHTTP.request("messages", config: config, consent: consent, headers: headers,
                                  reserved: ["content-type", "authorization", "x-api-key", "anthropic-version"], body: body)
    }
}

private struct Body: Encodable {
    let model: String
    let system: String?
    let messages: [ChatMessage]
    let stream = true
    let maxTokens = 4096

    enum CodingKeys: String, CodingKey { case model, system, messages, stream, maxTokens = "max_tokens" }
}

private struct Event: Decodable {
    struct Delta: Decodable {
        let type: String?
        let text: String?
    }
    struct Failure: Decodable { let message: String? }
    let type: String
    let delta: Delta?
    let error: Failure?
}
