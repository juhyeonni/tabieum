import Foundation
import SQLite3

public struct SearchResult: Equatable, Sendable {
    public let id: String
    public let title: String
    public let folder: String
    public let modified: Date
    public let snippet: String
    public let ownerIdentifier: String?
}

public struct Backlink: Equatable, Sendable {
    public let id: String
    public let title: String
    public let folder: String
    public let modified: Date
}

struct IndexedNote {
    let id: String
    let title: String
    let folder: String
    let modified: Date
    let body: String
    let owner: String
    var links: [String] = []
}

/// A full-text index of readable notes in one SQLite file. It is a cache: everything in it can be rebuilt from Notes.
public final class SearchIndex: @unchecked Sendable {
    static let schemaVersion = 5

    public static func defaultURL(bundleIdentifier: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(bundleIdentifier)/index.sqlite")
    }

    let db: SQLiteConnection

    public init(url: URL, readOnly: Bool = false) throws {
        if readOnly {
            let connection = try SQLiteConnection(url: url, readOnly: true)
            guard try Self.version(connection) == Self.schemaVersion else {
                throw SQLiteError(message: "index schema version mismatch", code: 0)
            }
            db = connection
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection = try SQLiteConnection(url: url, readOnly: false)
        if try Self.version(connection) != Self.schemaVersion {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
            connection = try SQLiteConnection(url: url, readOnly: false)
        }
        try connection.run("PRAGMA journal_mode = WAL")
        try connection.run("CREATE TABLE IF NOT EXISTS notes(id TEXT NOT NULL UNIQUE, modified REAL NOT NULL)")
        try connection.run("""
            CREATE TABLE IF NOT EXISTS links(
                source TEXT NOT NULL, target TEXT NOT NULL, PRIMARY KEY(source, target)) WITHOUT ROWID
            """)
        try connection.run("CREATE INDEX IF NOT EXISTS links_target ON links(target)")
        try connection.run("""
            CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
                title, body, folder UNINDEXED, owner UNINDEXED, tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3')
            """)
        try connection.run("""
            CREATE TABLE IF NOT EXISTS chunks(
                id INTEGER PRIMARY KEY, note_id TEXT NOT NULL, position INTEGER NOT NULL, path TEXT NOT NULL,
                text TEXT NOT NULL, modified REAL NOT NULL, model TEXT NOT NULL, vec BLOB NOT NULL)
            """)
        try connection.run("CREATE INDEX IF NOT EXISTS chunks_note ON chunks(note_id)")
        try connection.run("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID")
        try connection.run("PRAGMA user_version = \(Self.schemaVersion)")
        db = connection
    }

    /// The notes with every term first, then those with only some of them, the better match first within each group.
    /// Every term is a quoted prefix match, so user input never reaches FTS5 syntax.
    public func search(_ query: String, limit: Int = 20) throws -> [SearchResult] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        let all = try match(terms.map { "(" + Self.spellings($0).joined(separator: " OR ") + ")" }.joined(separator: " AND "), limit)
        let useful = terms.filter { $0.count >= 2 }
        guard terms.count > 1, !useful.isEmpty, all.count < limit else { return all }
        let some = try match(useful.flatMap(Self.spellings).joined(separator: " OR "), limit)
        let seen = Set(all.map(\.id))
        return Array((all + some.filter { !seen.contains($0.id) }).prefix(limit))
    }

    /// The term as a prefix match, and for a Korean word its shorter stems: a word is often written with an ending
    /// the note does not have (조깅했던 for 조깅), and a prefix match already finds the longer forms.
    static func spellings(_ term: String) -> [String] {
        func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
        guard let last = term.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value) else { return [quoted(term)] }
        let stems = [1, 2].filter { term.count - $0 >= 2 }.map { String(term.dropLast($0)) }
        return ([term] + stems).map(quoted)
    }

    private func match(_ expression: String, _ limit: Int) throws -> [SearchResult] {
        try db.rows("""
            SELECT n.id, notes_fts.title, notes_fts.folder, n.modified, snippet(notes_fts, 1, '', '', '…', 16), notes_fts.owner
            FROM notes_fts JOIN notes n ON n.rowid = notes_fts.rowid
            WHERE notes_fts MATCH ?1
            ORDER BY bm25(notes_fts, 10.0, 1.0, 0.0, 0.0)
            LIMIT ?2
            """, [.text(expression), .int(Int64(limit))]) {
            SearchResult(id: SQLiteConnection.text($0, 0), title: SQLiteConnection.text($0, 1),
                         folder: SQLiteConnection.text($0, 2),
                         modified: Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0, 3)),
                         snippet: SQLiteConnection.text($0, 4),
                         ownerIdentifier: Optional(SQLiteConnection.text($0, 5)).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// The notes that link to `uuid`, each once, newest first.
    public func backlinks(to uuid: String) throws -> [Backlink] {
        try db.rows("""
            SELECT n.id, f.title, f.folder, n.modified
            FROM links l JOIN notes n ON n.id = l.source JOIN notes_fts f ON f.rowid = n.rowid
            WHERE l.target = ?1 AND l.source <> ?1
            ORDER BY n.modified DESC
            """, [.text(uuid.uppercased())]) {
            Backlink(id: SQLiteConnection.text($0, 0), title: SQLiteConnection.text($0, 1),
                     folder: SQLiteConnection.text($0, 2),
                     modified: Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0, 3)))
        }
    }

    func modifiedDates() throws -> [String: Double] {
        let pairs = try db.rows("SELECT id, modified FROM notes") {
            (SQLiteConnection.text($0, 0), sqlite3_column_double($0, 1))
        }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    func upsert(_ notes: [IndexedNote]) throws {
        try db.transaction {
            for note in notes {
                try db.run("""
                    INSERT INTO notes(id, modified) VALUES (?1, ?2)
                    ON CONFLICT(id) DO UPDATE SET modified = excluded.modified
                    """, [.text(note.id), .real(note.modified.timeIntervalSinceReferenceDate)])
                try db.run("DELETE FROM notes_fts WHERE rowid = (SELECT rowid FROM notes WHERE id = ?1)", [.text(note.id)])
                try db.run("""
                    INSERT INTO notes_fts(rowid, title, body, folder, owner)
                    VALUES ((SELECT rowid FROM notes WHERE id = ?1), ?2, ?3, ?4, ?5)
                    """, [.text(note.id), .text(note.title), .text(note.body), .text(note.folder), .text(note.owner)])
                try db.run("DELETE FROM links WHERE source = ?1", [.text(note.id)])
                for target in note.links {
                    try db.run("INSERT INTO links(source, target) VALUES (?1, ?2)", [.text(note.id), .text(target)])
                }
            }
        }
    }

    func remove(_ ids: [String]) throws {
        try db.transaction {
            for id in ids {
                try db.run("DELETE FROM notes_fts WHERE rowid = (SELECT rowid FROM notes WHERE id = ?1)", [.text(id)])
                try db.run("DELETE FROM chunks WHERE note_id = ?1", [.text(id)])
                try db.run("DELETE FROM links WHERE source = ?1", [.text(id)])
                try db.run("DELETE FROM notes WHERE id = ?1", [.text(id)])
            }
        }
    }

    func meta(_ key: String) throws -> String? {
        try db.rows("SELECT value FROM meta WHERE key = ?1", [.text(key)]) { SQLiteConnection.text($0, 0) }.first
    }

    func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2", [.text(key), .text(value)])
    }

    private static func version(_ db: SQLiteConnection) throws -> Int {
        try db.rows("PRAGMA user_version") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }
}
