import Foundation
import SQLite3

public struct Account: Equatable, Sendable {
    public let id: String
    public let name: String
}

public struct Folder: Equatable, Sendable {
    public let id: String
    public let name: String
    public let accountID: String
    public let parentID: String?
}

public struct Note: Equatable, Sendable {
    public let id: String
    public let title: String
    public let folderID: String
    public let created: Date
    public let modified: Date
    public let snippet: String?
    public let body: Data
}

public enum NotesReaderError: Error, Equatable {
    case cannotOpen(path: String, message: String)
    case permissionDenied(path: String)
    case unsupportedSchema(missingColumns: [String])
}

/// Reads Apple Notes' NoteStore.sqlite through a read-only connection that never writes or checkpoints.
public final class NotesReader {
    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    }

    private static let objects = "ZICCLOUDSYNCINGOBJECT"
    private static let requiredColumns = [
        "Z_PK", "Z_ENT", "ZIDENTIFIER", "ZNAME", "ZPARENT", "ZFOLDER", "ZFOLDERTYPE", "ZNOTEDATA",
        "ZSNIPPET", "ZISPASSWORDPROTECTED", "ZMARKEDFORDELETION",
    ]
    private static let trashFolderType = 1
    private static let smartFolderType = 3

    private let db: OpaquePointer
    private let path: String
    private let accountEntity: Int
    private let folderEntity: Int
    private let noteEntity: Int
    private let titleColumns: [String]
    private let creationColumns: [String]
    private let modificationColumns: [String]
    private let accountLinkColumns: [String]
    private let mergeableColumns: [String]
    private let typeColumns: [String]

    public init(databaseURL: URL = NotesReader.defaultDatabaseURL) throws {
        let path = databaseURL.path
        self.path = path
        var handle: OpaquePointer?
        let uri = databaseURL.absoluteString + "?mode=ro"
        let rc = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard let handle else { throw NotesReaderError.cannotOpen(path: path, message: "out of memory") }
        db = handle
        do {
            if rc != SQLITE_OK { throw Self.openError(handle, path: path) }
            sqlite3_busy_timeout(handle, 1000)
            try Self.exec(handle, "PRAGMA query_only = ON", path: path)

            let columns = try Set(Self.strings(handle, "SELECT name FROM pragma_table_info('\(Self.objects)')", path: path))
            let dataColumns = try Set(Self.strings(handle, "SELECT name FROM pragma_table_info('ZICNOTEDATA')", path: path))
            func family(_ base: String) -> [String] {
                columns.filter { $0 == base || ($0.hasPrefix(base) && Int($0.dropFirst(base.count)) != nil) }.sorted()
            }
            titleColumns = family("ZTITLE")
            creationColumns = family("ZCREATIONDATE")
            modificationColumns = family("ZMODIFICATIONDATE")
            mergeableColumns = family("ZMERGEABLEDATA")
            typeColumns = family("ZTYPEUTI")
            accountLinkColumns = (columns.contains("ZOWNER") ? ["ZOWNER"] : [])
                + columns.filter { $0.hasPrefix("ZACCOUNT") && Int($0.dropFirst(8)) != nil }
                    .sorted { Int($0.dropFirst(8))! < Int($1.dropFirst(8))! }

            var missing = Self.requiredColumns.filter { !columns.contains($0) }
            if titleColumns.isEmpty { missing.append("ZTITLE") }
            if creationColumns.isEmpty { missing.append("ZCREATIONDATE") }
            if modificationColumns.isEmpty { missing.append("ZMODIFICATIONDATE") }
            if accountLinkColumns.isEmpty { missing.append("ZOWNER") }
            missing += ["Z_PK", "ZDATA"].filter { !dataColumns.contains($0) }.map { "ZICNOTEDATA.\($0)" }
            if !missing.isEmpty { throw NotesReaderError.unsupportedSchema(missingColumns: missing) }

            let entities = try Self.rows(handle, "SELECT Z_NAME, Z_ENT FROM Z_PRIMARYKEY", path: path) {
                (Self.text($0, 0) ?? "", Int(sqlite3_column_int64($0, 1)))
            }
            let entity = Dictionary(entities, uniquingKeysWith: { first, _ in first })
            guard let account = entity["ICAccount"], let folder = entity["ICFolder"], let note = entity["ICNote"] else {
                throw NotesReaderError.unsupportedSchema(
                    missingColumns: ["ICAccount", "ICFolder", "ICNote"].filter { entity[$0] == nil }.map { "Z_PRIMARYKEY.\($0)" })
            }
            accountEntity = account
            folderEntity = folder
            noteEntity = note
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
    }

    deinit {
        sqlite3_close_v2(db)
    }

    public func accounts() throws -> [Account] {
        try query("""
            SELECT ZIDENTIFIER, ZNAME FROM \(Self.objects)
            WHERE Z_ENT = \(accountEntity) AND coalesce(ZMARKEDFORDELETION, 0) = 0
            ORDER BY Z_PK
            """) { Account(id: Self.text($0, 0) ?? "", name: Self.text($0, 1) ?? "") }
    }

    public func folders() throws -> [Folder] {
        let title = try mostUsed(titleColumns, entity: folderEntity)
        let link = try accountLink()
        return try query("""
            SELECT f.ZIDENTIFIER, f.\(title), a.ZIDENTIFIER, p.ZIDENTIFIER
            FROM \(Self.objects) f
            JOIN \(Self.objects) a ON a.Z_PK = f.\(link) AND a.Z_ENT = \(accountEntity)
            LEFT JOIN \(Self.objects) p ON p.Z_PK = f.ZPARENT AND p.Z_ENT = \(folderEntity)
            WHERE f.Z_ENT = \(folderEntity) AND \(visibleFolder("f"))
              AND coalesce(a.ZMARKEDFORDELETION, 0) = 0
            ORDER BY f.Z_PK
            """) {
            Folder(id: Self.text($0, 0) ?? "", name: Self.text($0, 1) ?? "",
                   accountID: Self.text($0, 2) ?? "", parentID: Self.text($0, 3))
        }
    }

    public func notes() throws -> [Note] {
        let title = try mostUsed(titleColumns, entity: noteEntity)
        let created = try mostUsed(creationColumns, entity: noteEntity)
        let modified = try mostUsed(modificationColumns, entity: noteEntity)
        return try query("""
            SELECT n.ZIDENTIFIER, n.\(title), f.ZIDENTIFIER, n.\(created), n.\(modified), n.ZSNIPPET, d.ZDATA
            FROM \(Self.objects) n
            JOIN \(Self.objects) f ON f.Z_PK = n.ZFOLDER AND f.Z_ENT = \(folderEntity)
            LEFT JOIN ZICNOTEDATA d ON d.Z_PK = n.ZNOTEDATA
            WHERE n.Z_ENT = \(noteEntity) AND \(visibleFolder("f"))
              AND coalesce(n.ZISPASSWORDPROTECTED, 0) = 0 AND coalesce(n.ZMARKEDFORDELETION, 0) = 0
            ORDER BY n.Z_PK
            """) {
            Note(id: Self.text($0, 0) ?? "", title: Self.text($0, 1) ?? "", folderID: Self.text($0, 2) ?? "",
                 created: Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0, 3)),
                 modified: Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0, 4)),
                 snippet: Self.text($0, 5), body: Self.blob($0, 6))
        }
    }

    /// The gzip-compressed mergeable data of the table attachment with this identifier, or nil if there is none.
    public func tableData(attachmentID: String) throws -> Data? {
        guard !mergeableColumns.isEmpty, !typeColumns.isEmpty else { return nil }
        let id = attachmentID.replacingOccurrences(of: "'", with: "''")
        let data = try query("""
            SELECT coalesce(\((mergeableColumns + ["NULL"]).joined(separator: ", ")))
            FROM \(Self.objects)
            WHERE ZIDENTIFIER = '\(id)'
              AND coalesce(\((typeColumns + ["NULL"]).joined(separator: ", "))) = '\(NoteBodyDecoder.tableUTI)'
              AND coalesce(ZMARKEDFORDELETION, 0) = 0
            LIMIT 1
            """) { Self.blob($0, 0) }.first
        return data?.isEmpty == false ? data : nil
    }

    private func visibleFolder(_ alias: String) -> String {
        "coalesce(\(alias).ZMARKEDFORDELETION, 0) = 0"
            + " AND coalesce(\(alias).ZFOLDERTYPE, 0) NOT IN (\(Self.trashFolderType), \(Self.smartFolderType))"
    }

    /// The column of a numbered family (e.g. ZCREATIONDATE3) that holds the most values on this entity's rows.
    private func mostUsed(_ candidates: [String], entity: Int) throws -> String {
        let counts = try query("""
            SELECT \(candidates.map { "count(\($0))" }.joined(separator: ", "))
            FROM \(Self.objects) WHERE Z_ENT = \(entity)
            """) { row in candidates.indices.map { sqlite3_column_int64(row, Int32($0)) } }.first ?? []
        guard let best = counts.indices.max(by: { counts[$0] < counts[$1] }) else { return candidates[0] }
        return candidates[best]
    }

    /// The first candidate whose non-null values on folder rows all point at account rows.
    private func accountLink() throws -> String {
        let accounts = "SELECT Z_PK FROM \(Self.objects) WHERE Z_ENT = \(accountEntity)"
        for column in accountLinkColumns {
            let counts = try query("""
                SELECT count(\(column)), count(CASE WHEN \(column) IN (\(accounts)) THEN 1 END)
                FROM \(Self.objects) WHERE Z_ENT = \(folderEntity)
                """) { (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1)) }.first
            if let counts, counts.0 > 0, counts.0 == counts.1 { return column }
        }
        return accountLinkColumns[0]
    }

    private func query<T>(_ sql: String, _ map: (OpaquePointer) -> T) throws -> [T] {
        try Self.rows(db, sql, path: path, map)
    }

    private static func rows<T>(_ db: OpaquePointer, _ sql: String, path: String, _ map: (OpaquePointer) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw openError(db, path: path)
        }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return result }
            guard rc == SQLITE_ROW else { throw openError(db, path: path) }
            result.append(map(statement))
        }
    }

    private static func strings(_ db: OpaquePointer, _ sql: String, path: String) throws -> [String] {
        try rows(db, sql, path: path) { text($0, 0) ?? "" }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String, path: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw openError(db, path: path) }
    }

    private static func openError(_ db: OpaquePointer, path: String) -> NotesReaderError {
        let errno = sqlite3_system_errno(db)
        if errno == EPERM || errno == EACCES { return .permissionDenied(path: path) }
        return .cannotOpen(path: path, message: String(cString: sqlite3_errmsg(db)))
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    private static func blob(_ statement: OpaquePointer, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
}
