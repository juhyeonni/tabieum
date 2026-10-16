import Foundation

/// Notes' Format menu paragraph styles, in menu order.
public enum NotesStyle: String, CaseIterable, Sendable {
    case title, heading, subheading, body, monostyled, bulletedList, dashedList, numberedList, checklist, blockQuote

    /// The Notes menu item's key equivalent, as AXMenuItemCmdChar and AXMenuItemCmdModifiers report it
    /// (modifiers: 0 = ⌘ alone, 1 = ⇧⌘).
    public var keyEquivalent: (char: String, modifiers: Int) {
        switch self {
        case .title: ("T", 1)
        case .heading: ("H", 1)
        case .subheading: ("J", 1)
        case .body: ("B", 1)
        case .monostyled: ("M", 1)
        case .bulletedList: ("7", 1)
        case .dashedList: ("8", 1)
        case .numberedList: ("9", 1)
        case .checklist: ("L", 1)
        case .blockQuote: ("'", 0)
        }
    }

    /// The key equivalent written as Notes' menu shows it, such as ⇧⌘H.
    public var shortcut: String {
        let (char, modifiers) = keyEquivalent
        return (modifiers == 1 ? "⇧⌘" : "⌘") + char
    }

    public var displayName: String {
        switch self {
        case .title: "Title"
        case .heading: "Heading"
        case .subheading: "Subheading"
        case .body: "Body"
        case .monostyled: "Monostyled"
        case .bulletedList: "Bulleted list"
        case .dashedList: "Dashed list"
        case .numberedList: "Numbered list"
        case .checklist: "Checklist"
        case .blockQuote: "Block quote"
        }
    }
}

/// Notes paragraph styles reachable from a Markdown marker typed at the start of a line.
public enum MarkdownStyle: String, CaseIterable, Sendable {
    case title, heading, subheading, checklist, blockQuote, monostyled

    public var marker: String {
        switch self {
        case .title: "# "
        case .heading: "## "
        case .subheading: "### "
        case .checklist: "[ ] "
        case .blockQuote: "> "
        case .monostyled: "```\n"
        }
    }

    public var style: NotesStyle { NotesStyle(rawValue: rawValue)! }
    public var displayName: String { style.displayName }
}

/// The note body's text and caret. Offsets count UTF-16 code units.
public struct TextSnapshot: Equatable, Sendable {
    public var text: String
    public var caret: Int

    public init(text: String, caret: Int) {
        self.text = text
        self.caret = caret
    }
}

public struct MarkdownMatch: Equatable, Sendable {
    public var style: MarkdownStyle
    /// The marker's range in the new text, to delete before applying the style.
    public var range: NSRange
}

/// The offset of the character just typed, when `current` is `previous` with exactly one character typed at the caret.
public func typedOffset(previous: TextSnapshot, current: TextSnapshot) -> Int? {
    let old = Array(previous.text.utf16)
    let new = Array(current.text.utf16)
    let caret = previous.caret
    guard new.count == old.count + 1, caret >= 0, caret <= old.count, current.caret == caret + 1,
          new[..<caret].elementsEqual(old[..<caret]),
          new[(caret + 1)...].elementsEqual(old[caret...])
    else { return nil }
    return caret
}

/// A match only when one character was just typed (see `typedOffset`)
/// and the line up to the new caret is exactly an enabled style's marker.
public func markdownMatch(previous: TextSnapshot, current: TextSnapshot, enabled: Set<MarkdownStyle>) -> MarkdownMatch? {
    guard let caret = typedOffset(previous: previous, current: current) else { return nil }
    let new = Array(current.text.utf16)
    // The typed character itself may be the Return that ends a ``` line.
    let start = new[..<caret].lastIndex(of: UInt16(UInt8(ascii: "\n"))).map { $0 + 1 } ?? 0
    let line = String(decoding: new[start..<current.caret], as: UTF16.self)
    guard let style = enabled.first(where: { $0.marker == line }) else { return nil }
    return MarkdownMatch(style: style, range: NSRange(location: start, length: current.caret - start))
}
