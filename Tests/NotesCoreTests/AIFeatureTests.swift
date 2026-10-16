import Foundation
import Testing
@testable import NotesCore

private final class HangingProvider: AIProvider {
    func chat(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { _ in }
    }

    func embed(_ texts: [String]) async throws -> [[Float]] { [] }
}

@Test(arguments: [
    ("https://api.openai.com/v1", true),
    ("https://openrouter.ai/api/v1", true),
    ("http://localhost:11434/v1", true),
    ("http://LOCALHOST:1234/v1", true),
    ("http://127.0.0.1:1234/v1", true),
    ("http://127.4.5.6/v1", true),
    ("http://[::1]:11434/v1", true),
    ("http://192.168.1.10:11434/v1", false),
    ("http://api.openai.com/v1", false),
    ("http://127.0.0.1.example.com/v1", false),
    ("ftp://localhost/v1", false),
    ("not a url", false),
])
func baseURLValidation(url: String, allowed: Bool) {
    #expect((AIConfig(baseURL: url, chatModel: "m") != nil) == allowed)
}

@Test func loopbackHostsAreRecognised() {
    #expect(AIConfig(baseURL: "http://[::1]:11434/v1", chatModel: "m")?.host == "::1")
    #expect(AIConfig(baseURL: "http://[::1]:11434/v1", chatModel: "m")?.isLoopback == true)
    #expect(AIConfig(baseURL: "https://api.openai.com/v1", chatModel: "m")?.isLoopback == false)
    #expect(AIConfig(baseURL: "http://localhost/v1", chatModel: " ") == nil)
}

@MainActor
@Test func offMeansNoProvider() async {
    let name = "test.\(UUID().uuidString)"
    let toggles = FeatureToggles(defaults: UserDefaults(suiteName: name)!)
    var calls = 0
    weak var created: HangingProvider?
    let feature = AIFeature(toggles: toggles) { _ in
        calls += 1
        let provider = HangingProvider()
        created = provider
        return provider
    }
    feature.config = AIConfig(baseURL: "http://localhost:11434/v1", chatModel: "m")
    #expect(calls == 0 && feature.provider == nil)
    #expect(feature.perform { _ in } == nil)

    toggles.aiEnabled = true
    toggles.aiEnabled = true
    #expect(calls == 1 && feature.provider != nil)

    var cancelled = false
    let task = feature.perform { provider in
        do { for try await _ in provider.chat([]) {} } catch {}
        cancelled = Task.isCancelled
    }
    try? await Task.sleep(for: .milliseconds(20))

    toggles.aiEnabled = false
    await task?.value
    #expect(cancelled)
    #expect(feature.provider == nil && created == nil)
    #expect(calls == 1)
}

@Test func extraHeadersParse() {
    let text = "  X-A :  one  \n\n X-B: {session}-{session}\nno colon\n: v\nBad Name: v\nX-C:"
    let result = ExtraHeader.parse(text, session: "S")
    #expect(result.headers == [ExtraHeader(name: "X-A", value: "one"), ExtraHeader(name: "X-B", value: "S-S"),
                               ExtraHeader(name: "X-C", value: "")])
    #expect(result.errors.map(\.line) == [4, 5, 6])
}
