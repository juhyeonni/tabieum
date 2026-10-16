import Foundation
import Security

public struct HostConsent: @unchecked Sendable { // UserDefaults is thread-safe
    private let defaults: UserDefaults
    private let key = "aiConsentedHosts"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hosts: [String] { defaults.stringArray(forKey: key) ?? [] }

    public func isGranted(_ host: String) -> Bool { hosts.contains(host.lowercased()) }

    public func grant(_ host: String) {
        guard !isGranted(host) else { return }
        defaults.set(hosts + [host.lowercased()], forKey: key)
    }

    public func revoke(_ host: String) {
        defaults.set(hosts.filter { $0 != host.lowercased() }, forKey: key)
    }
}

public enum APIKeychain {
    public static func key(service: String, host: String) -> String? {
        var result: AnyObject?
        let status = SecItemCopyMatching(query(service, host).merging([
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { $1 } as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func setKey(_ key: String?, service: String, host: String) -> Bool {
        let base = query(service, host)
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return true }
        let item = base.merging([kSecValueData as String: Data(key.utf8)]) { $1 }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func query(_ service: String, _ host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }
}
