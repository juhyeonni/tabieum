import Foundation

public enum VimAction: Equatable, Sendable {
    case select(NSRange)
    case delete(NSRange)
    case insert(String, at: Int)
    case undo
}

/// A text snapshot with its selection, both in UTF-16 units as AX reports them.
public struct VimBuffer: Equatable, Sendable {
    public var text: String
    public var selection: NSRange

    public init(text: String, selection: NSRange = NSRange(location: 0, length: 0)) {
        self.text = text
        self.selection = selection
    }

    public mutating func apply(_ action: VimAction) {
        switch action {
        case .select(let range):
            selection = range
        case .delete(let range):
            text = (text as NSString).replacingCharacters(in: range, with: "")
            selection = NSRange(location: range.location, length: 0)
        case .insert(let string, let offset):
            text = (text as NSString).replacingCharacters(in: NSRange(location: offset, length: 0), with: string)
            selection = NSRange(location: offset + string.utf16.count, length: 0)
        case .undo:
            break
        }
    }

    public mutating func apply(_ actions: [VimAction]) {
        actions.forEach { apply($0) }
    }

    /// The caret's line, newline included.
    public var caretLine: NSRange {
        let ns = text as NSString
        return ns.lineRange(for: NSRange(location: min(selection.location, ns.length), length: 0))
    }

    /// A line holding only U+FFFC is a table or an image; deleting across it would destroy the attachment.
    public func deleteWouldHitBlockAttachment(_ range: NSRange) -> Bool {
        let ns = text as NSString
        guard range.length > 0 else { return false }
        var location = ns.lineRange(for: NSRange(location: min(range.location, ns.length), length: 0)).location
        while location < min(NSMaxRange(range), ns.length) {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            if ns.substring(with: line).trimmingCharacters(in: .newlines) == "\u{FFFC}" { return true }
            location = NSMaxRange(line)
        }
        return false
    }
}

/// The text as `Character`s, with each one's UTF-16 offset, so motions never split a grapheme.
struct VimText {
    let chars: [Character]
    let offsets: [Int]

    init(_ string: String) {
        var chars: [Character] = []
        var offsets: [Int] = []
        var offset = 0
        for c in string {
            chars.append(c)
            offsets.append(offset)
            offset += c.utf16.count
        }
        offsets.append(offset)
        self.chars = chars
        self.offsets = offsets
    }

    var count: Int { chars.count }

    // ponytail: linear scan per command, binary search if long notes feel slow
    func index(at offset: Int) -> Int {
        offsets.firstIndex { $0 >= offset } ?? count
    }

    func lineStart(_ i: Int) -> Int {
        var j = i
        while j > 0 && chars[j - 1] != "\n" { j -= 1 }
        return j
    }

    func lineEnd(_ i: Int) -> Int {
        var j = i
        while j < count && chars[j] != "\n" { j += 1 }
        return j
    }

    func lastChar(_ i: Int) -> Int {
        max(lineStart(i), lineEnd(i) - 1)
    }

    func clamp(_ i: Int) -> Int {
        min(i, lastChar(i))
    }

    func firstNonBlank(_ i: Int, clamped: Bool = true) -> Int {
        var j = lineStart(i)
        let end = lineEnd(i)
        while j < end && chars[j].isWhitespace { j += 1 }
        return clamped ? min(j, lastChar(i)) : j
    }

    func range(_ from: Int, _ to: Int) -> NSRange {
        NSRange(location: offsets[from], length: offsets[to] - offsets[from])
    }

    func string(_ from: Int, _ to: Int) -> String {
        String(chars[from..<to])
    }
}
