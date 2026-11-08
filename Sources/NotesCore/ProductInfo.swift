import Foundation

public struct ProductInfo: Equatable, Sendable {
    public let name: String
    public let bundleIdentifier: String
    public let version: String
    public let urlScheme: String?
    /// "owner/name" on GitHub, the place "Check for Updates" looks.
    public let repository: String?

    public init?(infoDictionary: [String: Any]) {
        guard let name = infoDictionary["CFBundleName"] as? String,
              let bundleIdentifier = infoDictionary["CFBundleIdentifier"] as? String
        else { return nil }
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = infoDictionary["CFBundleShortVersionString"] as? String ?? "0"
        let urlTypes = infoDictionary["CFBundleURLTypes"] as? [[String: Any]]
        self.urlScheme = (urlTypes?.first?["CFBundleURLSchemes"] as? [String])?.first
        self.repository = infoDictionary["ReleasesRepository"] as? String
    }

    public static var main: ProductInfo? {
        Bundle.main.infoDictionary.flatMap(ProductInfo.init(infoDictionary:))
    }
}
