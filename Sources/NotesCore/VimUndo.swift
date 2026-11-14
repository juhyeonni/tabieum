import Foundation

/// One change to the note text: `removed` at `location` was replaced by `inserted`. UTF-16 units, as AX reports them.
/// It also keeps the text around the change and both lengths, to tell later whether a note is in the state it left.
public struct VimEdit: Equatable, Sendable {
    private static let context = 16

    public let location: Int
    public let removed: String
    public let inserted: String
    private let beforeLength: Int
    private let afterLength: Int
    private let prefix: [UInt16]
    private let suffix: [UInt16]

    /// The single replacement that turns `old` into `new`, found by trimming what both share at the start and the end.
    /// Nil when the texts are equal.
    public init?(from old: String, to new: String) {
        let before = Array(old.utf16), after = Array(new.utf16)
        guard before != after else { return nil }
        var start = 0
        while start < min(before.count, after.count), before[start] == after[start] { start += 1 }
        var end = 0
        let shortest = min(before.count, after.count)
        while end < shortest - start, before[before.count - 1 - end] == after[after.count - 1 - end] { end += 1 }
        if start > 0, UTF16.isLeadSurrogate(before[start - 1]) { start -= 1 }
        if end > 0, UTF16.isTrailSurrogate(before[before.count - end]) { end -= 1 }
        location = start
        removed = String(decoding: before[start ..< before.count - end], as: UTF16.self)
        inserted = String(decoding: after[start ..< after.count - end], as: UTF16.self)
        beforeLength = before.count
        afterLength = after.count
        prefix = Array(before[max(0, start - Self.context) ..< start])
        let suffixStart = before.count - end
        suffix = Array(before[suffixStart ..< min(before.count, suffixStart + Self.context)])
    }

    func actions(replacing old: String, with new: String) -> [VimAction] {
        var actions: [VimAction] = []
        if !old.isEmpty { actions.append(.delete(NSRange(location: location, length: old.utf16.count))) }
        if !new.isEmpty { actions.append(.insert(new, at: location)) }
        return actions + [.select(NSRange(location: location, length: 0))]
    }

    /// Whether `note` is the text this edit started from (`.before`) or left (`.after`).
    func matches(_ note: String, _ state: State) -> Bool {
        let units = Array(note.utf16)
        let middle = Array((state == .before ? removed : inserted).utf16)
        let tail = location + middle.count
        guard units.count == (state == .before ? beforeLength : afterLength),
              location >= prefix.count, tail + suffix.count <= units.count else { return false }
        return Array(units[location - prefix.count ..< location]) == prefix
            && Array(units[location ..< tail]) == middle
            && Array(units[tail ..< tail + suffix.count]) == suffix
    }

    enum State { case before, after }
}

/// Undo and redo of whole Vim commands, kept apart from Notes' own history, which merges a run of deletions.
/// Restored text comes back as plain text.
public struct VimUndoStack: Sendable {
    private static let limit = 500
    private var done: [VimEdit] = []
    private var undone: [VimEdit] = []

    public init() {}

    public mutating func record(_ edit: VimEdit) {
        done.append(edit)
        if done.count > Self.limit { done.removeFirst() }
        undone.removeAll()
    }

    /// The actions that take back the latest edit. Nil when there is none, or when `note` is no longer what that
    /// edit left: the note was changed from outside Vim, so the stack is dropped.
    public mutating func undo(on note: String) -> [VimAction]? {
        guard let edit = done.last else { return nil }
        guard edit.matches(note, .after) else { clear(); return nil }
        done.removeLast()
        undone.append(edit)
        return edit.actions(replacing: edit.inserted, with: edit.removed)
    }

    public mutating func redo(on note: String) -> [VimAction]? {
        guard let edit = undone.last else { return nil }
        guard edit.matches(note, .before) else { clear(); return nil }
        undone.removeLast()
        done.append(edit)
        return edit.actions(replacing: edit.removed, with: edit.inserted)
    }

    public mutating func clear() {
        done = []
        undone = []
    }
}

extension VimCommand {
    /// Undo or Redo with how many times, or nil for any other command.
    public var historyRun: (redo: Bool, count: Int)? {
        switch self {
        case .undo: (false, 1)
        case .redo: (true, 1)
        case .counted(.undo, let count): (false, count)
        case .counted(.redo, let count): (true, count)
        default: nil
        }
    }
}
