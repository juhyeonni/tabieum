import Foundation

public struct Release: Equatable, Sendable {
    public let version: String
    public let url: URL
}

/// Reads GitHub's "latest release" answer. Nothing here talks to the network.
public enum UpdateCheck {
    public static func endpoint(repository: String) -> URL? {
        guard repository.wholeMatch(of: /[\w.-]+\/[\w.-]+/) != nil else { return nil }
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    /// The release page must be on github.com over https, because the app opens it.
    public static func latest(from data: Data) -> Release? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              page.scheme == "https", page.host == "github.com"
        else { return nil }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url: page)
    }

    public static func isNewer(_ latest: String, than current: String) -> Bool {
        latest.compare(current, options: .numeric) == .orderedDescending
    }
}
