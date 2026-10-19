import Foundation

/// Turns the small Markdown subset an agent writes into the HTML Notes takes as a note body.
/// All text is escaped; nothing the agent writes reaches Notes as markup.
public enum NoteHTML {
    public static func html(fromMarkdown markdown: String) -> String {
        var out = ""
        var paragraph: [String] = []
        var list: (tag: String, items: [String])?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out += "<div>" + paragraph.map(inline).joined(separator: "<br>") + "</div>"
            paragraph = []
        }
        func flushList() {
            guard let current = list else { return }
            out += "<\(current.tag)>" + current.items.map { "<li>\(inline($0))</li>" }.joined() + "</\(current.tag)>"
            list = nil
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let (level, text) = heading(line) {
                flushParagraph()
                flushList()
                out += "<h\(level)>\(inline(text))</h\(level)>"
            } else if let (box, text) = task(line) {
                flushParagraph()
                flushList()
                out += "<div>\(box) \(inline(text))</div>"
            } else if let (tag, text) = item(line) {
                flushParagraph()
                if list?.tag != tag {
                    flushList()
                    list = (tag, [])
                }
                list?.items.append(text)
            } else if line.allSatisfy(\.isWhitespace) {
                flushParagraph()
                flushList()
            } else {
                flushList()
                paragraph.append(line)
            }
        }
        flushParagraph()
        flushList()
        return out
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...3).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    /// Notes cannot be handed a real checklist, so a task item becomes a line starting with a box character.
    private static func task(_ line: String) -> (String, String)? {
        guard line.hasPrefix("- [") || line.hasPrefix("* [") else { return nil }
        let rest = line.dropFirst(3)
        guard rest.dropFirst().first == "]",rest.dropFirst(2).first == " " else { return nil }
        switch rest.first {
        case " ": return ("☐", String(rest.dropFirst(3)))
        case "x", "X": return ("☑", String(rest.dropFirst(3)))
        default: return nil
        }
    }

    private static func item(_ line: String) -> (String, String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return ("ul", String(line.dropFirst(2))) }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return ("ol", String(line.dropFirst(digits.count + 2)))
    }

    /// Code spans first, so their contents stay literal; bold and italic only in the text between them.
    private static func inline(_ text: String) -> String {
        let parts = text.components(separatedBy: "`")
        guard parts.count % 2 == 1 else { return styled(text) }
        return parts.enumerated().map { index, part in
            index % 2 == 1 ? "<tt>\(escaped(part))</tt>" : styled(part)
        }.joined()
    }

    private static func styled(_ text: String) -> String {
        escaped(text)
            .replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
            .replacingOccurrences(of: #"\*(.+?)\*"#, with: "<i>$1</i>", options: .regularExpression)
            .replacingOccurrences(of: #"(?<![A-Za-z0-9])_(.+?)_(?![A-Za-z0-9])"#, with: "<i>$1</i>", options: .regularExpression)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
