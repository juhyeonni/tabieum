import Foundation

public enum NoteBodyDecoderError: Error, Equatable {
    case notGzip
    case decompressionFailed
    case malformed
}

public enum ParagraphKind: Equatable, Sendable {
    case body, title, heading, subheading, monospaced, dotted, dashed, numbered, checklist
}

public struct ParagraphStyle: Equatable, Sendable {
    public var kind = ParagraphKind.body
    public var indent = 0
    public var checked = false
    public var blockQuote = false

    public init(kind: ParagraphKind = .body, indent: Int = 0, checked: Bool = false, blockQuote: Bool = false) {
        self.kind = kind
        self.indent = indent
        self.checked = checked
        self.blockQuote = blockQuote
    }
}

public struct NoteAttachment: Equatable, Sendable {
    public var identifier: String?
    public var typeUTI: String?

    public init(identifier: String? = nil, typeUTI: String? = nil) {
        self.identifier = identifier
        self.typeUTI = typeUTI
    }
}

/// A span of `length` UTF-16 code units of the note text and the styles that apply to it.
public struct NoteRun: Equatable, Sendable {
    public var length: Int
    public var paragraph = ParagraphStyle()
    public var bold = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public var link: String?
    public var attachment: NoteAttachment?

    public init(length: Int) {
        self.length = length
    }
}

public struct NoteDocument: Equatable, Sendable {
    public let text: String
    public let runs: [NoteRun]

    public var plainText: String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "")
    }
}

public enum NoteBodyDecoder {
    public static func decode(_ body: Data) throws -> NoteDocument {
        let root = try Message(try gunzip(body))
        guard let document = try root.message(2), let note = try document.message(3) else {
            throw NoteBodyDecoderError.malformed
        }
        return try Self.document(from: note)
    }

    static func document(from note: Message) throws -> NoteDocument {
        let text = note.bytes(2).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let runs = try note.allBytes(5).map { try run(from: Message($0)) }
        return NoteDocument(text: text, runs: runs)
    }

    private static func run(from message: Message) throws -> NoteRun {
        var run = NoteRun(length: Int(clamping: message.varint(1) ?? 0))
        if let paragraph = try message.message(2) {
            run.paragraph = try paragraphStyle(from: paragraph)
        }
        switch message.varint(5) {
        case 1: run.bold = true
        case 2: run.italic = true
        case 3: (run.bold, run.italic) = (true, true)
        default: break
        }
        run.underline = (message.varint(6) ?? 0) != 0
        run.strikethrough = (message.varint(7) ?? 0) != 0
        run.link = message.bytes(9).map { String(decoding: $0, as: UTF8.self) }
        if let info = try message.message(12) {
            run.attachment = NoteAttachment(
                identifier: info.bytes(1).map { String(decoding: $0, as: UTF8.self) },
                typeUTI: info.bytes(2).map { String(decoding: $0, as: UTF8.self) })
        }
        return run
    }

    private static func paragraphStyle(from message: Message) throws -> ParagraphStyle {
        var style = ParagraphStyle()
        style.kind = switch message.varint(1).map({ Int64(bitPattern: $0) }) {
        case 0: .title
        case 1: .heading
        case 2: .subheading
        case 4: .monospaced
        case 100: .dotted
        case 101: .dashed
        case 102: .numbered
        case 103: .checklist
        default: .body
        }
        style.indent = Int(clamping: message.varint(4) ?? 0)
        style.checked = ((try message.message(5))?.varint(2) ?? 0) != 0
        style.blockQuote = (message.varint(8) ?? 0) != 0
        return style
    }

    /// Checks the gzip header, skips its optional fields (RFC 1952) and inflates the raw DEFLATE payload.
    static func gunzip(_ data: Data) throws -> [UInt8] {
        let b = [UInt8](data)
        guard b.count >= 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw NoteBodyDecoderError.notGzip }
        let flags = b[3]
        var pos = 10
        if flags & 4 != 0 {
            guard pos + 2 <= b.count else { throw NoteBodyDecoderError.decompressionFailed }
            pos += 2 + Int(b[pos]) + (Int(b[pos + 1]) << 8)
        }
        for flag: UInt8 in [8, 16] where flags & flag != 0 {
            while pos < b.count, b[pos] != 0 { pos += 1 }
            pos += 1
        }
        if flags & 2 != 0 { pos += 2 }
        guard pos < b.count - 8 else { throw NoteBodyDecoderError.decompressionFailed }
        do {
            let payload = Data(b[pos..<(b.count - 8)]) as NSData
            return [UInt8](try payload.decompressed(using: .zlib) as Data)
        } catch {
            throw NoteBodyDecoderError.decompressionFailed
        }
    }
}

/// Reads protobuf wire format: varint and length-delimited fields are kept, fixed32/fixed64 are skipped.
struct WireReader {
    enum Value {
        case varint(UInt64)
        case bytes([UInt8])
        case skipped
    }

    private let data: [UInt8]
    private var pos = 0

    init(_ data: [UInt8]) {
        self.data = data
    }

    mutating func next() throws -> (field: Int, value: Value)? {
        guard pos < data.count else { return nil }
        let key = try readVarint()
        let field = Int(key >> 3)
        switch key & 7 {
        case 0: return (field, .varint(try readVarint()))
        case 1: try skip(8); return (field, .skipped)
        case 2:
            let length = try readVarint()
            guard length <= UInt64(data.count - pos) else { throw NoteBodyDecoderError.malformed }
            defer { pos += Int(length) }
            return (field, .bytes(Array(data[pos..<(pos + Int(length))])))
        case 5: try skip(4); return (field, .skipped)
        default: throw NoteBodyDecoderError.malformed
        }
    }

    private mutating func skip(_ count: Int) throws {
        guard count <= data.count - pos else { throw NoteBodyDecoderError.malformed }
        pos += count
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 7) {
            guard pos < data.count else { throw NoteBodyDecoderError.malformed }
            let byte = data[pos]
            pos += 1
            result |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte < 0x80 { return result }
        }
        throw NoteBodyDecoderError.malformed
    }
}

/// One parsed protobuf message. A field read with the wrong wire type counts as absent; a repeated singular field keeps its last value.
struct Message {
    private var fields: [(field: Int, value: WireReader.Value)] = []

    init(_ data: [UInt8]) throws {
        var reader = WireReader(data)
        while let field = try reader.next() { fields.append(field) }
    }

    func allBytes(_ field: Int) -> [[UInt8]] {
        fields.compactMap { entry in
            guard entry.field == field, case .bytes(let bytes) = entry.value else { return nil }
            return bytes
        }
    }

    func bytes(_ field: Int) -> [UInt8]? {
        allBytes(field).last
    }

    func varint(_ field: Int) -> UInt64? {
        fields.last { entry in
            if entry.field == field, case .varint = entry.value { return true }
            return false
        }.flatMap { entry in
            guard case .varint(let value) = entry.value else { return nil }
            return value
        }
    }

    func message(_ field: Int) throws -> Message? {
        try bytes(field).map { try Message($0) }
    }
}
