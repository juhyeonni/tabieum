import Foundation
import Security

public enum WriteAction: String, CaseIterable, Sendable {
    case create, edit, delete
}

/// Which notes an edit or a delete may touch.
public enum WriteScope: String, CaseIterable, Sendable {
    case targetFolder, anyNote, mcpCreated
}

public enum ConsentMode: String, CaseIterable, Sendable {
    case always, oncePerSession, eachTime, never
}

/// What the owner lets an AI agent write to Notes. Everything is off until the owner turns it on.
public struct WriteSettings: Equatable, Sendable {
    public var enabled = false
    public var allowedActions: Set<WriteAction> = [.create]
    public var scope = WriteScope.targetFolder
    public var targetAccount = ""
    public var targetFolder = ""
    public var consent = ConsentMode.eachTime
    public var marker = false

    public init() {}

    public init(defaults: UserDefaults) {
        enabled = defaults.bool(forKey: "write.enabled")
        if let stored = defaults.stringArray(forKey: "write.actions") {
            allowedActions = Set(stored.compactMap(WriteAction.init(rawValue:)))
        }
        scope = defaults.string(forKey: "write.scope").flatMap(WriteScope.init(rawValue:)) ?? scope
        targetAccount = defaults.string(forKey: "write.account") ?? ""
        targetFolder = defaults.string(forKey: "write.folder") ?? ""
        consent = defaults.string(forKey: "write.consent").flatMap(ConsentMode.init(rawValue:)) ?? consent
        marker = defaults.bool(forKey: "write.marker")
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: "write.enabled")
        defaults.set(allowedActions.map(\.rawValue).sorted(), forKey: "write.actions")
        defaults.set(scope.rawValue, forKey: "write.scope")
        defaults.set(targetAccount, forKey: "write.account")
        defaults.set(targetFolder, forKey: "write.folder")
        defaults.set(consent.rawValue, forKey: "write.consent")
        defaults.set(marker, forKey: "write.marker")
    }
}

extension WriteSettings {
    /// The fields that decide whether and how far an agent may write: the master switch, the actions, the reach and the
    /// consent mode. The app keeps a copy of them where `defaults write` cannot reach.
    public var grant: String {
        "enabled=\(enabled);actions=\(allowedActions.map(\.rawValue).sorted().joined(separator: ","));scope=\(scope.rawValue);consent=\(consent.rawValue)"
    }

    /// These settings, with the grant fields put back to their defaults unless they are the ones the app last saved.
    /// `approved` is that saved grant; nil means the app never saved one, which approves only the defaults.
    public func approved(by approved: String?) -> WriteSettings {
        guard grant != (approved ?? WriteSettings().grant) else { return self }
        var safe = self
        let defaults = WriteSettings()
        safe.enabled = defaults.enabled
        safe.allowedActions = defaults.allowedActions
        safe.scope = defaults.scope
        safe.consent = defaults.consent
        return safe
    }

    /// The settings the write service may act on: what is in `defaults`, as far as the grant in `grants` approves it.
    public static func approved(defaults: UserDefaults, grants: WriteGrantStore) -> WriteSettings {
        WriteSettings(defaults: defaults).approved(by: grants.load())
    }
}

/// Where the app keeps the grant it last saved from its own Settings window.
public protocol WriteGrantStore: Sendable {
    func load() -> String?
    func save(_ grant: String)
}

/// Keeps the grant in the login Keychain. Its item is created by this app, so another process that reads or changes it
/// makes macOS ask the owner, unlike a `defaults write`.
public struct KeychainWriteGrantStore: WriteGrantStore {
    private let service: String

    public init(bundleIdentifier: String) {
        service = bundleIdentifier
    }

    public func load() -> String? {
        var result: AnyObject?
        let status = SecItemCopyMatching(query.merging([
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { $1 } as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes and re-adds rather than updating, so the item always carries this app's own access list.
    public func save(_ grant: String) {
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query.merging([kSecValueData as String: Data(grant.utf8)]) { $1 } as CFDictionary, nil)
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "write-grant",
            kSecUseDataProtectionKeychain as String: false,
        ]
    }
}
