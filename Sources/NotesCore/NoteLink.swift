import Foundation

/// A link to a note in Apple's own `applenotes:` scheme, so it works without this app.
public struct NoteLink: Equatable, Sendable {
    public let identifier: String
    public let ownerIdentifier: String?

    public init(identifier: String, ownerIdentifier: String? = nil) {
        self.identifier = identifier
        self.ownerIdentifier = ownerIdentifier
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "applenotes"
        components.path = "note/\(identifier)"
        if let ownerIdentifier { components.queryItems = [URLQueryItem(name: "ownerIdentifier", value: ownerIdentifier)] }
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme == "applenotes",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == nil,
              components.path.hasPrefix("note/")
        else { return nil }
        let id = String(components.path.dropFirst("note/".count))
        guard UUID(uuidString: id) != nil else { return nil }
        self.init(identifier: id, ownerIdentifier: components.queryItems?.first { $0.name == "ownerIdentifier" }?.value)
    }
}
