import Combine
import Foundation

public struct ChatMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public protocol AIProvider: Sendable {
    func chat(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public enum AIError: Error, Equatable {
    case unreachable
    case unauthorized
    case http(status: Int, message: String)
    case stream(String)
    case badResponse
    case consentRequired(host: String)
}

public struct ExtraHeader: Equatable, Sendable {
    public let name: String
    public let value: String

    public static func parse(_ text: String, session: String) -> (headers: [ExtraHeader], errors: [(line: Int, reason: String)]) {
        var headers: [ExtraHeader] = []
        var errors: [(line: Int, reason: String)] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let colon = trimmed.firstIndex(of: ":") else {
                errors.append((index + 1, "Missing a colon."))
                continue
            }
            let name = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                errors.append((index + 1, "Missing a header name."))
            } else if !name.unicodeScalars.allSatisfy(tokenCharacters.contains) {
                errors.append((index + 1, "Invalid header name."))
            } else {
                let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers.append(ExtraHeader(name: name, value: value.replacingOccurrences(of: "{session}", with: session)))
            }
        }
        return (headers, errors)
    }

    private static let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
        .union(CharacterSet(charactersIn: "a"..."z")).union(CharacterSet(charactersIn: "A"..."Z"))
        .union(CharacterSet(charactersIn: "0"..."9"))
}

public struct AIConfig: Equatable, Sendable {
    public let baseURL: URL
    public let host: String
    public let chatModel: String
    public let embeddingModel: String?
    public let apiKey: String?
    public let extraHeaders: [ExtraHeader]

    public init?(baseURL: String, chatModel: String, embeddingModel: String? = nil, apiKey: String? = nil,
                 extraHeaders: [ExtraHeader] = []) {
        let chatModel = chatModel.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)),
              let host = Self.allowedHost(url), !chatModel.isEmpty
        else { return nil }
        self.baseURL = url
        self.host = host
        self.chatModel = chatModel
        self.embeddingModel = embeddingModel.flatMap { $0.isEmpty ? nil : $0 }
        self.apiKey = apiKey.flatMap { $0.isEmpty ? nil : $0 }
        self.extraHeaders = extraHeaders
    }

    public var isLoopback: Bool { Self.isLoopback(host) }

    public static func isAllowedBaseURL(_ url: URL) -> Bool { allowedHost(url) != nil }

    static func allowedHost(_ url: URL) -> String? {
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        switch url.scheme?.lowercased() {
        case "https": return bare
        case "http": return isLoopback(bare) ? bare : nil
        default: return nil
        }
    }

    public static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil } && parts[0] == "127"
    }
}

@MainActor
public final class AIFeature: ObservableObject {
    @Published public private(set) var provider: (any AIProvider)?
    public var isEnabled: Bool { didSet { update() } }
    public var config: AIConfig? { didSet { update() } }

    private let factory: @MainActor (AIConfig) -> any AIProvider
    private var activeConfig: AIConfig?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var subscription: AnyCancellable?

    public init(toggles: FeatureToggles, factory: @escaping @MainActor (AIConfig) -> any AIProvider) {
        self.factory = factory
        isEnabled = toggles.aiEnabled
        subscription = toggles.$aiEnabled.dropFirst().sink { [weak self] on in
            MainActor.assumeIsolated { self?.isEnabled = on }
        }
    }

    @discardableResult
    public func perform(_ work: @escaping @MainActor (any AIProvider) async -> Void) -> Task<Void, Never>? {
        guard let provider else { return nil }
        let id = UUID()
        let task = Task { [weak self] in
            await work(provider)
            self?.tasks[id] = nil
        }
        tasks[id] = task
        return task
    }

    private func update() {
        let wanted = isEnabled ? config : nil
        guard wanted != activeConfig else { return }
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        provider = nil
        activeConfig = wanted
        provider = wanted.map(factory)
    }
}
