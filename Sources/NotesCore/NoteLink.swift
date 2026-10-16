import Foundation

/// An `applenotes:note/<UUID>` link to a note, as Notes writes it for `>>` links and Copy Link.
public enum NoteLink {
    public static let linkAttachmentUTI = "com.apple.notes.inlinetextattachment.link"

    /// The uppercase note UUID, or nil when `string` is not a note link.
    public static func uuid(from string: String) -> String? {
        guard let components = URLComponents(string: string), components.scheme?.lowercased() == "applenotes",
              components.path.hasPrefix("note/"),
              let uuid = UUID(uuidString: String(components.path.dropFirst(5)))
        else { return nil }
        return uuid.uuidString
    }

    public static func url(for uuid: String) -> URL? {
        URL(string: "applenotes:note/\(uuid)")
    }
}

public enum NoteLinkRef: Equatable, Sendable {
    case url(String)
    case attachment(String)
}

extension NoteDocument {
    public var linkRefs: [NoteLinkRef] {
        runs.compactMap { run in
            if let link = run.link { return .url(link) }
            if let attachment = run.attachment, attachment.typeUTI == NoteLink.linkAttachmentUTI,
               let id = attachment.identifier { return .attachment(id) }
            return nil
        }
    }
}

/// The database key at the end of a Core Data ID such as `x-coredata://<store>/ICNote/p123`.
public enum CurrentNote {
    public static func key(coreDataID: String) -> Int? {
        let prefix = "x-coredata://"
        guard coreDataID.hasPrefix(prefix) else { return nil }
        let parts = coreDataID.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[1] == "ICNote", parts[2].hasPrefix("p") else { return nil }
        return Int(parts[2].dropFirst())
    }
}
