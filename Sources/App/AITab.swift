import NotesAI
import NotesCore
import SwiftUI

enum AISettings {
    static var service: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    static func savedConfig(_ defaults: UserDefaults = .standard) -> AIConfig? {
        let baseURL = defaults.string(forKey: "aiBaseURL") ?? ""
        guard let host = AIConfig(baseURL: baseURL, chatModel: "-")?.host else { return nil }
        return AIConfig(baseURL: baseURL, chatModel: defaults.string(forKey: "aiChatModel") ?? "",
                      embeddingModel: defaults.string(forKey: "aiEmbeddingModel") ?? "",
                      apiKey: APIKeychain.key(service: service, host: host))
    }

    static func makeProvider(_ config: AIConfig) -> any AIProvider {
        OpenAICompatibleProvider(config: config, consent: HostConsent())
    }
}

extension AIError {
    var reason: String {
        switch self {
        case .unreachable: "Can't reach the server."
        case .unauthorized: "Unauthorized: check the API key."
        case let .http(status, message): "HTTP \(status): \(message)"
        case let .stream(message): "The server ended the reply: \(message)"
        case .badResponse: "The server sent an unexpected response."
        case let .consentRequired(host): "Sending to \(host) needs your consent."
        }
    }
}

struct AITab: View {
    @ObservedObject var toggles: FeatureToggles
    @ObservedObject var feature: AIFeature
    @AppStorage("aiBaseURL") private var baseURL = ""
    @AppStorage("aiChatModel") private var chatModel = ""
    @AppStorage("aiEmbeddingModel") private var embeddingModel = ""
    @State private var apiKey = ""
    @State private var hosts: [String] = []
    @State private var result = ""
    @State private var testing = false
    @State private var consentHost: String?
    @State private var recording = false
    @State private var shortcutRejected = false
    private let consent = HostConsent()

    private var host: String? { AIConfig(baseURL: baseURL, chatModel: "-")?.host }

    var body: some View {
        Form {
            Toggle("Enable AI", isOn: $toggles.aiEnabled)
            Text("Uses an OpenAI-compatible server such as Ollama or LM Studio. While off, nothing is sent.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("Shortcut")
                Button(recording ? "Press keys…" : toggles.aiShortcut.label, action: record)
                if shortcutRejected { Text("Include ⌘ or ⌃.").font(.caption).foregroundStyle(.red) }
            }
            TextField("Base URL", text: $baseURL, prompt: Text("http://localhost:11434/v1"))
            if !baseURL.isEmpty && host == nil {
                Text("Use https, or http to localhost.").font(.caption).foregroundStyle(.red)
            }
            TextField("Chat model", text: $chatModel, prompt: Text("llama3.2"))
            TextField("Embedding model", text: $embeddingModel, prompt: Text("Optional"))
            SecureField("API key", text: $apiKey, prompt: Text("Optional"))
            HStack {
                Button("Test connection", action: test).disabled(testing || feature.provider == nil)
                Text(result).font(.callout).lineLimit(3)
            }
            if !hosts.isEmpty {
                Section("Hosts allowed to receive note text") {
                    ForEach(hosts, id: \.self) { allowed in
                        HStack {
                            Text(allowed)
                            Spacer()
                            Button("Revoke") { consent.revoke(allowed); hosts = consent.hosts }
                        }
                    }
                }
            }
        }
        .padding()
        .onAppear {
            hosts = consent.hosts
            apiKey = host.flatMap { APIKeychain.key(service: AISettings.service, host: $0) } ?? ""
        }
        .onChange(of: baseURL) {
            apiKey = host.flatMap { APIKeychain.key(service: AISettings.service, host: $0) } ?? ""
            apply()
        }
        .onChange(of: chatModel) { apply() }
        .onChange(of: embeddingModel) { apply() }
        .onChange(of: apiKey) {
            if let host { APIKeychain.setKey(apiKey, service: AISettings.service, host: host) }
            apply()
        }
        .alert("Send note text to \(consentHost ?? "")?", isPresented: Binding(
            get: { consentHost != nil }, set: { if !$0 { consentHost = nil } })) {
            Button("Allow") {
                if let consentHost { consent.grant(consentHost) }
                hosts = consent.hosts
                test()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Note text will be sent to \(consentHost ?? ""). You can revoke this here later.")
        }
    }

    private func record() {
        guard !recording else { return }
        recording = true
        shortcutRejected = false
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let monitor { NSEvent.removeMonitor(monitor) }
            recording = false
            guard event.keyCode != 53 else { return nil }
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).intersection(HotKey.relevant)
            let name = (event.charactersIgnoringModifiers ?? "").uppercased()
            let key = HotKey(keyCode: event.keyCode, modifiers: flags, key: name.isEmpty ? "Key \(event.keyCode)" : name)
            if key.isValid { toggles.aiShortcut = key } else { shortcutRejected = true }
            return nil
        }
    }

    private func apply() {
        feature.config = AIConfig(baseURL: baseURL, chatModel: chatModel,
                                  embeddingModel: embeddingModel, apiKey: apiKey)
    }

    private func test() {
        result = "Testing…"
        testing = true
        let started = feature.perform { provider in
            defer { testing = false }
            do {
                var reply = ""
                for try await piece in provider.chat([ChatMessage(role: .user, content: "Reply with one word.")]) {
                    reply += piece
                    result = "Reply: \(reply)"
                }
                try Task.checkCancellation()
                if !embeddingModel.isEmpty {
                    let vectors = try await provider.embed(["hello"])
                    result += " · embedding: \(vectors.first?.count ?? 0) dimensions"
                }
            } catch let error as AIError {
                if case let .consentRequired(host) = error { result = ""; consentHost = host } else { result = error.reason }
            } catch is CancellationError {
                result = "Cancelled."
            } catch {
                result = error.localizedDescription
            }
        }
        if started == nil {
            testing = false
            result = "Turn on AI and set a base URL and chat model."
        }
    }
}
