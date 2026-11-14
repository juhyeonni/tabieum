import Foundation

public struct Release: Equatable, Sendable {
    public let version: String
    public let url: URL
    public let notes: String
    public let zip: URL?
    public let checksum: URL?
}

public enum InstallKind: Equatable, Sendable {
    public enum Reason: Equatable, Sendable { case notWritable, translocated }
    case homebrew
    case fixed(Reason)
    case replaceable
}

/// Reads GitHub's "latest release" answer. Nothing here talks to the network.
public enum UpdateCheck {
    public static func endpoint(repository: String) -> URL? {
        guard repository.wholeMatch(of: /[\w.-]+\/[\w.-]+/) != nil else { return nil }
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    /// The release page must be on github.com over https, because the app opens it.
    public static func latest(from data: Data, product: String? = nil, repository: String? = nil) -> Release? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              page.scheme == "https", page.host == "github.com"
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zipName = product.map { "\($0)-\(version).zip" }
        func asset(_ name: String?) -> URL? {
            guard let name, let repository else { return nil }
            return Self.asset(named: name, in: assets, repository: repository)
        }
        return Release(
            version: version, url: page, notes: json["body"] as? String ?? "",
            zip: asset(zipName),
            checksum: asset(zipName.map { $0 + ".sha256" })
        )
    }

    /// The app downloads from this address, so it must lie in the release downloads of its own repository.
    public static func isReleaseAsset(_ url: URL, repository: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.port == nil && url.user == nil
            && !url.pathComponents.contains("..")
            && url.path.hasPrefix("/\(repository)/releases/download/")
    }

    private static func asset(named name: String, in assets: [[String: Any]], repository: String) -> URL? {
        assets.lazy
            .filter { $0["name"] as? String == name }
            .compactMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
            .first { isReleaseAsset($0, repository: repository) }
    }

    /// Reads the first non-empty line of a `shasum -a 256` file.
    public static func parseChecksum(_ text: String) -> (digest: String, file: String)? {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { !$0.allSatisfy(\.isWhitespace) }),
              let match = line.wholeMatch(of: /([0-9a-fA-F]{64}) +\*?(\S.*)/)
        else { return nil }
        return (match.1.lowercased(), String(match.2))
    }

    public static func installKind(
        bundlePath: String,
        product: String,
        hasCaskroom: (String) -> Bool = { name in
            ["/opt/homebrew", "/usr/local"].contains {
                FileManager.default.fileExists(atPath: "\($0)/Caskroom/\(name)")
            }
        },
        isWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) }
    ) -> InstallKind {
        if hasCaskroom(product.lowercased()) { return .homebrew }
        if bundlePath.contains("/AppTranslocation/") { return .fixed(.translocated) }
        let folder = (bundlePath as NSString).deletingLastPathComponent
        return isWritable(folder) ? .replaceable : .fixed(.notWritable)
    }

    public static func isNewer(_ latest: String, than current: String) -> Bool {
        latest.compare(current, options: .numeric) == .orderedDescending
    }
}
