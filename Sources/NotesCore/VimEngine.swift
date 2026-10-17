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
    case normal, insert, visual, search
}

public struct VimFind: Equatable, Sendable {
    var char: Character
    var forward: Bool
    var till: Bool
}

public enum VimMotion: Equatable, Sendable {
    case left, right, down, up
    case wordForward, wordBackward, wordEnd
    case bigWordForward, bigWordBackward, bigWordEnd
    case lineStart, firstNonBlank, lineEnd
    case firstLine, lastLine
    case paragraphForward, paragraphBackward, matchBracket
    case screenTop, screenMiddle, screenBottom
    case halfPageDown, halfPageUp, pageDown, pageUp
    case find(VimFind)
    case repeatFind(reverse: Bool)

    init?(_ c: Character) {
        switch c {
        case "h": self = .left
        case "l": self = .right
        case "j": self = .down
        case "k": self = .up
        case "w": self = .wordForward
        case "b": self = .wordBackward
        case "e": self = .wordEnd
        case "W": self = .bigWordForward
        case "B": self = .bigWordBackward
        case "E": self = .bigWordEnd
        case "}": self = .paragraphForward
        case "{": self = .paragraphBackward
        case "%": self = .matchBracket
        case "H": self = .screenTop
        case "M": self = .screenMiddle
        case "L": self = .screenBottom
        case ";": self = .repeatFind(reverse: false)
        case ",": self = .repeatFind(reverse: true)
        case "0": self = .lineStart
        case "^": self = .firstNonBlank
        case "$": self = .lineEnd
        case "G": self = .lastLine
        default: return nil
        }
    }

    init?(control c: Character) {
        switch c {
        case "d": self = .halfPageDown
        case "u": self = .halfPageUp
        case "f": self = .pageDown
        case "b": self = .pageUp
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

public enum VimOperator: Equatable, Sendable {
    case delete, change, yank

    init?(_ c: Character) {
        switch c {
        case "d": self = .delete
        case "c": self = .change
        case "y": self = .yank
        default: return nil
        }
    }
}

public struct VimObject: Equatable, Sendable {
    var key: Character
    var around: Bool

    init?(_ key: Character, around: Bool) {
        guard "wp\"'()[]{}".contains(key) else { return nil }
        self.key = key
        self.around = around
    }
}

public indirect enum VimCommand: Equatable, Sendable {
    case none
    case motion(VimMotion)
    case counted(VimCommand, Int)
    case operate(VimOperator, VimMotion)
    case operateLines(VimOperator)
    case operateObject(VimOperator, VimObject)
    case selectObject(VimObject)
    case deleteChar, put, putBefore, join, toggleCase, undo, redo
    case replaceChar(Character)
    case insert(VimInsertion)
    case exitInsert(deletingJ: Bool)
    case enterVisual, exitVisual
    case deleteSelection, yankSelection
    case search(String, forward: Bool)
    case searchNext(reverse: Bool)
    case searchWord(forward: Bool)
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

    private var count: Int?
    private var opCount: Int?
    private var op: VimOperator?
    private var pending: Character?
    private var lastJ: TimeInterval?

    private enum Register: Sendable {
        case charwise(String), linewise(String)
    }
    private var register: Register?
    private var goal: (offset: Int, column: Int)?
    private var visualAnchor: Int?
    private var visualCursor = 0
    private var searchInput = ""
    private var searchForward = true
    private var lastSearch: (pattern: String, forward: Bool)?
    private var lastFind: VimFind?
    private var visible: NSRange?

    /// What the command line shows while a search pattern is typed.
    public var searchPrompt: String? {
        mode == .search ? (searchForward ? "/" : "?") + searchInput : nil
    }

    public init(mode: VimMode = .normal, jkEnabled: Bool = false) {
        self.mode = mode
        self.jkEnabled = jkEnabled
    }

    // MARK: - feed

    public mutating func feed(_ key: VimKey, at time: TimeInterval) -> VimDecision {
        switch mode {
        case .insert: feedInsert(key, at: time)
        case .search: feedSearch(key)
        default: feedCommand(key)
        }
    }

    private mutating func feedSearch(_ key: VimKey) -> VimDecision {
        if key.command { return .passThrough }
        if key.isEscape {
            mode = .normal
            searchInput = ""
            return .consume(.none)
        }
        guard key.isPlain else { return .consume(.none) }
        switch key.character {
        case "\n":
            let pattern = searchInput.isEmpty ? lastSearch?.pattern : searchInput
            mode = .normal
            searchInput = ""
            guard let pattern else { return .consume(.none) }
            lastSearch = (pattern, searchForward)
            return .consume(.search(pattern, forward: searchForward))
        case "\u{7F}":
            if searchInput.isEmpty { mode = .normal } else { searchInput.removeLast() }
        case let c where c.unicodeScalars.allSatisfy({ ![.control, .privateUse].contains($0.properties.generalCategory) }):
            searchInput.append(c)
        default:
            break
        }
        return .consume(.none)
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
        let busy = count != nil || op != nil || pending != nil
        let prefix = pending
        pending = nil
        if key.command { reset(); return .passThrough }
        if key.isEscape {
            reset()
            guard mode == .visual, !busy else { return .consume(.none) }
            mode = .normal
            return .consume(.exitVisual)
        }
        if key.control, key.character == "r", mode == .normal {
            reset()
            return .consume(.redo)
        }
        if key.control, let motion = VimMotion(control: key.character) {
            return .consume(op == nil ? finish(.motion(motion)) : cancel())
        }
        guard key.isPlain else { reset(); return .consume(.none) }
        let c = key.character
        if prefix == "r" { return .consume(c == "\n" ? cancel() : finish(.replaceChar(c))) }
        if prefix == "g" { return .consume(c == "g" ? motionOrOperate(.firstLine) : cancel()) }
        if let prefix, "ftFT".contains(prefix) {
            guard c != "\n" else { return .consume(cancel()) }
            let find = VimFind(char: c, forward: "ft".contains(prefix), till: "tT".contains(prefix))
            lastFind = find
            return .consume(motionOrOperate(.find(find)))
        }
        if let prefix, "ia".contains(prefix) {
            guard let object = VimObject(c, around: prefix == "a") else { return .consume(cancel()) }
            guard let op else { return .consume(finish(.selectObject(object))) }
            return .consume(operate(.operateObject(op, object)))
        }
        if let digit = c.isASCII ? c.wholeNumberValue : nil, digit > 0 || count != nil {
            count = min((count ?? 0) * 10 + digit, 9999)
            return .consume(.none)
        }
        if "ftFT".contains(c) { pending = c; return .consume(.none) }
        if c == "i" || c == "a", op != nil || mode == .visual { pending = c; return .consume(.none) }
        if let op {
            if VimOperator(c) == op { return .consume(operate(.operateLines(op))) }
            if c == "g" { pending = c; return .consume(.none) }
            guard let motion = VimMotion(c) else { return .consume(cancel()) }
            return .consume(motionOrOperate(motion))
        }
        if c == "g" { pending = c; return .consume(.none) }
        if let motion = VimMotion(c) { return .consume(finish(.motion(motion))) }
        if mode == .visual { reset() }
        return .consume(mode == .visual ? visualCommand(c) : normalCommand(c))
    }

    private mutating func reset() {
        count = nil
        opCount = nil
        op = nil
        pending = nil
    }

    private mutating func cancel() -> VimCommand {
        reset()
        return .none
    }

    private mutating func finish(_ command: VimCommand) -> VimCommand {
        let n = (opCount ?? 1) * (count ?? 1)
        reset()
        return n > 1 ? .counted(command, n) : command
    }

    private mutating func operate(_ command: VimCommand) -> VimCommand {
        if op == .change { mode = .insert }
        return finish(command)
    }

    private mutating func motionOrOperate(_ motion: VimMotion) -> VimCommand {
        guard let op else { return finish(.motion(motion)) }
        return operate(.operate(op, motion))
    }

    private mutating func normalCommand(_ c: Character) -> VimCommand {
        if let insertion = VimInsertion(c) {
            reset()
            mode = .insert
            return .insert(insertion)
        }
        if let operator_ = VimOperator(c) {
            opCount = count
            count = nil
            op = operator_
            return .none
        }
        switch c {
        case "r": pending = c; return .none
        case "x": return finish(.deleteChar)
        case "p": return finish(.put)
        case "P": return finish(.putBefore)
        case "J": return finish(.join)
        case "~": return finish(.toggleCase)
        case "D": return finish(.operate(.delete, .lineEnd))
        case "C": mode = .insert; return finish(.operate(.change, .lineEnd))
        case "u": reset(); return .undo
        case "/", "?":
            reset()
            mode = .search
            searchForward = c == "/"
            searchInput = ""
            return .none
        case "n", "N": reset(); return .searchNext(reverse: c == "N")
        case "*", "#": reset(); return .searchWord(forward: c == "*")
        case "v": reset(); mode = .visual; return .enterVisual
        default: reset(); return .none
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
        guard case .counted(let inner, let n) = command else { return run(command, 1, on: buffer) }
        return run(inner, n, on: buffer)
    }

    private mutating func run(_ command: VimCommand, _ n: Int, on buffer: VimBuffer) -> [VimAction] {
        let t = VimText(buffer.text)
        visible = buffer.visible
        let goal = self.goal
        self.goal = nil
        let raw = t.index(at: buffer.selection.location)
        let cur = t.clamp(raw)

        switch command {
        case .none:
            return []

        case .counted:
            return []

        case .motion(let motion):
            guard let anchor = visualAnchor else {
                let new = travel(motion, n, from: cur, in: t, goal: goal)
                return [.select(t.range(new, new))]
            }
            let new = travel(motion, n, from: t.clamp(t.index(at: visualCursor)), in: t, goal: goal)
            visualCursor = t.offsets[new]
            return [.select(visualRange(anchor, in: t))]

        case .deleteChar:
            let end = min(cur + n, t.lineEnd(cur))
            guard cur < end else { return [] }
            return remove(buffer, t, cur, end) { $0.clamp($1) }

        case .operateLines(let op):
            return lines(op, t.lineStart(cur), lastLineEnd(cur, n, in: t), buffer, t)

        case .operate(let op, let motion):
            guard let span = span(op, motion, n, from: cur, in: t) else {
                if op == .change { mode = .normal }
                return []
            }
            if span.linewise { return lines(op, span.lo, span.hi, buffer, t) }
            return characters(op, span.lo, span.hi, buffer, t)

        case .operateObject(let op, let object):
            guard let span = span(of: object, at: cur, in: t) else {
                if op == .change { mode = .normal }
                return []
            }
            if span.linewise { return lines(op, span.lo, span.hi, buffer, t) }
            return characters(op, span.lo, span.hi, buffer, t)

        case .selectObject(let object):
            guard visualAnchor != nil else { return [] }
            let at = t.clamp(t.index(at: visualCursor))
            guard let span = span(of: object, at: at, in: t), span.lo < span.hi else { return [] }
            visualAnchor = t.offsets[span.lo]
            visualCursor = t.offsets[span.hi - 1]
            return [.select(visualRange(visualAnchor!, in: t))]

        case .put, .putBefore:
            return put(before: command == .putBefore, n, at: cur, buffer, t)

        case .replaceChar(let char):
            let end = cur + n
            guard cur < t.lineEnd(cur), end <= t.lineEnd(cur) else { return [] }
            let range = t.range(cur, end)
            guard !buffer.deleteWouldHitBlockAttachment(range) else { return [] }
            let new = String(repeating: char, count: n)
            return edit(
                buffer, [.delete(range), .insert(new, at: range.location)],
                cursorAt: range.location + (n - 1) * String(char).utf16.count)

        case .toggleCase:
            let end = min(cur + n, t.lineEnd(cur))
            guard cur < end else { return [] }
            let original = t.string(cur, end)
            let toggled = original.map { $0.isUppercase ? $0.lowercased() : $0.uppercased() }.joined()
            let range = t.range(cur, end)
            guard toggled != original else { return [.select(t.range(t.clamp(end), t.clamp(end)))] }
            guard !buffer.deleteWouldHitBlockAttachment(range) else { return [] }
            return edit(
                buffer, [.delete(range), .insert(toggled, at: range.location)],
                cursorAt: range.location + toggled.utf16.count)

        case .join:
            let end = t.lineEnd(cur)
            guard end < t.count else { return [] }
            let nextEnd = t.lineEnd(end + 1)
            var next = end + 1
            while next < nextEnd && t.chars[next].isWhitespace { next += 1 }
            let wide = t.range(t.lineStart(cur), nextEnd)
            guard !buffer.deleteWouldHitBlockAttachment(wide) else { return [] }
            let space = next < nextEnd && end > t.lineStart(cur)
            let at = t.offsets[end]
            return edit(
                buffer, [.delete(t.range(end, next))] + (space ? [.insert(" ", at: at)] : []), cursorAt: at)

        case .redo:
            return [.redo]

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

        case .search(let pattern, let forward):
            return find(pattern, forward, from: cur, buffer, t)

        case .searchNext(let reverse):
            guard let last = lastSearch else { return [] }
            return find(last.pattern, last.forward != reverse, from: cur, buffer, t)

        case .searchWord(let forward):
            guard let word = wordUnder(cur, in: t) else { return [] }
            lastSearch = (word.text, forward)
            return find(word.text, forward, from: word.start, buffer, t)

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

    private func find(
        _ pattern: String, _ forward: Bool, from cur: Int, _ buffer: VimBuffer, _ t: VimText
    ) -> [VimAction] {
        guard let range = vimSearch(in: buffer.text, pattern: pattern, from: t.offsets[cur], forward: forward)
        else { return [] }
        return [.select(range)]
    }

    private func wordUnder(_ cur: Int, in t: VimText) -> (text: String, start: Int)? {
        let end = t.lineEnd(cur)
        var start = cur
        while start < end && charClass(t.chars[start]) != .word { start += 1 }
        guard start < end else { return nil }
        while start > t.lineStart(cur) && charClass(t.chars[start - 1]) == .word { start -= 1 }
        var stop = start
        while stop < end && charClass(t.chars[stop]) == .word { stop += 1 }
        return (t.string(start, stop), start)
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
        edit(buffer, [action], cursorAt: offset, place: place)
    }

    private func edit(
        _ buffer: VimBuffer, _ actions: [VimAction], cursorAt offset: Int,
        place: (VimText, Int) -> Int = { $0.clamp($1) }
    ) -> [VimAction] {
        var after = buffer
        after.apply(actions)
        let t = VimText(after.text)
        let new = place(t, t.index(at: offset))
        return actions + [.select(t.range(new, new))]
    }

    private mutating func remove(
        _ buffer: VimBuffer, _ t: VimText, _ lo: Int, _ hi: Int, place: (VimText, Int) -> Int
    ) -> [VimAction] {
        let range = t.range(lo, hi)
        guard !buffer.deleteWouldHitBlockAttachment(range) else { return [] }
        register = .charwise(t.string(lo, hi))
        return edit(buffer, .delete(range), cursorAt: t.offsets[lo], place: place)
    }

    private mutating func characters(
        _ op: VimOperator, _ lo: Int, _ hi: Int, _ buffer: VimBuffer, _ t: VimText
    ) -> [VimAction] {
        let caret = [VimAction.select(t.range(lo, lo))]
        guard lo < hi else { return op == .change ? caret : [] }
        switch op {
        case .yank:
            register = .charwise(t.string(lo, hi))
            return caret
        case .delete:
            return remove(buffer, t, lo, hi) { $1 }
        case .change:
            let actions = remove(buffer, t, lo, hi) { $1 }
            if actions.isEmpty { mode = .normal }
            return actions
        }
    }

    private mutating func lines(
        _ op: VimOperator, _ start: Int, _ end: Int, _ buffer: VimBuffer, _ t: VimText
    ) -> [VimAction] {
        if op == .yank {
            register = .linewise(t.string(start, end))
            return []
        }
        let whole = op == .change
        let range = whole ? t.range(start, end)
            : end < t.count ? t.range(start, end + 1)
            : start > 0 ? t.range(start - 1, end)
            : t.range(start, end)
        guard !buffer.deleteWouldHitBlockAttachment(range) else {
            if whole { mode = .normal }
            return []
        }
        register = .linewise(t.string(start, end))
        guard range.length > 0 else { return whole ? [.select(t.range(start, start))] : [] }
        return whole
            ? edit(buffer, .delete(range), cursorAt: range.location) { $1 }
            : edit(buffer, .delete(range), cursorAt: range.location) { $0.firstNonBlank($1) }
    }

    private func lastLineEnd(_ cur: Int, _ n: Int, in t: VimText) -> Int {
        var end = t.lineEnd(cur)
        for _ in 1..<max(n, 1) {
            guard end < t.count else { break }
            end = t.lineEnd(end + 1)
        }
        return end
    }

    private func put(before: Bool, _ n: Int, at cur: Int, _ buffer: VimBuffer, _ t: VimText) -> [VimAction] {
        switch register {
        case .charwise(let s) where !s.isEmpty:
            let text = String(repeating: s, count: n)
            let at = t.offsets[before || cur >= t.lineEnd(cur) ? cur : cur + 1]
            return edit(buffer, .insert(text, at: at), cursorAt: at + String(text.dropLast()).utf16.count)
        case .linewise(let s):
            let body = Array(repeating: s, count: n).joined(separator: "\n")
            if before {
                let at = t.offsets[t.lineStart(cur)]
                return edit(buffer, .insert(body + "\n", at: at), cursorAt: at) { $0.firstNonBlank($1) }
            }
            let at = t.offsets[t.lineEnd(cur)]
            return edit(buffer, .insert("\n" + body, at: at), cursorAt: at + 1) { $0.firstNonBlank($1) }
        default:
            return []
        }
    }

    private func span(
        _ op: VimOperator, _ motion: VimMotion, _ n: Int, from cur: Int, in t: VimText
    ) -> (lo: Int, hi: Int, linewise: Bool)? {
        let lineEnd = t.lineEnd(cur)
        switch motion {
        case .left: return (max(cur - n, t.lineStart(cur)), cur, false)
        case .right: return (cur, min(cur + n, lineEnd), false)
        case .wordForward, .bigWordForward:
            let big = motion == .bigWordForward
            if op == .change, cur < t.count, charClass(t.chars[cur], big) != .blank {
                let cls = charClass(t.chars[cur], big)
                var e = cur
                while e + 1 < t.count && charClass(t.chars[e + 1], big) == cls { e += 1 }
                for _ in 1..<n { e = wordEnd(e, in: t, big) }
                return (cur, e + 1, false)
            }
            var i = cur, last = cur
            for _ in 0..<n {
                last = i
                let next = wordForward(i, in: t, clamped: false, big: big)
                guard next != i else { break }
                i = next
            }
            return (cur, min(i, t.lineEnd(last)), false)
        case .wordBackward, .bigWordBackward:
            var i = cur
            for _ in 0..<n { i = wordBackward(i, in: t, motion == .bigWordBackward) }
            return (i, cur, false)
        case .wordEnd, .bigWordEnd:
            var i = cur
            for _ in 0..<n { i = wordEnd(i, in: t, motion == .bigWordEnd) }
            return (cur, min(i + 1, t.count), false)
        case .paragraphForward:
            var i = cur
            for _ in 0..<n { i = paragraph(forward: true, from: i, in: t) }
            return (cur, i, false)
        case .paragraphBackward:
            var i = cur
            for _ in 0..<n { i = paragraph(forward: false, from: i, in: t) }
            return (i, cur, false)
        case .matchBracket:
            guard let m = matchBracket(cur, in: t) else { return nil }
            return (min(cur, m.match), max(m.bracket, m.match) + 1, false)
        case .find, .repeatFind:
            guard let hit = findTarget(motion, n, from: cur, in: t) else { return nil }
            return hit.find.forward ? (cur, hit.target + 1, false) : (hit.target, cur, false)
        case .screenTop, .screenMiddle, .screenBottom:
            let target = screenLine(motion, t)
            return (min(t.lineStart(cur), target), max(lineEnd, t.lineEnd(target)), true)
        case .halfPageDown, .halfPageUp, .pageDown, .pageUp: return nil
        case .lineStart: return (t.lineStart(cur), cur, false)
        case .firstNonBlank:
            let f = t.firstNonBlank(cur, clamped: false)
            return (min(f, cur), max(f, cur), false)
        case .lineEnd: return (cur, lineEnd, false)
        case .down:
            let end = lastLineEnd(cur, n + 1, in: t)
            return end == lineEnd ? nil : (t.lineStart(cur), end, true)
        case .up:
            var start = t.lineStart(cur)
            for _ in 0..<n {
                guard start > 0 else { break }
                start = t.lineStart(start - 1)
            }
            return start == t.lineStart(cur) ? nil : (start, lineEnd, true)
        case .firstLine: return (0, lineEnd, true)
        case .lastLine: return (t.lineStart(cur), t.count, true)
        }
    }

    private func span(of object: VimObject, at cur: Int, in t: VimText) -> (lo: Int, hi: Int, linewise: Bool)? {
        guard cur < t.count else { return nil }
        let key = object.key
        switch key {
        case "w": return wordObject(around: object.around, at: cur, in: t).map { ($0, $1, false) }
        case "p": return paragraphObject(around: object.around, at: cur, in: t).map { ($0, $1, true) }
        case "\"", "'": return quoteObject(key, around: object.around, at: cur, in: t).map { ($0, $1, false) }
        default: return bracketObject(key, around: object.around, at: cur, in: t).map { ($0, $1, false) }
        }
    }

    private func wordObject(around: Bool, at cur: Int, in t: VimText) -> (Int, Int)? {
        let start = t.lineStart(cur), end = t.lineEnd(cur)
        guard cur < end else { return nil }
        func run(_ i: Int) -> (Int, Int) {
            let cls = charClass(t.chars[i])
            var lo = i, hi = i + 1
            while lo > start && charClass(t.chars[lo - 1]) == cls { lo -= 1 }
            while hi < end && charClass(t.chars[hi]) == cls { hi += 1 }
            return (lo, hi)
        }
        var (lo, hi) = run(cur)
        guard around else { return (lo, hi) }
        if hi < end {
            hi = run(hi).1
        } else if lo > start, charClass(t.chars[cur]) != .blank {
            lo = run(lo - 1).0
        }
        return (lo, hi)
    }

    private func paragraphObject(around: Bool, at cur: Int, in t: VimText) -> (Int, Int)? {
        func blank(_ i: Int) -> Bool { t.lineStart(i) == t.lineEnd(i) }
        func run(_ i: Int) -> (Int, Int) {
            let isBlank = blank(i)
            var lo = t.lineStart(i), hi = t.lineEnd(i)
            while lo > 0 && blank(lo - 1) == isBlank { lo = t.lineStart(lo - 1) }
            while hi < t.count && blank(hi + 1) == isBlank { hi = t.lineEnd(hi + 1) }
            return (lo, hi)
        }
        var (lo, hi) = run(cur)
        guard around else { return (lo, hi) }
        if hi < t.count {
            hi = run(hi + 1).1
        } else if lo > 0 {
            lo = run(lo - 1).0
        }
        return (lo, hi)
    }

    private func quoteObject(_ quote: Character, around: Bool, at cur: Int, in t: VimText) -> (Int, Int)? {
        let marks = (t.lineStart(cur)..<t.lineEnd(cur)).filter { t.chars[$0] == quote }
        for k in stride(from: 0, to: marks.count - 1, by: 2) where marks[k] <= cur && cur <= marks[k + 1] {
            return around ? (marks[k], marks[k + 1] + 1) : (marks[k] + 1, marks[k + 1])
        }
        return nil
    }

    private func bracketObject(_ bracket: Character, around: Bool, at cur: Int, in t: VimText) -> (Int, Int)? {
        let pairs: [(Character, Character)] = [("(", ")"), ("[", "]"), ("{", "}")]
        guard let (o, c) = pairs.first(where: { $0.0 == bracket || $0.1 == bracket }) else { return nil }
        var open = t.chars[cur] == o ? cur : nil
        var depth = 0, j = cur - 1
        while open == nil && j >= 0 {
            if t.chars[j] == c { depth += 1 }
            if t.chars[j] == o {
                if depth == 0 { open = j }
                depth -= 1
            }
            j -= 1
        }
        guard let open else { return nil }
        depth = 0
        for close in open..<t.count {
            if t.chars[close] == o { depth += 1 }
            if t.chars[close] == c { depth -= 1 }
            if depth == 0 { return around ? (open, close + 1) : (open + 1, close) }
        }
        return nil
    }

    private mutating func travel(
        _ motion: VimMotion, _ n: Int, from start: Int, in t: VimText, goal: (offset: Int, column: Int)?
    ) -> Int {
        if let hit = findTarget(motion, n, from: start, in: t) { return hit.target }
        var pos = start, goal = goal
        for _ in 0..<n {
            let new = move(motion, from: pos, in: t, goal: goal)
            goal = self.goal
            guard new != pos else { break }
            pos = new
        }
        return pos
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
        case .down, .up, .halfPageDown, .halfPageUp, .pageDown, .pageUp:
            let column = goal?.offset == t.offsets[i] ? goal!.column : i - t.lineStart(i)
            let pageLines = visibleLineStarts(t).count
            let (down, lines) = switch motion {
            case .halfPageDown: (true, max(pageLines / 2, 1))
            case .halfPageUp: (false, max(pageLines / 2, 1))
            case .pageDown: (true, max(pageLines, 1))
            case .pageUp: (false, max(pageLines, 1))
            default: (motion == .down, 1)
            }
            var new = i
            for _ in 0..<lines { new = vertical(down, from: new, column: column, in: t) }
            self.goal = (t.offsets[new], column)
            return new
        case .wordForward, .bigWordForward: return wordForward(i, in: t, big: motion == .bigWordForward)
        case .wordBackward, .bigWordBackward: return wordBackward(i, in: t, motion == .bigWordBackward)
        case .wordEnd, .bigWordEnd: return wordEnd(i, in: t, motion == .bigWordEnd)
        case .paragraphForward: return t.clamp(paragraph(forward: true, from: i, in: t))
        case .paragraphBackward: return paragraph(forward: false, from: i, in: t)
        case .matchBracket: return matchBracket(i, in: t)?.match ?? i
        case .screenTop, .screenMiddle, .screenBottom: return t.firstNonBlank(screenLine(motion, t))
        case .find, .repeatFind: return i
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

    /// Line starts of the lines in view, or of every line when the editor does not say.
    private func visibleLineStarts(_ t: VimText) -> [Int] {
        var first = 0, last = t.count
        if let visible {
            first = t.lineStart(t.index(at: visible.location))
            last = t.index(at: max(NSMaxRange(visible) - 1, visible.location))
        }
        var starts = [first]
        var end = t.lineEnd(first)
        while end < last && end < t.count {
            starts.append(end + 1)
            end = t.lineEnd(end + 1)
        }
        return starts
    }

    private func screenLine(_ motion: VimMotion, _ t: VimText) -> Int {
        let starts = visibleLineStarts(t)
        switch motion {
        case .screenTop: return starts[0]
        case .screenMiddle: return starts[(starts.count - 1) / 2]
        default: return starts[starts.count - 1]
        }
    }

    /// The start of the next blank line, or the end of the text; backwards, the previous one or the start.
    private func paragraph(forward: Bool, from cur: Int, in t: VimText) -> Int {
        func blank(_ i: Int) -> Bool { t.lineStart(i) == t.lineEnd(i) }
        func neighbour(_ i: Int) -> Int? {
            if forward {
                let end = t.lineEnd(i)
                return end < t.count ? end + 1 : nil
            }
            let start = t.lineStart(i)
            return start > 0 ? t.lineStart(start - 1) : nil
        }
        var i = t.lineStart(cur)
        while blank(i), let next = neighbour(i) { i = next }
        while !blank(i) {
            guard let next = neighbour(i) else { return forward ? t.count : 0 }
            i = next
        }
        return i
    }

    /// The bracket at or after `cur` on its line and the one it pairs with, across lines.
    private func matchBracket(_ cur: Int, in t: VimText) -> (bracket: Int, match: Int)? {
        let opens: [Character] = ["(", "[", "{"], closes: [Character] = [")", "]", "}"]
        var i = cur
        let end = t.lineEnd(cur)
        while i < end && !opens.contains(t.chars[i]) && !closes.contains(t.chars[i]) { i += 1 }
        guard i < end else { return nil }
        let forward = opens.contains(t.chars[i])
        let k = (forward ? opens.firstIndex(of: t.chars[i]) : closes.firstIndex(of: t.chars[i]))!
        let (same, other) = forward ? (opens[k], closes[k]) : (closes[k], opens[k])
        var depth = 0, j = i
        while j >= 0 && j < t.count {
            if t.chars[j] == same { depth += 1 }
            if t.chars[j] == other { depth -= 1 }
            if depth == 0 { return (i, j) }
            j += forward ? 1 : -1
        }
        return nil
    }

    /// Where `f`, `t`, `F`, `T` (or `;` and `,`) land, on the caret's line only.
    private func findTarget(_ motion: VimMotion, _ n: Int, from cur: Int, in t: VimText) -> (find: VimFind, target: Int)? {
        var find: VimFind
        var repeating = false
        switch motion {
        case .find(let f): find = f
        case .repeatFind(let reverse):
            guard let last = lastFind else { return nil }
            find = last
            if reverse { find.forward.toggle() }
            repeating = true
        default: return nil
        }
        let step = find.forward ? 1 : -1
        let start = t.lineStart(cur), end = t.lineEnd(cur)
        var i = cur
        for k in 0..<n {
            var j = i + step
            if k == 0 && repeating && find.till { j += step }
            while j >= start && j < end && t.chars[j] != find.char { j += step }
            guard j >= start && j < end else { return nil }
            i = j
        }
        return (find, find.till ? i - step : i)
    }

    private enum CharClass { case blank, word, other }

    private func charClass(_ c: Character, _ big: Bool = false) -> CharClass {
        if c.isWhitespace { return .blank }
        if big { return .word }
        return c.isLetter || c.isNumber || c == "_" ? .word : .other
    }

    private func wordForward(_ cur: Int, in t: VimText, clamped: Bool = true, big: Bool = false) -> Int {
        guard cur < t.count else { return cur }
        var i = cur
        let start = charClass(t.chars[i], big)
        if start != .blank {
            while i < t.count && charClass(t.chars[i], big) == start { i += 1 }
        }
        while i < t.count && charClass(t.chars[i], big) == .blank {
            let newline = t.chars[i] == "\n"
            i += 1
            if newline && (i == t.count || t.chars[i] == "\n") { return i }
        }
        return clamped ? t.clamp(i) : i
    }

    private func wordBackward(_ cur: Int, in t: VimText, _ big: Bool = false) -> Int {
        guard cur > 0 else { return 0 }
        var i = cur - 1
        while i > 0 && charClass(t.chars[i], big) == .blank {
            if t.chars[i] == "\n" && t.chars[i - 1] == "\n" { return i }
            i -= 1
        }
        let cls = charClass(t.chars[i], big)
        guard cls != .blank else { return i }
        while i > 0 && charClass(t.chars[i - 1], big) == cls { i -= 1 }
        return i
    }

    private func wordEnd(_ cur: Int, in t: VimText, _ big: Bool = false) -> Int {
        var i = cur + 1
        while i < t.count && charClass(t.chars[i], big) == .blank { i += 1 }
        guard i < t.count else { return cur }
        let cls = charClass(t.chars[i], big)
        while i + 1 < t.count && charClass(t.chars[i + 1], big) == cls { i += 1 }
        return i
    }
}

/// The next match of `pattern` after UTF-16 offset `offset` (before it, backwards), wrapping at the ends.
/// Plain text; case-insensitive unless the pattern has an uppercase letter.
public func vimSearch(in text: String, pattern: String, from offset: Int, forward: Bool) -> NSRange? {
    guard !pattern.isEmpty else { return nil }
    let ns = text as NSString
    let options: NSString.CompareOptions = pattern.contains(where: \.isUppercase) ? [] : [.caseInsensitive]
    let all = NSRange(location: 0, length: ns.length)
    func find(_ options: NSString.CompareOptions, in range: NSRange) -> NSRange? {
        guard range.length > 0 else { return nil }
        let found = ns.range(of: pattern, options: options, range: range)
        return found.location == NSNotFound ? nil : found
    }
    if forward {
        let start = min(offset + 1, ns.length)
        return find(options, in: NSRange(location: start, length: ns.length - start)) ?? find(options, in: all)
    }
    let end = min(max(offset - 1 + pattern.utf16.count, 0), ns.length)
    return find(options.union(.backwards), in: NSRange(location: 0, length: end))
        ?? find(options.union(.backwards), in: all)
}
