import Foundation
import NotesAI
import NotesCore
import Testing

final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: ((StubProtocol) -> Void)?
    nonisolated(unsafe) private static var _requests: [(URLRequest, Data)] = []
    nonisolated(unsafe) private static var _stopped = false

    static func reset(_ handler: @escaping (StubProtocol) -> Void) {
        lock.withLock { _handler = handler; _requests = []; _stopped = false }
    }
    static var requests: [(URLRequest, Data)] { lock.withLock { _requests } }
    static var stopped: Bool { lock.withLock { _stopped } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let handler = Self.lock.withLock {
            Self._requests.append((request, body))
            return Self._handler
        }
        handler?(self)
    }

    override func stopLoading() { Self.lock.withLock { Self._stopped = true } }

    func respond(status: Int = 200, _ body: String, chunkSize: Int = .max, finish: Bool = true) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let bytes = Array(body.utf8)
        for start in stride(from: 0, to: bytes.count, by: min(chunkSize, max(bytes.count, 1))) {
            client?.urlProtocol(self, didLoad: Data(bytes[start..<min(start + chunkSize, bytes.count)]))
        }
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }

    func fail(_ code: URLError.Code) {
        client?.urlProtocol(self, didFailWithError: URLError(code))
    }
}

private func freshDefaults() -> UserDefaults {
    let name = "test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
}

private func provider(_ baseURL: String = "http://localhost:11434/v1", key: String? = nil,
                      consent: HostConsent = HostConsent(defaults: freshDefaults())) -> OpenAICompatibleProvider {
    let config = AIConfig(baseURL: baseURL, chatModel: "llama3", embeddingModel: "nomic-embed-text", apiKey: key)!
    return OpenAICompatibleProvider(config: config, consent: consent, session: stubSession())
}

private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var out: [String] = []
    for try await piece in stream { out.append(piece) }
    return out
}

private func chatError(_ provider: OpenAICompatibleProvider) async -> Error? {
    do { _ = try await collect(provider.chat([ChatMessage(role: .user, content: "hi")])); return nil } catch { return error }
}

private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
}

private let user = [ChatMessage(role: .user, content: "hi")]

@Suite(.serialized) struct OpenAICompatibleProviderTests {
    @Test(arguments: ["http://localhost:11434/v1", "http://localhost:11434/v1/"])
    func chatRequestShape(baseURL: String) async throws {
        for key in [nil, "sk-test"] as [String?] {
            StubProtocol.reset { $0.respond("data: [DONE]\n\n") }
            _ = try await collect(provider(baseURL, key: key).chat(user))
            let (request, body) = try #require(StubProtocol.requests.first)
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == key.map { "Bearer \($0)" })
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == "llama3")
            #expect(json["stream"] as? Bool == true)
            let messages = try #require(json["messages"] as? [[String: String]])
            #expect(messages == [["role": "user", "content": "hi"]])
        }
    }

    @Test(arguments: [Int.max, 1, 7])
    func streamYieldsDeltasInOrder(chunkSize: Int) async throws {
        let body = """
        : OPENROUTER PROCESSING

        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"content":"Hel"}}]}

        data: {"choices":[]}

        data:{"choices":[{"delta":{"content":"lo"}}]}

        data: [DONE]

        data: {"choices":[{"delta":{"content":"after"}}]}

        """
        StubProtocol.reset { $0.respond(body, chunkSize: chunkSize) }
        #expect(try await collect(provider().chat(user)) == ["Hel", "lo"])
    }

    @Test func streamErrorEventEndsStream() async {
        StubProtocol.reset {
            $0.respond("data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\ndata: {\"error\":{\"message\":\"overloaded\"}}\n\n")
        }
        #expect(await chatError(provider()) as? AIError == .stream("overloaded"))
    }

    @Test func httpErrors() async {
        StubProtocol.reset { $0.respond(status: 404, "{\"error\":{\"message\":\"model not found\"}}") }
        #expect(await chatError(provider()) as? AIError == .http(status: 404, message: "model not found"))
        StubProtocol.reset { $0.respond(status: 401, "{\"error\":{\"message\":\"bad key\"}}") }
        #expect(await chatError(provider()) as? AIError == .unauthorized)
        StubProtocol.reset { $0.fail(.cannotConnectToHost) }
        #expect(await chatError(provider()) as? AIError == .unreachable)
        StubProtocol.reset { $0.respond(status: 500, "{\"error\":{\"message\":\"boom\"}}") }
        await #expect(throws: AIError.http(status: 500, message: "boom")) { try await provider().embed(["a"]) }
    }

    @Test func cancellingConsumerCancelsRequest() async throws {
        StubProtocol.reset { $0.respond("data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\n", finish: false) }
        let stream = provider().chat(user)
        let consumer = Task { for try await _ in stream {} }
        #expect(await eventually { !StubProtocol.requests.isEmpty })
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        #expect(await eventually { StubProtocol.stopped })
    }

    @Test func embedOrdersByIndex() async throws {
        StubProtocol.reset {
            $0.respond("{\"data\":[{\"index\":1,\"embedding\":[2,2]},{\"index\":0,\"embedding\":[1,1]}]}")
        }
        let vectors = try await provider("http://localhost:11434/v1/").embed(["a", "b"])
        #expect(vectors == [[1, 1], [2, 2]])
        let (request, body) = try #require(StubProtocol.requests.first)
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/embeddings")
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "nomic-embed-text")
        #expect(json["input"] as? [String] == ["a", "b"])

        StubProtocol.reset { $0.respond("{\"data\":[{\"index\":0,\"embedding\":[1]}]}") }
        await #expect(throws: AIError.badResponse) { try await provider().embed(["a", "b"]) }
    }

    @Test func consentGatesNonLoopbackHosts() async throws {
        let consent = HostConsent(defaults: freshDefaults())
        StubProtocol.reset { $0.respond("data: [DONE]\n\n") }
        let remote = provider("https://api.openai.com/v1", consent: consent)
        #expect(await chatError(remote) as? AIError == .consentRequired(host: "api.openai.com"))
        await #expect(throws: AIError.consentRequired(host: "api.openai.com")) { try await remote.embed(["a"]) }
        #expect(StubProtocol.requests.isEmpty)

        consent.grant("api.openai.com")
        #expect(await chatError(remote) == nil)
        #expect(StubProtocol.requests.count == 1)

        let other = provider("https://openrouter.ai/api/v1", consent: consent)
        #expect(await chatError(other) as? AIError == .consentRequired(host: "openrouter.ai"))
        #expect(StubProtocol.requests.count == 1)

        consent.revoke("api.openai.com")
        #expect(await chatError(remote) as? AIError == .consentRequired(host: "api.openai.com"))

        for local in ["http://localhost:1234/v1", "http://127.0.0.1:11434/v1", "http://[::1]:11434/v1"] {
            #expect(await chatError(provider(local, consent: consent)) == nil)
        }
        #expect(StubProtocol.requests.count == 4)
    }
}
