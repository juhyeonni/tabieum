import Foundation
import NotesCore

public struct OpenAICompatibleProvider: AIProvider {
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
                    let request = try makeRequest("chat/completions", body: ChatBody(model: config.chatModel, messages: messages))
                    let (bytes, response) = try await session.bytes(for: request)
                    if let error = try await httpError(response, body: { try await Data(collecting: bytes) }) { throw error }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) else {
                            throw AIError.badResponse
                        }
                        if let error = chunk.error { throw AIError.stream(error.message ?? "") }
                        if let content = chunk.choices?.first?.delta?.content, !content.isEmpty {
                            continuation.yield(content)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        do {
            let model = config.embeddingModel ?? config.chatModel
            let request = try makeRequest("embeddings", body: EmbedBody(model: model, input: texts))
            let (data, response) = try await session.data(for: request)
            if let error = try await httpError(response, body: { data }) { throw error }
            guard let result = try? JSONDecoder().decode(EmbedResponse.self, from: data),
                  result.data.count == texts.count
            else { throw AIError.badResponse }
            return result.data.sorted { $0.index < $1.index }.map(\.embedding)
        } catch {
            throw Self.map(error)
        }
    }

    private func makeRequest(_ path: String, body: some Encodable) throws -> URLRequest {
        var headers: [(String, String)] = []
        if let key = config.apiKey { headers.append(("Authorization", "Bearer \(key)")) }
        return try AIHTTP.request(path, config: config, consent: consent, headers: headers,
                                  reserved: ["content-type", "authorization"], body: body)
    }

    private func httpError(_ response: URLResponse, body: () async throws -> Data) async throws -> AIError? {
        try await AIHTTP.httpError(response, body: body)
    }

    private static func map(_ error: Error) -> Error { AIHTTP.map(error) }
}

private struct ChatBody: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream = true
}

private struct EmbedBody: Encodable {
    let model: String
    let input: [String]
}

private struct Chunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?
    }
    struct Failure: Decodable { let message: String? }
    let choices: [Choice]?
    let error: Failure?
}

private struct EmbedResponse: Decodable {
    struct Item: Decodable {
        let index: Int
        let embedding: [Float]
    }
    let data: [Item]
}
