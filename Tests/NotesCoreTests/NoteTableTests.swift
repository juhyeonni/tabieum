import Foundation
import Testing
@testable import NotesCore

extension Encode {
    enum TableFault { case none, danglingCell, unknownRow }

    static func cell(_ text: String, _ runs: [[UInt8]] = []) -> [UInt8] {
        string(2, text) + runs.flatMap { $0 }
    }

    /// A table's mergeable data with made-up cells; `nil` cells have no entry, as in Notes.
    /// Row and column orderings use one UUID, and the cell map a second UUID that the ordering's contents dictionary links to it.
    static func table(_ cells: [[[UInt8]?]], fault: TableFault = .none) -> Data {
        let rowCount = cells.count, columnCount = cells[0].count
        let keys = ["identity", "crTableColumnDirection", "self", "crRows", "UUIDIndex", "crColumns", "cellColumns"]
        let types = [
            "com.apple.CRDT.NSNumber", "com.apple.CRDT.NSString", "com.apple.CRDT.NSUUID", "com.apple.CRDT.CRTuple",
            "com.apple.CRDT.CRRegisterMultiValueLeast", "com.apple.CRDT.CRRegisterMultiValue", "com.apple.CRDT.CRTree",
            "com.apple.CRDT.CRTreeNode", "com.apple.notes.CRTable", "com.apple.notes.ICTable",
        ]
        let uuidCount = 2 * (rowCount + columnCount) + 1
        let uuids = (0..<uuidCount).map { [UInt8](repeating: UInt8($0 + 1), count: 16) }
        let rowOrder = 0, rowRef = rowCount
        let columnOrder = 2 * rowCount, columnRef = 2 * rowCount + columnCount
        let stray = uuidCount - 1

        var objects: [[UInt8]] = [[]]
        func add(_ object: [UInt8]) -> Int {
            objects.append(object)
            return objects.count - 1
        }
        func map(_ type: Int, _ entries: [(key: Int, value: [UInt8])]) -> [UInt8] {
            bytes(13, int(1, type) + entries.flatMap { bytes(3, int(1, $0.key) + bytes(2, $0.value)) })
        }
        func uuidObject(_ index: Int) -> Int {
            add(map(2, [(4, int(2, index))]))
        }
        func dictionary(_ pairs: [(Int, Int)]) -> [UInt8] {
            pairs.flatMap { bytes(1, bytes(1, int(6, $0.0)) + bytes(2, int(6, $0.1))) }
        }
        func orderedSet(count: Int, order: Int, ref: Int) -> Int {
            let attachments = (0..<count).flatMap { bytes(2, int(1, $0) + bytes(2, uuids[order + $0])) }
            let pairs = (0..<count).map { (uuidObject(order + $0), uuidObject(ref + $0)) }
            let note = bytes(1, string(2, String(repeating: "\u{FFFC}", count: count)))
            let ordering = bytes(1, note + attachments) + bytes(2, dictionary(pairs))
            return add(bytes(16, bytes(1, ordering) + bytes(2, dictionary(pairs.map { ($0.0, $0.0) }))))
        }

        let rows = orderedSet(count: rowCount, order: rowOrder, ref: rowRef)
        let columns = orderedSet(count: columnCount, order: columnOrder, ref: columnRef)
        var columnPairs: [(Int, Int)] = []
        for column in 0..<columnCount {
            var cellPairs: [(Int, Int)] = []
            for row in 0..<rowCount {
                guard let cell = cells[row][column] else { continue }
                let rowUUID = fault == .unknownRow && row == 0 && column == 0 ? stray : rowRef + row
                let note = fault == .danglingCell && row == 0 && column == 0 ? 9999 : add(bytes(10, cell))
                cellPairs.append((uuidObject(rowUUID), note))
            }
            if cellPairs.isEmpty { continue }
            columnPairs.append((uuidObject(columnRef + column), add(bytes(6, dictionary(cellPairs)))))
        }
        let cellColumns = add(bytes(6, dictionary(columnPairs)))
        objects[0] = map(9, [
            (3, int(6, rows)), (5, int(6, columns)), (6, int(6, cellColumns)),
        ])

        let data = objects.flatMap { bytes(3, $0) } + keys.flatMap { string(4, $0) }
            + types.flatMap { string(5, $0) } + uuids.flatMap { bytes(6, $0) }
        return gzip(bytes(2, int(1, 0) + bytes(3, data)))
    }
}

private let tableAttachment = Encode.run(1, attachment: .some("com.apple.notes.table"))

private func render(_ table: Data) throws -> String {
    let runs = [Encode.run(7), tableAttachment, Encode.run(6)]
    let document = try NoteBodyDecoder.decode(Encode.gzipBody("before\n\u{FFFC}\nafter", runs))
    return document.markdown(tableData: { _ in table })
}

@Suite struct NoteTableTests {
    // AC5
    @Test func goldenTableRendersInTheGoldenNote() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        func fixture(_ name: String) throws -> Data {
            let hex = Array(try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
            return Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(String(hex[$0...$0 + 1]), radix: 16)! })
        }
        let table = try fixture("golden-table-macOS26.hex")
        let markdown = try NoteBodyDecoder.decode(try fixture("golden-macOS26.hex")).markdown(tableData: { _ in table })
        let expected = try String(contentsOf: fixtures.appendingPathComponent("golden-table-macOS26.md"), encoding: .utf8)
        #expect(markdown == expected)
    }

    // AC1
    @Test func rendersThreeByThreeInOrderingOrder() throws {
        let cells = (0..<3).map { row in (0..<3).map { Encode.cell("r\(row)c\($0)") as [UInt8]? } }
        #expect(try render(Encode.table(cells)) == """
            before
            | r0c0 | r0c1 | r0c2 |
            | --- | --- | --- |
            | r1c0 | r1c1 | r1c2 |
            | r2c0 | r2c1 | r2c2 |
            after
            """)
    }

    @Test func missingCellsAreEmpty() throws {
        let cells: [[[UInt8]?]] = [[Encode.cell("a"), nil], [nil, Encode.cell("d")]]
        #expect(try render(Encode.table(cells)) == "before\n| a |  |\n| --- | --- |\n|  | d |\nafter")
    }

    // AC2
    @Test func cellsKeepInlineStylesEscapePipesAndBreakLines() throws {
        let styled = Encode.cell("bold it link", [
            Encode.run(5, weight: 1), Encode.run(3, weight: 2), Encode.run(4, link: "https://e.com"),
        ])
        let cells: [[[UInt8]?]] = [[Encode.cell("a|b"), styled], [Encode.cell("x\ny"), Encode.cell("z")]]
        #expect(try render(Encode.table(cells)) == """
            before
            | a\\|b | **bold** *it* [link](https://e.com) |
            | --- | --- |
            | x<br>y | z |
            after
            """)
    }

    // AC3
    @Test func oneRowTableKeepsHeaderAndDelimiter() throws {
        let cells: [[[UInt8]?]] = [[Encode.cell("a"), Encode.cell("b")]]
        #expect(try render(Encode.table(cells)) == "before\n| a | b |\n| --- | --- |\nafter")
    }

    // AC4
    @Test func malformedTableLeavesPlaceholderAndSurroundingText() throws {
        let placeholder = "before\n[attachment: com.apple.notes.table]\nafter"
        let cells: [[[UInt8]?]] = [[Encode.cell("a")]]
        #expect(try render(Encode.table(cells, fault: .danglingCell)) == placeholder)
        #expect(try render(Encode.table(cells, fault: .unknownRow)) == placeholder)
        #expect(try render(Data([1, 2, 3])) == placeholder)
        #expect(try render(Encode.gzip([0x0a, 0x05, 1])) == placeholder)
        let document = try NoteBodyDecoder.decode(Encode.gzipBody("before\n\u{FFFC}\nafter", [Encode.run(7), tableAttachment, Encode.run(6)]))
        #expect(document.markdown() == placeholder)
    }

    @Test func everyTruncationDecodesOrThrows() {
        let full = Encode.table([[Encode.cell("a"), Encode.cell("b")], [Encode.cell("c"), nil]])
        for length in 0...full.count {
            _ = try? NoteBodyDecoder.decodeTable(full.prefix(length))
        }
    }
}

@Test func readsTableDataByAttachmentIdentifier() throws {
    let library = try Library()
    try library.populate()
    let table = Encode.table([[Encode.cell("a")]])
    try library.insert(["Z_PK": 200, "Z_ENT": 5, "ZIDENTIFIER": "T-1", "ZTYPEUTI": "com.apple.notes.table", "ZMERGEABLEDATA1": table])
    try library.insert(["Z_PK": 201, "Z_ENT": 5, "ZIDENTIFIER": "I-1", "ZTYPEUTI": "public.jpeg", "ZMERGEABLEDATA1": table])
    let reader = try NotesReader(databaseURL: library.url)

    #expect(try reader.tableData(attachmentID: "T-1") == table)
    #expect(try reader.tableData(attachmentID: "I-1") == nil)
    #expect(try reader.tableData(attachmentID: "missing") == nil)
    #expect(try reader.tableData(attachmentID: "x' OR '1'='1") == nil)
}
