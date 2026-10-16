import Foundation
import Testing
@testable import NotesCore

/// Test-only protobuf and gzip encoder with made-up text. It only shows the decoder agrees with it.
enum Encode {
    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        while value >= 0x80 {
            out.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        return out + [UInt8(value)]
    }

    static func int(_ field: Int, _ value: Int) -> [UInt8] {
        varint(UInt64(field) << 3) + varint(UInt64(bitPattern: Int64(value)))
    }

    static func bytes(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        varint(UInt64(field) << 3 | 2) + varint(UInt64(payload.count)) + payload
    }

    static func string(_ field: Int, _ value: String) -> [UInt8] {
        bytes(field, Array(value.utf8))
    }

    static func fixed32(_ field: Int) -> [UInt8] {
        varint(UInt64(field) << 3 | 5) + [1, 2, 3, 4]
    }

    static func fixed64(_ field: Int) -> [UInt8] {
        varint(UInt64(field) << 3 | 1) + [1, 2, 3, 4, 5, 6, 7, 8]
    }

    static func paragraph(_ style: Int? = nil, indent: Int = 0, checked: Bool? = nil, quote: Bool = false) -> [UInt8] {
        var out: [UInt8] = []
        if let style { out += int(1, style) }
        if indent > 0 { out += int(4, indent) }
        if let checked { out += bytes(5, string(1, "uuid") + int(2, checked ? 1 : 0)) }
        if quote { out += int(8, 1) }
        return out
    }

    static func run(
        _ length: Int, paragraph: [UInt8]? = nil, weight: Int? = nil, underline: Bool = false,
        strike: Bool = false, link: String? = nil, attachment: String?? = nil, extra: [UInt8] = []
    ) -> [UInt8] {
        var out = int(1, length)
        if let paragraph { out += bytes(2, paragraph) }
        if let weight { out += int(5, weight) }
        if underline { out += int(6, 1) }
        if strike { out += int(7, 1) }
        if let link { out += string(9, link) }
        if let attachment {
            out += bytes(12, string(1, "id") + (attachment.map { string(2, $0) } ?? []))
        }
        return bytes(5, out + extra)
    }

    /// body -> document (2) -> note (3) -> text (2), runs (5)
    static func body(_ text: String, _ runs: [[UInt8]], noteExtra: [UInt8] = []) -> [UInt8] {
        bytes(2, int(1, 0) + bytes(3, string(2, text) + runs.flatMap { $0 } + noteExtra))
    }

    static func gzip(_ raw: [UInt8], name: String? = nil) -> Data {
        let deflated = try! (Data(raw) as NSData).compressed(using: .zlib) as Data
        var header: [UInt8] = [0x1f, 0x8b, 8, name == nil ? 0 : 8, 0, 0, 0, 0, 0, 3]
        if let name { header += Array(name.utf8) + [0] }
        return Data(header) + deflated + Data(repeating: 0, count: 8)
    }

    static func gzipBody(_ text: String, _ runs: [[UInt8]]) -> Data {
        gzip(body(text, runs))
    }
}

private func markdown(_ text: String, _ runs: [[UInt8]]) throws -> String {
    try NoteBodyDecoder.decode(Encode.gzipBody(text, runs)).markdown()
}

@Suite struct NoteBodyDecoderTests {
    // AC10
    @Test func goldenFixtureDecodesToCommittedMarkdown() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let hex = Array(try String(contentsOf: fixtures.appendingPathComponent("golden-macOS26.hex"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        let body = Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(String(hex[$0...$0 + 1]), radix: 16)! })
        let markdown = try NoteBodyDecoder.decode(body).markdown()
        let expected = try String(contentsOf: fixtures.appendingPathComponent("golden-macOS26.md"), encoding: .utf8)
        #expect(markdown == expected)
    }

    @Test func decodesGzipBodyToTextAndRuns() throws {
        let runs = [Encode.run(3, weight: 1), Encode.run(4, paragraph: Encode.paragraph(0), link: "https://example.com")]
        let document = try NoteBodyDecoder.decode(Encode.gzipBody("abcdefg", runs))
        #expect(document.text == "abcdefg")
        #expect(document.runs.count == 2)
        #expect(document.runs[0].length == 3 && document.runs[0].bold)
        #expect(document.runs[1].paragraph.kind == .title)
        #expect(document.runs[1].link == "https://example.com")
    }

    @Test func skipsGzipOptionalFields() throws {
        let data = Encode.gzip(Encode.body("hi", [Encode.run(2)]), name: "note.txt")
        #expect(try NoteBodyDecoder.decode(data).text == "hi")
    }

    @Test func rejectsBodyWithoutGzipMagic() {
        #expect(throws: NoteBodyDecoderError.notGzip) {
            try NoteBodyDecoder.decode(Data(Encode.body("hi", [])) + Data(repeating: 0, count: 20))
        }
    }

    @Test func paragraphStylesRenderAsMarkdown() throws {
        let styles: [(Int, String)] = [
            (0, "# t"), (1, "## t"), (2, "### t"), (100, "- t"), (101, "- t"), (102, "1. t"), (103, "- [ ] t"),
        ]
        for (style, expected) in styles {
            #expect(try markdown("t", [Encode.run(1, paragraph: Encode.paragraph(style, checked: style == 103 ? false : nil))]) == expected)
        }
        #expect(try markdown("t", [Encode.run(1, paragraph: Encode.paragraph(103, checked: true))]) == "- [x] t")
        #expect(try markdown("t", [Encode.run(1, paragraph: Encode.paragraph(-1))]) == "t")
    }

    @Test func indentAndBlockQuoteRender() throws {
        #expect(try markdown("t", [Encode.run(1, paragraph: Encode.paragraph(100, indent: 2))]) == "        - t")
        #expect(try markdown("t", [Encode.run(1, paragraph: Encode.paragraph(102, indent: 1, quote: true))]) == ">     1. t")
        #expect(try markdown("t", [Encode.run(1, paragraph: Encode.paragraph(quote: true))]) == "> t")
    }

    @Test func paragraphsStayOneLineEach() throws {
        let h = Encode.paragraph(1)
        let result = try markdown("a\n\nb\n", [Encode.run(2, paragraph: h), Encode.run(1), Encode.run(2)])
        #expect(result == "## a\n\nb\n")
    }

    @Test func inlineStylesRender() throws {
        let cases: [(Encode.Style, String)] = [
            (.weight(1), "**x**"), (.weight(2), "*x*"), (.weight(3), "***x***"),
            (.strike, "~~x~~"), (.underline, "<u>x</u>"), (.link, "[x](https://e.com/a%20b)"),
        ]
        for (style, expected) in cases {
            #expect(try markdown("x", [style.run(1)]) == expected)
        }
    }

    @Test func adjacentSameStyleRunsMerge() throws {
        #expect(try markdown("abcd", [Encode.run(2, weight: 1), Encode.run(2, weight: 1)]) == "**abcd**")
    }

    @Test func markersStayAwayFromWhitespace() throws {
        let result = try markdown(" ab  c ", [Encode.run(1), Encode.run(2, weight: 1), Encode.run(3, weight: 2), Encode.run(1, strike: true)])
        #expect(result == " **ab**  *c* ")
        #expect(try markdown("   ", [Encode.run(3, weight: 1)]) == "   ")
    }

    @Test func literalMarkdownCharactersAreEscaped() throws {
        #expect(try markdown("a*b_c[d]`e\\f~g<h", [Encode.run(16)]) == "a\\*b\\_c\\[d\\]\\`e\\\\f\\~g\\<h")
        #expect(try markdown("# not heading", [Encode.run(13)]) == "\\# not heading")
        #expect(try markdown("1. not list", [Encode.run(11)]) == "1\\. not list")
        #expect(try markdown("- not bullet", [Encode.run(12)]) == "\\- not bullet")
        #expect(try markdown("> not quote", [Encode.run(11)]) == "\\> not quote")
    }

    @Test func consecutiveMonospacedLinesFormOneFence() throws {
        let mono = Encode.paragraph(4)
        let result = try markdown("a\n*b*\nc\nd", [Encode.run(2, paragraph: mono), Encode.run(4, paragraph: mono), Encode.run(2), Encode.run(1)])
        #expect(result == "```\na\n*b*\n```\nc\nd")
    }

    @Test func fenceGrowsPastBackticksInCode() throws {
        #expect(try markdown("```", [Encode.run(3, paragraph: Encode.paragraph(4))]) == "````\n```\n````")
    }

    @Test func runLengthsCountUTF16UnitsAfterEmoji() throws {
        let runs = [Encode.run(2, weight: 1), Encode.run(1), Encode.run(1, weight: 2)]
        #expect(try markdown("😀 b", runs) == "**😀** *b*")
    }

    @Test func attachmentsRenderAndLeavePlainText() throws {
        let runs = [Encode.run(1), Encode.run(1, attachment: .some("public.jpeg")), Encode.run(1, attachment: .some(nil))]
        let document = try NoteBodyDecoder.decode(Encode.gzipBody("a\u{FFFC}\u{FFFC}", runs))
        #expect(document.markdown() == "a[attachment: public.jpeg][attachment]")
        #expect(document.plainText == "a")
    }

    @Test func unknownFieldsAndStylesDoNotChangeOutput() throws {
        let clean = try markdown("ab", [Encode.run(1, weight: 1), Encode.run(1)])
        let noisy = Encode.body(
            "ab",
            [
                Encode.run(1, paragraph: Encode.paragraph(77) + Encode.fixed32(30), weight: 1, extra: Encode.fixed64(40) + Encode.int(41, 5) + Encode.string(42, "x")),
                Encode.run(1),
            ],
            noteExtra: Encode.fixed32(50) + Encode.string(51, "y"))
        let document = try NoteBodyDecoder.decode(Encode.gzip(noisy))
        #expect(document.markdown() == clean)
        #expect(document.runs[0].paragraph.kind == .body)
    }

    @Test func runsPastTheTextEndAreCut() throws {
        #expect(try markdown("ab", [Encode.run(1), Encode.run(100, weight: 1)]) == "a**b**")
    }

    @Test func everyTruncationDecodesOrThrows() {
        let runs = [Encode.run(2, paragraph: Encode.paragraph(103, checked: true), weight: 1), Encode.run(3, link: "https://e.com")]
        let full = Encode.gzipBody("ab\ncde", runs)
        for length in 0...full.count {
            _ = try? NoteBodyDecoder.decode(full.prefix(length)).markdown()
        }
        let raw = Encode.body("ab\ncde", runs)
        for length in 0...raw.count {
            _ = try? NoteBodyDecoder.decode(Encode.gzip(Array(raw.prefix(length)))).markdown()
        }
    }

    @Test func malformedProtobufThrows() {
        #expect(throws: NoteBodyDecoderError.malformed) { try NoteBodyDecoder.decode(Encode.gzip([0x0a, 0x05, 1])) }
        #expect(throws: NoteBodyDecoderError.malformed) { try NoteBodyDecoder.decode(Encode.gzip([])) }
    }
}

extension Encode {
    enum Style {
        case weight(Int), strike, underline, link

        func run(_ length: Int) -> [UInt8] {
            switch self {
            case .weight(let w): Encode.run(length, weight: w)
            case .strike: Encode.run(length, strike: true)
            case .underline: Encode.run(length, underline: true)
            case .link: Encode.run(length, link: "https://e.com/a b")
            }
        }
    }
}
