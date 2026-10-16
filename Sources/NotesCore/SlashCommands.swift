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

public struct SlashItem: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// A Notes note id.
        case template(String)
        case style(NotesStyle)
        /// An index into `SlashCommandRegistry.commands`.
        case command(Int)
    }

    public var title: String
    public var action: Action

    public init(title: String, action: Action) {
        self.title = title
        self.action = action
    }

    public static let builtIns = NotesStyle.allCases.map { SlashItem(title: $0.displayName, action: .style($0)) }
}

/// Case-insensitive, canonically equivalent substring match on the title; prefix matches first, otherwise source order.
public func filterSlashItems(_ items: [SlashItem], query: String) -> [SlashItem] {
    let query = query.precomposedStringWithCanonicalMapping
    guard !query.isEmpty else { return items }
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
