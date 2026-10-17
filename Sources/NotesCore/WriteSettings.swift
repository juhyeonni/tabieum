import Foundation

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
