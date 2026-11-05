import Foundation

public enum TabieumAction: Equatable, Sendable {
    case search(String)
    case open(String)
    case append(String)
}

/// Reads a `tabieum://` URL into an action; anything unknown or incomplete is nil.
public enum TabieumURL {
    public static let maxTextLength = 2000

    public static func parse(_ url: URL) -> TabieumAction? {
        guard url.scheme?.lowercased() == "tabieum",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased()
        else { return nil }
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch host {
        case "search": return value("q").map { .search($0) }
        case "open": return value("id").flatMap { UUID(uuidString: $0) }.map { .open($0.uuidString) }
        case "append": return value("text").map { .append(String($0.prefix(maxTextLength))) }
        default: return nil
        }
    }
}
