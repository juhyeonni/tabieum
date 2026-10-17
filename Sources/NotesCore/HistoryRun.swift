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
