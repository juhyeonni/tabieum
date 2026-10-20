import Foundation

/// The `/` just typed at the start of a line or after whitespace, as a range to delete.
public func slashTrigger(previous: TextSnapshot, current: TextSnapshot) -> NSRange? {
    guard let offset = typedOffset(previous: previous, current: current) else { return nil }
    let text = Array(current.text.utf16)
    guard text[offset] == UInt16(UInt8(ascii: "/")) else { return nil }
    if offset > 0 {
        guard let before = Unicode.Scalar(text[offset - 1]), Character(before).isWhitespace else { return nil }
    }
    return NSRange(location: offset, length: 1)
}

/// The text typed after the `/` at `offset`, up to the caret; nil when the menu should close.
public func slashQuery(text: String, slashOffset offset: Int, caret: Int) -> String? {
    let utf16 = Array(text.utf16)
    guard offset >= 0, offset < utf16.count, utf16[offset] == UInt16(UInt8(ascii: "/")),
          caret > offset, caret <= utf16.count
    else { return nil }
    let query = String(decoding: utf16[(offset + 1)..<caret], as: UTF16.self)
    return query.contains(where: \.isWhitespace) ? nil : query
}

public enum SlashSection: String, CaseIterable, Sendable {
    case templates = "Templates", styles = "Styles", commands = "Commands"
}

public struct SlashItem: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// A Notes note id.
        case template(String)
        case style(NotesStyle)
        /// An index into `SlashCommandRegistry.commands`.
        case command(Int)
        case table(columns: Int, rows: Int)
    }

    public var title: String
    public var action: Action

    public init(title: String, action: Action) {
        self.title = title
        self.action = action
    }

    public var section: SlashSection {
        switch action {
        case .template: .templates
        case .style: .styles
        case .command, .table: .commands
        }
    }

    /// A style's Notes keyboard shortcut; templates and commands have none.
    public var shortcut: String? {
        guard case let .style(style) = action else { return nil }
        return style.shortcut
    }

    public static let builtIns = NotesStyle.allCases.map { SlashItem(title: $0.displayName, action: .style($0)) }

    public static let table = SlashItem(title: "Table", action: .table(columns: 3, rows: 3))
}

/// The size in a `table<columns>x<rows>` query: up to 10 columns by 20 rows.
public func tableSize(query: String) -> (columns: Int, rows: Int)? {
    let parts = query.lowercased().split(separator: "x", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].hasPrefix("table") else { return nil }
    let numbers = [parts[0].dropFirst(5), parts[1]]
    guard numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
          let columns = Int(numbers[0]), let rows = Int(numbers[1]),
          (1...10).contains(columns), (1...20).contains(rows)
    else { return nil }
    return (columns, rows)
}

/// A table of empty cells as Notes HTML.
public func tableHTML(columns: Int, rows: Int) -> String {
    let row = "<tr>" + String(repeating: "<td></td>", count: columns) + "</tr>"
    return "<table>" + String(repeating: row, count: rows) + "</table>"
}

/// A table of empty cells as tab-separated plain text.
public func tablePlainText(columns: Int, rows: Int) -> String {
    String(repeating: String(repeating: "\t", count: columns - 1) + "\n", count: rows)
}

/// Case-insensitive, canonically equivalent substring match on the title; prefix matches first, otherwise source order.
public func filterSlashItems(_ items: [SlashItem], query: String) -> [SlashItem] {
    let query = query.precomposedStringWithCanonicalMapping
    guard !query.isEmpty else { return items }
    if let size = tableSize(query: query) {
        return [SlashItem(title: "Table \(size.columns)×\(size.rows)", action: .table(columns: size.columns, rows: size.rows))]
    }
    if query.lowercased().wholeMatch(of: /table(\d{1,2}x?)?/) != nil { return items.filter { $0 == .table } }
    var prefixed: [SlashItem] = []
    var contained: [SlashItem] = []
    for item in items {
        let title = item.title.precomposedStringWithCanonicalMapping
        guard let range = title.range(of: query, options: .caseInsensitive) else { continue }
        if range.lowerBound == title.startIndex {
            prefixed.append(item)
        } else {
            contained.append(item)
        }
    }
    return prefixed + contained
}

/// Items grouped Templates, Styles, Commands, each keeping its order; empty sections are left out.
public func groupSlashItems(_ items: [SlashItem]) -> [(section: SlashSection, items: [SlashItem])] {
    SlashSection.allCases.compactMap { section in
        let group = items.filter { $0.section == section }
        return group.isEmpty ? nil : (section, group)
    }
}

/// The menu stays open for the empty query and for any query that matches an item.
public func slashMenuStaysOpen(_ items: [SlashItem], query: String) -> Bool {
    !filterSlashItems(items, query: query).isEmpty
}

/// Commands other features add to the `/` panel, each listed only while its condition holds.
@MainActor
public final class SlashCommandRegistry {
    public struct Command {
        public let title: String
        public let isVisible: () -> Bool
        /// Runs after the `/` is deleted.
        public let run: () -> Void
    }

    public private(set) var commands: [Command] = []

    public init() {}

    public func register(_ title: String, isVisible: @escaping () -> Bool = { true }, run: @escaping () -> Void) {
        commands.append(Command(title: title, isVisible: isVisible, run: run))
    }

    public var items: [SlashItem] {
        commands.indices.filter { commands[$0].isVisible() }.map { SlashItem(title: commands[$0].title, action: .command($0)) }
    }
}

private let voidElements: Set<String> = ["br", "img", "hr", "input", "meta", "link", "wbr", "col", "source", "area", "base", "embed"]

/// A template's Notes HTML body without its first line, the template's title.
/// Notes writes each line as one top-level element; the element and the newline after it are removed.
public func strippingFirstLine(html: String) -> String {
    let trimmed = html.drop { $0.isWhitespace }
    guard trimmed.first == "<" else {
        return trimmed.firstIndex(of: "\n").map { String(trimmed[trimmed.index(after: $0)...]) } ?? ""
    }
    var index = trimmed.startIndex
    var depth = 0
    while let open = trimmed[index...].firstIndex(of: "<"), let close = trimmed[open...].firstIndex(of: ">") {
        let tag = trimmed[trimmed.index(after: open)..<close]
        index = trimmed.index(after: close)
        if tag.hasPrefix("!") { continue }
        let name = tag.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }.lowercased()
        if tag.hasPrefix("/") {
            depth -= 1
        } else if !tag.hasSuffix("/") && !voidElements.contains(name) {
            depth += 1
        }
        if depth <= 0 { break }
    }
    if trimmed[index...].hasPrefix("\n") { index = trimmed.index(after: index) }
    return String(trimmed[index...])
}

/// A template's plain text without its first line.
public func strippingFirstLine(plainText: String) -> String {
    plainText.firstIndex(of: "\n").map { String(plainText[plainText.index(after: $0)...]) } ?? ""
}
