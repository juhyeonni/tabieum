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
        /// Text to paste in place of the `/query`.
        case insert(String)
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
        case .command, .insert: .commands
        }
    }

    /// A style's Notes keyboard shortcut; templates and commands have none.
    public var shortcut: String? {
        guard case let .style(style) = action else { return nil }
        return style.shortcut
    }

    public static let builtIns = NotesStyle.allCases.map { SlashItem(title: $0.displayName, action: .style($0)) }
}

private func isoText(daysFrom offset: Int, time: String?, now: Date, calendar: Calendar) -> String {
    let day = calendar.date(byAdding: .day, value: offset, to: now) ?? now
    let parts = calendar.dateComponents([.year, .month, .day], from: day)
    let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    return time.map { "\(date) \($0)" } ?? date
}

private let dateWords: [(word: String, title: String, offset: Int)] = [
    ("today", "Today", 0), ("tomorrow", "Tomorrow", 1), ("yesterday", "Yesterday", -1),
]

extension SlashItem {
    /// Today, Tomorrow, Yesterday as `YYYY-MM-DD` and Now as `YYYY-MM-DD HH:mm`, in `calendar`'s time zone.
    public static func dates(now: Date, calendar: Calendar = .current) -> [SlashItem] {
        let days = dateWords.map {
            SlashItem(title: $0.title, action: .insert(isoText(daysFrom: $0.offset, time: nil, now: now, calendar: calendar)))
        }
        let time = String(format: "%02d:%02d", calendar.component(.hour, from: now), calendar.component(.minute, from: now))
        return days + [SlashItem(title: "Now", action: .insert(isoText(daysFrom: 0, time: time, now: now, calendar: calendar)))]
    }

    /// The one item for a query like `today1010`: a date word and exactly four digits `HHmm`; nil for any other shape.
    public static func timedDate(query: String, now: Date, calendar: Calendar = .current) -> SlashItem? {
        let query = query.lowercased()
        guard let entry = dateWords.first(where: { query.hasPrefix($0.word) }) else { return nil }
        let digits = query.dropFirst(entry.word.count)
        guard digits.count == 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let hour = Int(digits.prefix(2)), let minute = Int(digits.suffix(2)), hour < 24, minute < 60
        else { return nil }
        let time = String(format: "%02d:%02d", hour, minute)
        return SlashItem(title: "\(entry.title) \(time)",
                         action: .insert(isoText(daysFrom: entry.offset, time: time, now: now, calendar: calendar)))
    }
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
