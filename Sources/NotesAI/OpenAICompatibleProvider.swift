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
        guard config.isLoopback || consent.isGranted(config.host) else {
            throw AIError.consentRequired(host: config.host)
        }
        var base = config.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var request = URLRequest(url: URL(string: base + "/" + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        for header in config.extraHeaders where !["content-type", "authorization"].contains(header.name.lowercased()) {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func httpError(_ response: URLResponse, body: () async throws -> Data) async throws -> AIError? {
        guard let http = response as? HTTPURLResponse else { return .badResponse }
        if (200..<300).contains(http.statusCode) { return nil }
        if http.statusCode == 401 || http.statusCode == 403 { return .unauthorized }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: await body()))?.error.message
        return .http(status: http.statusCode, message: message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
    }

    private static func map(_ error: Error) -> Error {
        if error is AIError || error is CancellationError { return error }
        if let error = error as? URLError {
            return error.code == .cancelled ? CancellationError() : AIError.unreachable
        }
        return AIError.badResponse
    }
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

private struct ErrorBody: Decodable {
    struct Detail: Decodable { let message: String? }
    let error: Detail
}

private struct EmbedResponse: Decodable {
    struct Item: Decodable {
        let index: Int
        let embedding: [Float]
    }
    let data: [Item]
}

private extension Data {
    init(collecting bytes: URLSession.AsyncBytes) async throws {
        self.init()
        for try await byte in bytes { append(byte) }
    }
}
