import Foundation
import SQLite3
import Testing
@testable import NotesCore

/// A WAL-mode NoteStore built from the schema fixture in a temporary directory, with made-up rows.
/// The writer connection stays open with auto-checkpoint off, so rows stay in the -wal file.
final class Library {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/NoteStore-macOS26.sql")
    static let accountEnt = 14, folderEnt = 15, noteEnt = 12

    let directory: URL
    let url: URL
    private var db: OpaquePointer?
    var creationColumn = "ZCREATIONDATE3"
    var accountColumn = "ZACCOUNT8"

    init(schema transform: (String) -> String = { $0 }) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("NoteStore.sqlite")
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw TestError(message: "cannot create \(url.path)") }
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA wal_autocheckpoint = 0")
        try exec(transform(String(contentsOf: Self.fixture, encoding: .utf8)))
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: directory)
    }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            throw TestError(message: error.map { String(cString: $0) } ?? "sqlite error")
        }
    }

    func insert(_ columns: [String: Any?], into table: String = "ZICCLOUDSYNCINGOBJECT") throws {
        let names = Array(columns.keys)
        let sql = "INSERT INTO \(table) (\(names.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw TestError(message: sql) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, name) in names.enumerated() {
            let position = Int32(index + 1)
            switch columns[name]! {
            case let value as Int: sqlite3_bind_int64(statement, position, Int64(value))
            case let value as Double: sqlite3_bind_double(statement, position, value)
            case let value as String: sqlite3_bind_text(statement, position, value, -1, transient)
            case let value as Data:
                _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(value.count), transient) }
            default: sqlite3_bind_null(statement, position)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw TestError(message: sql) }
    }

    func account(pk: Int, id: String, name: String) throws {
        try insert(["Z_PK": pk, "Z_ENT": Self.accountEnt, "ZIDENTIFIER": id, "ZNAME": name, "ZOWNER": pk])
    }

    func folder(pk: Int, id: String, title: String, account: Int, owner: Int? = nil, parent: Int? = nil,
                type: Int = 0, deleted: Int = 0) throws {
        try insert(["Z_PK": pk, "Z_ENT": Self.folderEnt, "ZIDENTIFIER": id, "ZTITLE2": title,
                    accountColumn: account, "ZOWNER": owner ?? account, "ZPARENT": parent,
                    "ZFOLDERTYPE": type, "ZMARKEDFORDELETION": deleted])
    }

    func note(pk: Int, id: String, title: String, folder: Int, created: Double, modified: Double,
              snippet: String?, body: Data, locked: Int = 0, deleted: Int = 0) throws {
        try insert(["Z_PK": pk, "Z_ENT": 19, "ZNOTE": pk, "ZDATA": body], into: "ZICNOTEDATA")
        try insert(["Z_PK": pk, "Z_ENT": Self.noteEnt, "ZIDENTIFIER": id, "ZTITLE1": title, "ZFOLDER": folder,
                    creationColumn: created, "ZMODIFICATIONDATE1": modified, "ZSNIPPET": snippet,
                    "ZNOTEDATA": pk, "ZISPASSWORDPROTECTED": locked, "ZMARKEDFORDELETION": deleted])
    }

    /// Two accounts, a nested folder, a trash folder, a smart folder, and notes that must and must not show.
    func populate() throws {
        try account(pk: 1, id: "A-1", name: "iCloud")
        try account(pk: 2, id: "A-2", name: "On My Mac")
        try folder(pk: 10, id: "F-10", title: "Notes", account: 1)
        try folder(pk: 11, id: "F-11", title: "Nested", account: 1, parent: 10)
        try folder(pk: 12, id: "F-12", title: "Recently Deleted", account: 1, type: 1)
        try folder(pk: 13, id: "F-13", title: "Smart", account: 1, type: 3)
        try folder(pk: 14, id: "F-14", title: "Local", account: 2)
        try note(pk: 100, id: "N-100", title: "First", folder: 10, created: 700_000_000, modified: 700_000_500,
                 snippet: "hello", body: Data([0x1f, 0x8b, 0x00, 0xff]))
        try note(pk: 101, id: "N-101", title: "Second", folder: 11, created: 1.5, modified: 2.25,
                 snippet: nil, body: Data([0x00, 0x01]))
        try note(pk: 102, id: "N-102", title: "Locked", folder: 10, created: 1, modified: 1,
                 snippet: "secret first line", body: Data([1]), locked: 1)
        try note(pk: 103, id: "N-103", title: "Marked", folder: 10, created: 1, modified: 1,
                 snippet: nil, body: Data([1]), deleted: 1)
        try note(pk: 104, id: "N-104", title: "Trashed", folder: 12, created: 1, modified: 1,
                 snippet: nil, body: Data([1]))
    }
}

struct TestError: Error {
    let message: String
}

@Test func listsAccountsFoldersAndNotes() throws {
    let library = try Library()
    try library.populate()
    let reader = try NotesReader(databaseURL: library.url)

    #expect(try reader.accounts() == [Account(id: "A-1", name: "iCloud"), Account(id: "A-2", name: "On My Mac")])
    #expect(try reader.folders() == [
        Folder(id: "F-10", name: "Notes", accountID: "A-1", parentID: nil),
        Folder(id: "F-11", name: "Nested", accountID: "A-1", parentID: "F-10"),
        Folder(id: "F-14", name: "Local", accountID: "A-2", parentID: nil),
    ])
    #expect(try reader.notes() == [
        Note(id: "N-100", title: "First", folderID: "F-10",
             created: Date(timeIntervalSince1970: 978_307_200 + 700_000_000),
             modified: Date(timeIntervalSince1970: 978_307_200 + 700_000_500),
             snippet: "hello", body: Data([0x1f, 0x8b, 0x00, 0xff])),
        Note(id: "N-101", title: "Second", folderID: "F-11",
             created: Date(timeIntervalSinceReferenceDate: 1.5), modified: Date(timeIntervalSinceReferenceDate: 2.25),
             snippet: nil, body: Data([0x00, 0x01])),
    ])
}

@Test func readsNoteOnlyInWAL() throws {
    let library = try Library()
    try library.populate()
    try library.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    try library.note(pk: 105, id: "N-105", title: "Fresh", folder: 10, created: 3, modified: 4,
                     snippet: nil, body: Data([7]))
    let wal = try Data(contentsOf: URL(fileURLWithPath: library.url.path + "-wal"))
    #expect(!wal.isEmpty)

    let reader = try NotesReader(databaseURL: library.url)
    #expect(try reader.notes().map(\.id).contains("N-105"))
}

@Test func leavesDatabaseAndWALUntouched() throws {
    let library = try Library()
    try library.populate()
    let wal = URL(fileURLWithPath: library.url.path + "-wal")
    let before = try (Data(contentsOf: library.url), Data(contentsOf: wal))

    do {
        let reader = try NotesReader(databaseURL: library.url)
        _ = try (reader.accounts(), reader.folders(), reader.notes())
    }

    #expect(try Data(contentsOf: library.url) == before.0)
    #expect(try Data(contentsOf: wal) == before.1)
}

@Test func missingFileThrowsCannotOpen() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/NoteStore.sqlite")
    #expect {
        try NotesReader(databaseURL: url)
    } throws: { error in
        guard case .cannotOpen(let path, _) = error as? NotesReaderError else { return false }
        return path == url.path
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func unreadableFileThrowsPermissionDenied() throws {
    let library = try Library()
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: library.url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: library.url.path) }
    #expect(throws: NotesReaderError.permissionDenied(path: library.url.path)) {
        try NotesReader(databaseURL: library.url)
    }
}

@Test func missingColumnThrowsUnsupportedSchema() throws {
    let library = try Library { $0.replacingOccurrences(of: " ZISPASSWORDPROTECTED INTEGER,", with: "") }
    #expect(throws: NotesReaderError.unsupportedSchema(missingColumns: ["ZISPASSWORDPROTECTED"])) {
        try NotesReader(databaseURL: library.url)
    }
}

@Test func detectsRenumberedColumns() throws {
    let library = try Library {
        $0.replacingOccurrences(of: "ZCREATIONDATE3", with: "ZCREATIONDATE4")
            .replacingOccurrences(of: "ZACCOUNT8", with: "ZACCOUNT9")
    }
    library.creationColumn = "ZCREATIONDATE4"
    library.accountColumn = "ZACCOUNT9"
    try library.account(pk: 1, id: "A-1", name: "iCloud")
    try library.folder(pk: 10, id: "F-10", title: "Notes", account: 1)
    try library.folder(pk: 11, id: "F-11", title: "Nested", account: 1, owner: 10, parent: 10)
    try library.note(pk: 100, id: "N-100", title: "First", folder: 11, created: 42, modified: 43,
                     snippet: nil, body: Data([9]))
    let reader = try NotesReader(databaseURL: library.url)

    #expect(try reader.folders().map(\.accountID) == ["A-1", "A-1"])
    #expect(try reader.notes() == [
        Note(id: "N-100", title: "First", folderID: "F-11",
             created: Date(timeIntervalSinceReferenceDate: 42), modified: Date(timeIntervalSinceReferenceDate: 43),
             snippet: nil, body: Data([9])),
    ])
}

@Test func readsLinkAttachmentTargetsAndNoteKeys() throws {
    let library = try Library()
    try library.populate()
    let target = "applenotes:note/00000000-0000-0000-0000-000000000002?ownerIdentifier=x"
    try library.insert(["Z_PK": 200, "Z_ENT": 5, "ZIDENTIFIER": "ATT-LINK", "ZNOTE": 100,
                        "ZTYPEUTI": NoteLink.linkAttachmentUTI, "ZTOKENCONTENTIDENTIFIER": target])
    try library.insert(["Z_PK": 201, "Z_ENT": 5, "ZIDENTIFIER": "ATT-IMG", "ZNOTE": 100,
                        "ZTYPEUTI": "public.jpeg", "ZTOKENCONTENTIDENTIFIER": "x"])
    let reader = try NotesReader(databaseURL: library.url)

    #expect(try reader.attachmentLinkTargets(ids: ["ATT-LINK", "ATT-IMG", "ATT-NONE"]) == ["ATT-LINK": target])
    #expect(try reader.attachmentLinkTargets(ids: []).isEmpty)
    #expect(try reader.noteIdentifier(key: 100) == "N-100")
    #expect(try reader.noteIdentifier(key: 10) == nil)
    #expect(try reader.noteIdentifier(key: 9999) == nil)
}
