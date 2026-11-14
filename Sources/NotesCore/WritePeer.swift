import Darwin
import Foundation
import Security

/// Decides whether the process at the other end of a write socket connection may use the write service.
public struct WritePeerCheck: Sendable {
    let allows: @Sendable (Int32) -> Bool

    public init(_ allows: @escaping @Sendable (Int32) -> Bool) {
        self.allows = allows
    }

    /// Lets in only a process running this app's own code: the peer must satisfy this process's designated requirement.
    /// A Developer ID or self-signed build's requirement names its identifier and certificate, so it survives rebuilds;
    /// an ad-hoc build's requirement is its cdhash, so only the very same binary passes. That is the `--mcp` process,
    /// which an MCP client starts from the same app bundle.
    public static let sameCode = WritePeerCheck { WritePeer.runsSameCode(descriptor: $0) }
}

enum WritePeer {
    /// What this process's code is checked against, or nil when it has no signature at all.
    nonisolated(unsafe) private static let ownRequirement: SecRequirement? = {
        var me: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess
        else { return nil }
        return requirement
    }()

    static func runsSameCode(descriptor: Int32) -> Bool {
        guard let peer = code(descriptor: descriptor) else { return false }
        if let ownRequirement {
            return SecCodeCheckValidity(peer, [], ownRequirement) == errSecSuccess
        }
        // Only an unsigned build gets here; arm64 builds are always at least linker-signed. Fall back to the same file on disk.
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, let own = path(of: me), let theirs = path(of: peer) else { return false }
        return own.resolvingSymlinksInPath() == theirs.resolvingSymlinksInPath()
    }

    /// The code of the process that owns the other end of a connected Unix socket, found by its audit token, not its pid,
    /// so a pid that is reused after the peer exits cannot be mistaken for it.
    static func code(descriptor: Int32) -> SecCode? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return nil }
        let attributes = [kSecGuestAttributeAudit: withUnsafeBytes(of: &token) { Data($0) }] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }

    private static func path(of code: SecCode) -> URL? {
        var staticCode: SecStaticCode?
        var url: CFURL?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyPath(staticCode, [], &url) == errSecSuccess
        else { return nil }
        return url as URL?
    }
}
