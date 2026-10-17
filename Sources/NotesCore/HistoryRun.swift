public let maxHistoryRun = 100

/// Merges neighbouring Undo (or Redo) commands into one counted command, capped at `maxHistoryRun`.
public func mergeHistory(_ commands: [VimCommand]) -> [VimCommand] {
    func parse(_ command: VimCommand) -> (kind: VimCommand, count: Int)? {
        switch command {
        case .undo, .redo: (command, 1)
        case .counted(.undo, let n): (.undo, n)
        case .counted(.redo, let n): (.redo, n)
        default: nil
        }
    }
    func make(_ kind: VimCommand, _ count: Int) -> VimCommand {
        count > 1 ? .counted(kind, count) : kind
    }
    var out: [VimCommand] = []
    var run: (kind: VimCommand, count: Int)?
    for command in commands {
        guard let next = parse(command) else {
            if let run { out.append(make(run.kind, run.count)) }
            run = nil
            out.append(command)
            continue
        }
        if let current = run, current.kind == next.kind {
            run = (current.kind, min(current.count + next.count, maxHistoryRun))
        } else {
            if let run { out.append(make(run.kind, run.count)) }
            run = (next.kind, min(next.count, maxHistoryRun))
        }
    }
    if let run { out.append(make(run.kind, run.count)) }
    return out
}

/// Presses up to `count` times, stopping when the menu item reports disabled; returns the presses made.
public func pressHistory(count: Int, isEnabled: () -> Bool, press: () -> Void) -> Int {
    var done = 0
    while done < count, isEnabled() {
        press()
        done += 1
    }
    return done
}

/// Undoes until `read` returns `target`, at most `limit` steps, stopping at once when a step changes nothing; returns the steps made.
public func undoUntil<T: Equatable>(
    isolation: isolated (any Actor)? = #isolation,
    target: T, limit: Int = maxHistoryRun, read: () -> T, undo: () async -> Void
) async -> Int {
    var steps = 0
    while steps < limit {
        let before = read()
        await undo()
        steps += 1
        let after = read()
        if after == before || after == target { break }
    }
    return steps
}

/// Remembers the text before the last insert session and the steps of the last grouped undo.
public struct HistoryGroups {
    public enum Plan: Equatable {
        case plain
        case undoUntil(String)
        case redo(Int)
    }

    private var textBeforeInsertSession: String?
    private var redoSteps: Int?

    public init() {}

    public mutating func record(_ command: VimCommand, text: String) {
        switch command {
        case .counted(.undo, _), .counted(.redo, _):
            textBeforeInsertSession = nil
        default:
            if command.startsInsert {
                textBeforeInsertSession = text
            } else if command.isChange {
                textBeforeInsertSession = nil
            }
        }
        if command.isChange { redoSteps = nil }
    }

    public mutating func plan(_ command: VimCommand) -> Plan {
        switch command {
        case .undo:
            guard let text = textBeforeInsertSession else { return .plain }
            textBeforeInsertSession = nil
            return .undoUntil(text)
        case .redo:
            guard let steps = redoSteps else { return .plain }
            redoSteps = nil
            return .redo(steps)
        default:
            return .plain
        }
    }

    public mutating func undone(steps: Int) { redoSteps = steps }
}
