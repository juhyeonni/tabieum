import Foundation
import SQLite3

struct SQLiteError: Error, Equatable {
    let message: String
    let code: Int32
}

enum SQLiteValue {
    case text(String)
    case real(Double)
    case int(Int64)
    case blob(Data)
}

final class SQLiteConnection {
    private let db: OpaquePointer

    init(url: URL, readOnly: Bool) throws {
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard let handle else { throw SQLiteError(message: "out of memory", code: SQLITE_NOMEM) }
        if rc != SQLITE_OK {
            let error = SQLiteError(message: String(cString: sqlite3_errmsg(handle)), code: rc)
            sqlite3_close_v2(handle)
            throw error
        }
        sqlite3_busy_timeout(handle, 2000)
        db = handle
    }

    deinit {
        sqlite3_close_v2(db)
    }

    func run(_ sql: String, _ params: [SQLiteValue] = []) throws {
        _ = try rows(sql, params) { _ in () }
    }

    func rows<T>(_ sql: String, _ params: [SQLiteValue] = [], _ map: (OpaquePointer) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            switch param {
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, transient)
            case .real(let value): sqlite3_bind_double(statement, index, value)
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .blob(let value):
                _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            }
        }
        var result: [T] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return result }
            guard rc == SQLITE_ROW else { throw lastError() }
            result.append(map(statement))
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do {
            try body()
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    private func lastError() -> SQLiteError {
        SQLiteError(message: String(cString: sqlite3_errmsg(db)), code: sqlite3_errcode(db))
    }

    static func blob(_ statement: OpaquePointer, _ index: Int32) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: sqlite3_column_blob(statement, index), count: Int(sqlite3_column_bytes(statement, index)))
    }

    static func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }
}
