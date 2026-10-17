import Foundation

/// The Notes ids of the notes the app created for an agent, kept so "only notes created by agents" can be honored.
public struct CreatedNoteLog: @unchecked Sendable {
    private static let key = "write.created"
    private static let limit = 5000
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func record(_ handle: String) {
        let all = (defaults.stringArray(forKey: Self.key) ?? []) + [handle]
        defaults.set(Array(all.suffix(Self.limit)), forKey: Self.key)
    }

    public func contains(_ handle: String) -> Bool {
        defaults.stringArray(forKey: Self.key)?.contains(handle) ?? false
    }
}
