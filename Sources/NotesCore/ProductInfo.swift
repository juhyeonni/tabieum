import Foundation

public struct ProductInfo: Equatable, Sendable {
    public let name: String
    public let bundleIdentifier: String
    public let urlScheme: String?

    public init?(infoDictionary: [String: Any]) {
        guard let name = infoDictionary["CFBundleName"] as? String,
              let bundleIdentifier = infoDictionary["CFBundleIdentifier"] as? String
        else { return nil }
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        let urlTypes = infoDictionary["CFBundleURLTypes"] as? [[String: Any]]
        self.urlScheme = (urlTypes?.first?["CFBundleURLSchemes"] as? [String])?.first
    }

    public static var main: ProductInfo? {
        Bundle.main.infoDictionary.flatMap(ProductInfo.init(infoDictionary:))
    }
}
