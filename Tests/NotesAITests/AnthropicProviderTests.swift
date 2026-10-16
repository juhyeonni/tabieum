import Foundation
import NotesAI
import NotesCore
import Testing

private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
}

private func provider(key: String? = "k", headers: [ExtraHeader] = []) -> AnthropicProvider {
    let config = AIConfig(baseURL: "http://localhost:8080/v1/", chatModel: "m", embeddingModel: "e", apiKey: key,
                          extraHeaders: headers, format: .anthropic)!
    let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    return AnthropicProvider(config: config, consent: HostConsent(defaults: defaults), session: stubSession())
}

private func collect(_ messages: [ChatMessage], with provider: AnthropicProvider = provider()) async throws -> [String] {
    var out: [String] = []
    for try await piece in provider.chat(messages) { out.append(piece) }
    return out
}

private func chatError(_ provider: AnthropicProvider = provider()) async -> Error? {
    do { _ = try await collect([ChatMessage(role: .user, content: "hi")], with: provider); return nil } catch { return error }
}

private func delta(_ text: String) -> String {
    "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\(text)\"}}\n\n"
}

private let stop = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"

extension OpenAICompatibleProviderTests {
    @Test func anthropicRequestShape() async throws {
        StubProtocol.reset { $0.respond(stop) }
        _ = try await collect([ChatMessage(role: .user, content: "hi")])
        let (request, body) = try #require(StubProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://localhost:8080/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "m")
        #expect(json["stream"] as? Bool == true)
        #expect(json["max_tokens"] as? Int == 4096)
    }

    @Test func systemMessagesGoToTopLevelField() async throws {
        StubProtocol.reset { $0.respond(stop) }
        _ = try await collect([
            ChatMessage(role: .system, content: "a"), ChatMessage(role: .user, content: "hi"),
            ChatMessage(role: .system, content: "b"),
        ])
        let (_, body) = try #require(StubProtocol.requests.first)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["system"] as? String == "a\nb")
        #expect(json["messages"] as? [[String: String]] == [["role": "user", "content": "hi"]])
    }

    @Test(arguments: [Int.max, 1, 7])
    func streamYieldsTextDeltasInOrder(chunkSize: Int) async throws {
        let body = """
        event: message_start
        data: {"type":"message_start","message":{"id":"x"}}

        event: ping
        data: {"type":"ping"}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        \(delta("Hel"))event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}

        \(delta("lo"))\(stop)\(delta("after"))
        """
        StubProtocol.reset { $0.respond(body, chunkSize: chunkSize) }
        #expect(try await collect([ChatMessage(role: .user, content: "hi")]) == ["Hel", "lo"])
    }

    @Test func anthropicStreamErrorEventEndsStream() async {
        StubProtocol.reset {
            $0.respond(delta("a") + "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"overloaded\"}}\n\n")
        }
        #expect(await chatError() as? AIError == .stream("overloaded"))
    }

    @Test func anthropicHttpErrors() async {
        StubProtocol.reset { $0.respond(status: 404, "{\"type\":\"error\",\"error\":{\"message\":\"model not found\"}}") }
        #expect(await chatError() as? AIError == .http(status: 404, message: "model not found"))
        for status in [401, 403] {
            StubProtocol.reset { $0.respond(status: status, "{\"error\":{\"message\":\"bad key\"}}") }
            #expect(await chatError() as? AIError == .unauthorized)
        }
    }

    @Test func anthropicExtraHeaders() async throws {
        let headers = ExtraHeader.parse("X-Team: a\nanthropic-version: evil\nX-API-Key: evil", session: "S").headers
        StubProtocol.reset { $0.respond(stop) }
        _ = try await collect([ChatMessage(role: .user, content: "hi")], with: provider(headers: headers))
        let (request, _) = try #require(StubProtocol.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Team") == "a")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "k")
    }

    @Test func embeddingsAreUnavailable() async {
        await #expect(throws: AIError.embeddingsUnavailable) { try await provider().embed(["a"]) }
    }
}
