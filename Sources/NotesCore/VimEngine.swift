import Foundation

public struct VimKey: Equatable, Sendable {
    public var character: Character
    public var control: Bool
    public var command: Bool

    public init(_ character: Character, control: Bool = false, command: Bool = false) {
        self.character = character
        self.control = control
        self.command = command
    }

    public static let escape = VimKey("\u{1B}")

    var isEscape: Bool {
        !command && (character == "\u{1B}" || (control && character == "["))
    }

    var isPlain: Bool { !control && !command }
}

public enum VimMode: Equatable, Sendable {
    case normal, insert, visual
}

public enum VimMotion: Equatable, Sendable {
    case left, right, down, up
    case wordForward, wordBackward, wordEnd
    case lineStart, firstNonBlank, lineEnd
    case firstLine, lastLine

    init?(_ c: Character) {
        switch c {
        case "h": self = .left
        case "l": self = .right
        case "j": self = .down
        case "k": self = .up
        case "w": self = .wordForward
        case "b": self = .wordBackward
        case "e": self = .wordEnd
        case "0": self = .lineStart
        case "^": self = .firstNonBlank
        case "$": self = .lineEnd
        case "G": self = .lastLine
        default: return nil
        }
    }
}

public enum VimInsertion: Equatable, Sendable {
    case before, after, lineStart, lineEnd, lineBelow, lineAbove

    init?(_ c: Character) {
        switch c {
        case "i": self = .before
        case "a": self = .after
        case "I": self = .lineStart
        case "A": self = .lineEnd
        case "o": self = .lineBelow
        case "O": self = .lineAbove
        default: return nil
        }
    }
}

public enum VimCommand: Equatable, Sendable {
    case none
    case motion(VimMotion)
    case deleteChar, deleteLine, yankLine, put, undo
    case insert(VimInsertion)
    case exitInsert(deletingJ: Bool)
    case enterVisual, exitVisual
    case deleteSelection, yankSelection
}

public enum VimDecision: Equatable, Sendable {
    case passThrough
    case consume(VimCommand)
}

/// A Vim state machine: `feed` decides from engine state alone, `execute` turns a command into actions on a snapshot.
public struct VimEngine: Sendable {
    public static let jkTimeout: TimeInterval = 1.0

    public private(set) var mode: VimMode
    public var jkEnabled: Bool

    private var pending: Character?
    private var lastJ: TimeInterval?

    private enum Register: Sendable {
        case charwise(String), linewise(String)
    }
    private var register: Register?
    private var goal: (offset: Int, column: Int)?
    private var visualAnchor: Int?
    private var visualCursor = 0

    public init(mode: VimMode = .normal, jkEnabled: Bool = false) {
        self.mode = mode
        self.jkEnabled = jkEnabled
    }

    // MARK: - feed

    public mutating func feed(_ key: VimKey, at time: TimeInterval) -> VimDecision {
        mode == .insert ? feedInsert(key, at: time) : feedCommand(key)
    }

    private mutating func feedInsert(_ key: VimKey, at time: TimeInterval) -> VimDecision {
        let jAt = lastJ
        lastJ = nil
        if key.isEscape {
            mode = .normal
            return .consume(.exitInsert(deletingJ: false))
        }
        guard jkEnabled, key.isPlain else { return .passThrough }
        if key.character == "k", let jAt, time - jAt <= Self.jkTimeout {
            mode = .normal
            return .consume(.exitInsert(deletingJ: true))
        }
        if key.character == "j" { lastJ = time }
        return .passThrough
    }

    private mutating func feedCommand(_ key: VimKey) -> VimDecision {
        let prefix = pending
        pending = nil
        if key.command { return .passThrough }
        if let prefix { return .consume(complete(prefix, key)) }
        if key.isEscape {
            guard mode == .visual else { return .consume(.none) }
            mode = .normal
            return .consume(.exitVisual)
        }
        guard key.isPlain else { return .consume(.none) }
        let c = key.character
        if let motion = VimMotion(c) { return .consume(.motion(motion)) }
        if c == "g" { pending = c; return .consume(.none) }
        return .consume(mode == .visual ? visualCommand(c) : normalCommand(c))
    }

    private func complete(_ prefix: Character, _ key: VimKey) -> VimCommand {
        guard key.isPlain, key.character == prefix else { return .none }
        switch prefix {
        case "g": return .motion(.firstLine)
        case "d": return .deleteLine
        case "y": return .yankLine
        default: return .none
        }
    }

    private mutating func normalCommand(_ c: Character) -> VimCommand {
        if let insertion = VimInsertion(c) {
            mode = .insert
            return .insert(insertion)
        }
        switch c {
        case "d", "y": pending = c; return .none
        case "x": return .deleteChar
        case "p": return .put
        case "u": return .undo
        case "v": mode = .visual; return .enterVisual
        default: return .none
        }
    }

    private mutating func visualCommand(_ c: Character) -> VimCommand {
        switch c {
        case "x", "d": mode = .normal; return .deleteSelection
        case "y": mode = .normal; return .yankSelection
        case "v": mode = .normal; return .exitVisual
        default: return .none
        }
    }

    // MARK: - execute

    public mutating func execute(_ command: VimCommand, on buffer: VimBuffer) -> [VimAction] {
        let t = VimText(buffer.text)
        let goal = self.goal
        self.goal = nil
        let raw = t.index(at: buffer.selection.location)
        let cur = t.clamp(raw)

        switch command {
        case .none:
            return []

        case .motion(let motion):
            guard let anchor = visualAnchor else {
                let new = move(motion, from: cur, in: t, goal: goal)
                return [.select(t.range(new, new))]
            }
            let new = move(motion, from: t.clamp(t.index(at: visualCursor)), in: t, goal: goal)
            visualCursor = t.offsets[new]
            return [.select(visualRange(anchor, in: t))]

        case .deleteChar:
            guard cur < t.lineEnd(cur) else { return [] }
            register = .charwise(t.string(cur, cur + 1))
            return edit(buffer, .delete(t.range(cur, cur + 1)), cursorAt: t.offsets[cur])

        case .deleteLine:
            let start = t.lineStart(cur), end = t.lineEnd(cur)
            register = .linewise(t.string(start, end))
            let range = end < t.count ? t.range(start, end + 1)
                : start > 0 ? t.range(start - 1, end)
                : t.range(start, end)
            guard range.length > 0 else { return [] }
            return edit(buffer, .delete(range), cursorAt: range.location) { $0.firstNonBlank($1) }

        case .yankLine:
            register = .linewise(t.string(t.lineStart(cur), t.lineEnd(cur)))
            return []

        case .put:
            switch register {
            case .charwise(let s) where !s.isEmpty:
                let at = t.offsets[cur < t.lineEnd(cur) ? cur + 1 : cur]
                return edit(buffer, .insert(s, at: at), cursorAt: at + String(s.dropLast()).utf16.count)
            case .linewise(let s):
                let at = t.offsets[t.lineEnd(cur)]
                return edit(buffer, .insert("\n" + s, at: at), cursorAt: at + 1) { $0.firstNonBlank($1) }
            default:
                return []
            }

        case .undo:
            return [.undo]

        case .insert(let insertion):
            return insert(insertion, at: cur, in: t, buffer: buffer)

        case .exitInsert(let deletingJ):
            guard deletingJ, raw > 0, t.chars[raw - 1] == "j" else {
                let new = stepLeft(raw, in: t)
                return [.select(t.range(new, new))]
            }
            return edit(buffer, .delete(t.range(raw - 1, raw)), cursorAt: t.offsets[raw - 1]) {
                self.stepLeft($1, in: $0)
            }

        case .enterVisual:
            visualAnchor = t.offsets[cur]
            visualCursor = t.offsets[cur]
            return [.select(visualRange(t.offsets[cur], in: t))]

        case .exitVisual:
            visualAnchor = nil
            let new = t.clamp(t.index(at: visualCursor))
            return [.select(t.range(new, new))]

        case .deleteSelection, .yankSelection:
            guard let anchor = visualAnchor else { return [] }
            visualAnchor = nil
            let range = visualRange(anchor, in: t)
            let lo = t.index(at: range.location), hi = t.index(at: range.location + range.length)
            register = .charwise(t.string(lo, hi))
            guard command == .deleteSelection else { return [.select(t.range(lo, lo))] }
            return edit(buffer, .delete(range), cursorAt: range.location)
        }
    }

    private func visualRange(_ anchor: Int, in t: VimText) -> NSRange {
        let a = t.index(at: anchor), c = t.index(at: visualCursor)
        return t.range(min(a, c), min(max(a, c) + 1, t.count))
    }

    private func stepLeft(_ i: Int, in t: VimText) -> Int {
        i > t.lineStart(i) ? i - 1 : i
    }

    private func edit(
        _ buffer: VimBuffer, _ action: VimAction, cursorAt offset: Int,
        place: (VimText, Int) -> Int = { $0.clamp($1) }
    ) -> [VimAction] {
        var after = buffer
        after.apply(action)
        let t = VimText(after.text)
        let new = place(t, t.index(at: offset))
        return [action, .select(t.range(new, new))]
    }

    private func insert(_ insertion: VimInsertion, at cur: Int, in t: VimText, buffer: VimBuffer) -> [VimAction] {
        let new: Int
        switch insertion {
        case .before: new = cur
        case .after: new = cur < t.lineEnd(cur) ? cur + 1 : cur
        case .lineStart: new = t.firstNonBlank(cur, clamped: false)
        case .lineEnd: new = t.lineEnd(cur)
        case .lineBelow:
            let at = t.offsets[t.lineEnd(cur)]
            return edit(buffer, .insert("\n", at: at), cursorAt: at + 1) { $1 }
        case .lineAbove:
            let at = t.offsets[t.lineStart(cur)]
            return edit(buffer, .insert("\n", at: at), cursorAt: at) { $1 }
        }
        return [.select(t.range(new, new))]
    }

    // MARK: - motions

    private mutating func move(_ motion: VimMotion, from i: Int, in t: VimText, goal: (offset: Int, column: Int)?) -> Int {
        switch motion {
        case .left: return stepLeft(i, in: t)
        case .right: return i + 1 < t.lineEnd(i) ? i + 1 : i
        case .down, .up:
            let column = goal?.offset == t.offsets[i] ? goal!.column : i - t.lineStart(i)
            let new = vertical(motion == .down, from: i, column: column, in: t)
            self.goal = (t.offsets[new], column)
            return new
        case .wordForward: return wordForward(i, in: t)
        case .wordBackward: return wordBackward(i, in: t)
        case .wordEnd: return wordEnd(i, in: t)
        case .lineStart: return t.lineStart(i)
        case .firstNonBlank: return t.firstNonBlank(i)
        case .lineEnd:
            let new = t.lastChar(i)
            self.goal = (t.offsets[new], Int.max)
            return new
        case .firstLine: return t.firstNonBlank(0)
        case .lastLine: return t.firstNonBlank(t.count)
        }
    }

    private func vertical(_ down: Bool, from i: Int, column: Int, in t: VimText) -> Int {
        let start: Int
        if down {
            let end = t.lineEnd(i)
            guard end < t.count else { return i }
            start = end + 1
        } else {
            let lineStart = t.lineStart(i)
            guard lineStart > 0 else { return i }
            start = t.lineStart(lineStart - 1)
        }
        return start + min(column, t.lastChar(start) - start)
    }

    private enum CharClass { case blank, word, other }

    private func charClass(_ c: Character) -> CharClass {
        if c.isWhitespace { return .blank }
        return c.isLetter || c.isNumber || c == "_" ? .word : .other
    }

    private func wordForward(_ cur: Int, in t: VimText) -> Int {
        guard cur < t.count else { return cur }
        var i = cur
        let start = charClass(t.chars[i])
        if start != .blank {
            while i < t.count && charClass(t.chars[i]) == start { i += 1 }
        }
        while i < t.count && charClass(t.chars[i]) == .blank {
            let newline = t.chars[i] == "\n"
            i += 1
            if newline && (i == t.count || t.chars[i] == "\n") { return i }
        }
        return t.clamp(i)
    }

    private func wordBackward(_ cur: Int, in t: VimText) -> Int {
        guard cur > 0 else { return 0 }
        var i = cur - 1
        while i > 0 && charClass(t.chars[i]) == .blank {
            if t.chars[i] == "\n" && t.chars[i - 1] == "\n" { return i }
            i -= 1
        }
        let cls = charClass(t.chars[i])
        guard cls != .blank else { return i }
        while i > 0 && charClass(t.chars[i - 1]) == cls { i -= 1 }
        return i
    }

    private func wordEnd(_ cur: Int, in t: VimText) -> Int {
        var i = cur + 1
        while i < t.count && charClass(t.chars[i]) == .blank { i += 1 }
        guard i < t.count else { return cur }
        let cls = charClass(t.chars[i])
        while i + 1 < t.count && charClass(t.chars[i + 1]) == cls { i += 1 }
        return i
    }
}
