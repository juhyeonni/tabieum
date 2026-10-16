import Foundation

public enum CopyFailure: Error, Equatable, Sendable {
    case noCurrentNote
    case locked
    case notFound
    case automationDenied
}

public protocol NoteLookup {
    func note(key: Int) throws -> KeyedNote?
}

extension NotesReader: NoteLookup {}

/// Turns the ids Notes' `selection` returns into the one note's database key.
public enum CurrentNote {
    public static func key(fromSelection ids: [String]) throws -> Int {
        guard ids.count == 1, let range = ids[0].range(of: "/ICNote/p"), let key = Int(ids[0][range.upperBound...]) else {
            throw CopyFailure.noCurrentNote
        }
        return key
    }

    public struct Match: Equatable, Sendable {
        public let key: Int
        public let ambiguous: Bool
    }

    /// The one selected note, else the note whose title is the front window's; `keysForTitle` returns the newest first.
    public static func resolve(selection ids: [String], windowTitle: String?,
                               keysForTitle: (String) throws -> [Int]) throws -> Match {
        if ids.count == 1 { return Match(key: try key(fromSelection: ids), ambiguous: false) }
        guard ids.isEmpty, let windowTitle else { throw CopyFailure.noCurrentNote }
        let keys = try keysForTitle(windowTitle)
        guard let newest = keys.first else { throw CopyFailure.noCurrentNote }
        return Match(key: newest, ambiguous: keys.count > 1)
    }

    /// -1743 is "not authorized to send Apple events"; every other script error means no note could be read.
    public static func failure(scriptErrorNumber: Int) -> CopyFailure {
        scriptErrorNumber == -1743 ? .automationDenied : .noCurrentNote
    }
}

public enum CopyNote {
    public static func markdown(key: Int, from source: NoteLookup) throws -> String {
        try NoteBodyDecoder.decode(unlocked(key, source).note.body).markdown()
    }

    public static func link(key: Int, from source: NoteLookup) throws -> URL {
        let found = try unlocked(key, source)
        return NoteLink(identifier: found.note.id, ownerIdentifier: found.accountID).url
    }

    private static func unlocked(_ key: Int, _ source: NoteLookup) throws -> KeyedNote {
        guard let found = try source.note(key: key) else { throw CopyFailure.notFound }
        guard !found.locked else { throw CopyFailure.locked }
        return found
    }
}
