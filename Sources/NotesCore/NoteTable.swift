import Foundation

extension NoteBodyDecoder {
    static let tableUTI = "com.apple.notes.table"

    /// Rows of cells from a table attachment's gzip-compressed CRDT object graph. Cells without an entry are empty.
    /// Throws `malformed` when a reference points nowhere or a cell names a row or column the orderings do not list.
    static func decodeTable(_ data: Data) throws -> [[NoteDocument]] {
        let root = try Message(try gunzip(data))
        guard let object = try root.message(2), let content = try object.message(3) else { throw NoteBodyDecoderError.malformed }
        let objects = try content.allBytes(3).map { try Message($0) }
        let keys = content.allBytes(4).map { String(decoding: $0, as: UTF8.self) }
        let types = content.allBytes(5).map { String(decoding: $0, as: UTF8.self) }
        let uuids = content.allBytes(6)

        func target(_ id: Message?) throws -> Message {
            guard let index = id?.varint(6), index < UInt64(objects.count) else { throw NoteBodyDecoderError.malformed }
            return objects[Int(index)]
        }

        func customMap(_ object: Message) throws -> (type: String, entries: [String: Message])? {
            guard let map = try object.message(13) else { return nil }
            guard let type = map.varint(1).flatMap({ $0 < UInt64(types.count) ? types[Int($0)] : nil }) else {
                throw NoteBodyDecoderError.malformed
            }
            var entries: [String: Message] = [:]
            for bytes in map.allBytes(3) {
                let entry = try Message(bytes)
                guard let key = entry.varint(1).flatMap({ $0 < UInt64(keys.count) ? keys[Int($0)] : nil }),
                      let value = try entry.message(2) else { throw NoteBodyDecoderError.malformed }
                entries[key] = value
            }
            return (type, entries)
        }

        func uuidIndex(_ id: Message?) throws -> Int {
            guard let map = try customMap(try target(id)), map.type == "com.apple.CRDT.NSUUID",
                  let index = map.entries["UUIDIndex"]?.varint(2), index < UInt64(uuids.count) else {
                throw NoteBodyDecoderError.malformed
            }
            return Int(index)
        }

        var table: [String: Message]?
        for object in objects {
            if let map = try customMap(object), map.type == "com.apple.notes.ICTable" {
                table = map.entries
                break
            }
        }
        guard let table else { throw NoteBodyDecoderError.malformed }

        /// Maps every UUID index that stands for a row or column to its position, and counts the positions.
        func positions(_ name: String) throws -> (byUUID: [Int: Int], count: Int) {
            guard let ordering = try target(table[name]).message(16)?.message(1), let array = try ordering.message(1) else {
                throw NoteBodyDecoderError.malformed
            }
            let attachments = try array.allBytes(2).map { try Message($0) }.sorted { ($0.varint(1) ?? 0) < ($1.varint(1) ?? 0) }
            var ordered: [Int: Int] = [:]
            for (position, attachment) in attachments.enumerated() {
                guard let uuid = attachment.bytes(2), let index = uuids.firstIndex(of: uuid) else { throw NoteBodyDecoderError.malformed }
                ordered[index] = position
            }
            var result = ordered
            for bytes in try ordering.message(2)?.allBytes(1) ?? [] {
                let element = try Message(bytes)
                if let position = ordered[try uuidIndex(element.message(1))] {
                    result[try uuidIndex(element.message(2))] = position
                }
            }
            return (result, attachments.count)
        }

        let rows = try positions("crRows"), columns = try positions("crColumns")
        guard rows.count > 0, columns.count > 0, let cellColumns = try target(table["cellColumns"]).message(6) else {
            throw NoteBodyDecoderError.malformed
        }
        var grid = Array(
            repeating: Array(repeating: NoteDocument(text: "", runs: []), count: columns.count), count: rows.count)
        for columnBytes in cellColumns.allBytes(1) {
            let column = try Message(columnBytes)
            guard let c = columns.byUUID[try uuidIndex(column.message(1))],
                  let cells = try target(column.message(2)).message(6) else { throw NoteBodyDecoderError.malformed }
            for cellBytes in cells.allBytes(1) {
                let cell = try Message(cellBytes)
                guard let r = rows.byUUID[try uuidIndex(cell.message(1))],
                      let note = try target(cell.message(2)).message(10) else { throw NoteBodyDecoderError.malformed }
                grid[r][c] = try document(from: note)
            }
        }
        return grid
    }
}
