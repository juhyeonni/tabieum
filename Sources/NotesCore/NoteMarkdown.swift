import Foundation

extension NoteDocument {
    /// One Markdown line per Notes paragraph; consecutive monospaced paragraphs share one fenced block.
    public func markdown() -> String {
        var output: [String] = []
        var code: [String] = []
        func closeCode() {
            guard !code.isEmpty else { return }
            let longestRun = code.joined().split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            let fence = String(repeating: "`", count: max(3, longestRun + 1))
            output += [fence] + code + [fence]
            code = []
        }
        for line in lines() {
            if line.paragraph.kind == .monospaced {
                code.append(line.pieces.map(\.text).joined().replacingOccurrences(of: "\u{FFFC}", with: ""))
                continue
            }
            closeCode()
            output.append(Self.render(line))
        }
        closeCode()
        return output.joined(separator: "\n")
    }

    private struct Format: Equatable {
        var bold = false, italic = false, underline = false, strikethrough = false
        var link: String?
        var attachment: NoteAttachment?

        init(_ run: NoteRun) {
            bold = run.bold
            italic = run.italic
            underline = run.underline
            strikethrough = run.strikethrough
            link = run.link?.isEmpty == false ? run.link : nil
            attachment = run.attachment
        }
    }

    private struct Piece {
        var text: String
        var format: Format
    }

    private struct Line {
        var paragraph = ParagraphStyle()
        var pieces: [Piece] = []
    }

    /// Splits the text at newlines. A run's length counts UTF-16 code units; a line takes the paragraph style of its first character.
    private func lines() -> [Line] {
        let units = Array(text.utf16)
        var result: [Line] = []
        var current = Line()
        var hasStyle = false
        var position = 0

        func flush(_ chunk: inout [UInt16], _ format: Format) {
            guard !chunk.isEmpty else { return }
            current.pieces.append(Piece(text: String(decoding: chunk, as: UTF16.self), format: format))
            chunk = []
        }

        func consume(_ count: Int, _ run: NoteRun) {
            let format = Format(run)
            var chunk: [UInt16] = []
            for unit in units[position..<(position + count)] {
                if !hasStyle {
                    current.paragraph = run.paragraph
                    hasStyle = true
                }
                if unit == 10 {
                    flush(&chunk, format)
                    result.append(current)
                    current = Line()
                    hasStyle = false
                } else {
                    chunk.append(unit)
                }
            }
            flush(&chunk, format)
            position += count
        }

        for run in runs {
            consume(min(max(run.length, 0), units.count - position), run)
        }
        consume(units.count - position, NoteRun(length: 0))
        result.append(current)
        return result
    }

    private static func render(_ line: Line) -> String {
        let content = inline(line.pieces)
        guard !content.isEmpty else { return "" }
        let style = line.paragraph
        let indent = String(repeating: " ", count: 4 * style.indent)
        let prefix: String
        switch style.kind {
        case .title: prefix = "# "
        case .heading: prefix = "## "
        case .subheading: prefix = "### "
        case .dotted, .dashed: prefix = indent + "- "
        case .numbered: prefix = indent + "1. "
        case .checklist: prefix = indent + (style.checked ? "- [x] " : "- [ ] ")
        case .body, .monospaced: prefix = ""
        }
        return (style.blockQuote ? "> " : "") + prefix + content
    }

    private static func inline(_ pieces: [Piece]) -> String {
        var merged: [Piece] = []
        for piece in pieces {
            if let last = merged.last, last.format == piece.format {
                merged[merged.count - 1].text += piece.text
            } else {
                merged.append(piece)
            }
        }
        let raw = Array(pieces.map(\.text).joined().unicodeScalars)
        let blockMarkers = blockMarkerIndexes(raw)
        var offset = 0
        var output = ""
        for piece in merged {
            output += styled(piece, offset: offset, blockMarkers: blockMarkers)
            offset += piece.text.unicodeScalars.count
        }
        return output
    }

    /// Indexes of the characters that would turn a line into a heading, quote, bullet or numbered item.
    private static func blockMarkerIndexes(_ scalars: [Unicode.Scalar]) -> Set<Int> {
        guard var i = scalars.firstIndex(where: { $0 != " " }) else { return [] }
        if "#>+-".unicodeScalars.contains(scalars[i]) { return [i] }
        let start = i
        while i < scalars.count, ("0"..."9").contains(scalars[i]) { i += 1 }
        if i > start, i < scalars.count, scalars[i] == "." || scalars[i] == ")" { return [i] }
        return []
    }

    private static func styled(_ piece: Piece, offset: Int, blockMarkers: Set<Int>) -> String {
        let format = piece.format
        if let attachment = format.attachment {
            let marker = attachment.typeUTI.map { "[attachment: \($0)]" } ?? "[attachment]"
            return piece.text.unicodeScalars.filter { $0 == "\u{FFFC}" }.map { _ in marker }.joined()
        }
        var escaped = ""
        for (index, scalar) in piece.text.unicodeScalars.enumerated() where scalar != "\u{FFFC}" {
            if "\\*_`[]~<".unicodeScalars.contains(scalar) || blockMarkers.contains(offset + index) {
                escaped.unicodeScalars.append("\\")
            }
            escaped.unicodeScalars.append(scalar)
        }
        let leading = escaped.prefix(while: \.isWhitespace)
        var core = escaped.dropFirst(leading.count)
        let trailing = core.reversed().prefix(while: \.isWhitespace).reversed()
        core = core.dropLast(trailing.count)
        guard !core.isEmpty else { return escaped }

        var result = String(core)
        if format.strikethrough { result = "~~\(result)~~" }
        switch (format.bold, format.italic) {
        case (true, true): result = "***\(result)***"
        case (true, false): result = "**\(result)**"
        case (false, true): result = "*\(result)*"
        case (false, false): break
        }
        if format.underline { result = "<u>\(result)</u>" }
        if let link = format.link {
            let url = link.replacingOccurrences(of: " ", with: "%20")
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
            result = "[\(result)](\(url))"
        }
        return String(leading) + result + String(trailing)
    }
}
