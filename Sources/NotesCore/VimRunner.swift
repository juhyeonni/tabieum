import Foundation

/// The live note, read and written from the runner's background queue. Calls may block.
public protocol VimAXSource: Sendable {
    func buffer() -> VimBuffer?
    /// False when the action could not be applied; the rest of its command is dropped.
    func perform(_ action: VimAction) -> Bool
}

/// Feeds keys to the engine and runs the resulting commands on a serial background queue, in key order.
/// A command reads the note when it starts, and identical motions still waiting are merged into one move.
public final class VimRunner: @unchecked Sendable {
    private let ax: VimAXSource
    private let onApplied: @Sendable (UInt64) -> Void
    private let onIdle: @Sendable () -> Void
    private let executor = DispatchQueue(label: "vim-runner")
    private let lock = NSLock()
    private var engine: VimEngine
    private var queue: [(command: VimCommand, start: UInt64)] = []
    private var draining = false

    /// `onApplied` gets the `start` of each queued command once it is applied; `onIdle` runs when the queue empties.
    public init(
        engine: VimEngine, ax: VimAXSource,
        onApplied: @escaping @Sendable (UInt64) -> Void = { _ in },
        onIdle: @escaping @Sendable () -> Void = {}
    ) {
        self.engine = engine
        self.ax = ax
        self.onApplied = onApplied
        self.onIdle = onIdle
    }

    public var mode: VimMode { locked { $0.mode } }

    public var jkEnabled: Bool {
        get { locked { $0.jkEnabled } }
        set { locked { $0.jkEnabled = newValue } }
    }

    public func feed(_ key: VimKey, at time: TimeInterval) -> VimDecision {
        locked { $0.feed(key, at: time) }
    }

    public func enqueue(_ command: VimCommand, start: UInt64) {
        lock.lock()
        queue.append((command, start))
        let wasDraining = draining
        draining = true
        lock.unlock()
        if !wasDraining { executor.async { self.drain() } }
    }

    public func clear() {
        lock.lock()
        queue = []
        lock.unlock()
    }

    /// Returns once everything queued so far has run.
    public func flush() {
        executor.sync {}
    }

    private func locked<T>(_ body: (inout VimEngine) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&engine)
    }

    private func drain() {
        while let (command, starts) = next() {
            run(command, count: starts.count)
            starts.forEach(onApplied)
        }
        onIdle()
    }

    private func next() -> (VimCommand, [UInt64])? {
        lock.lock()
        defer { lock.unlock() }
        guard !queue.isEmpty else {
            draining = false
            return nil
        }
        let first = queue.removeFirst()
        var starts = [first.start]
        if case .motion = first.command {
            while queue.first?.command == first.command { starts.append(queue.removeFirst().start) }
        }
        return (first.command, starts)
    }

    private func run(_ command: VimCommand, count: Int) {
        guard var buffer = ax.buffer() else { return }
        var actions: [VimAction] = []
        for _ in 0..<count {
            actions = locked { $0.execute(command, on: buffer) }
            buffer.apply(actions)
        }
        for action in actions where !ax.perform(action) { return }
    }
}
