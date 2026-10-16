import Foundation
import Testing
@testable import NotesCore

final class FakeAX: VimAXSource, @unchecked Sendable {
    private let lock = NSLock()
    private var content: VimBuffer
    private var performed: [VimAction] = []
    var delay: TimeInterval = 0
    private var gate: DispatchSemaphore?
    var failSelect = false
    var onPerform: ((VimAction) -> Void)?

    init(_ text: String, caret: Int = 0) {
        content = VimBuffer(text: text, selection: NSRange(location: caret, length: 0))
    }

    var current: VimBuffer { lock.withLock { content } }
    var actions: [VimAction] { lock.withLock { performed } }

    func setText(_ text: String) { lock.withLock { content.text = text } }

    /// The next `buffer()` call blocks until the returned semaphore is signalled.
    func holdNextRead() -> DispatchSemaphore {
        let semaphore = DispatchSemaphore(value: 0)
        lock.withLock { gate = semaphore }
        return semaphore
    }

    func buffer() -> VimBuffer? {
        let held = lock.withLock { () -> DispatchSemaphore? in defer { gate = nil }; return gate }
        held?.wait()
        Thread.sleep(forTimeInterval: delay)
        return current
    }

    func perform(_ action: VimAction) -> Bool {
        Thread.sleep(forTimeInterval: delay)
        onPerform?(action)
        return lock.withLock {
            performed.append(action)
            if failSelect, case .select = action { return false }
            content.apply(action)
            return true
        }
    }
}

private final class Applied: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [UInt64] = []
    func add(_ start: UInt64) { lock.withLock { starts.append(start) } }
    var values: [UInt64] { lock.withLock { starts } }
}

private func runner(_ ax: FakeAX) -> VimRunner {
    VimRunner(engine: VimEngine(), ax: ax)
}

private func isSelect(_ action: VimAction) -> Bool {
    if case .select = action { return true }
    return false
}

// AC1
@Test func enqueueReturnsWithoutWaitingForAX() {
    let ax = FakeAX("a\nb\nc\n")
    ax.delay = 0.1
    let runner = runner(ax)
    let began = Date()
    for _ in 0..<10 { runner.enqueue(.deleteChar, start: 0) }
    #expect(Date().timeIntervalSince(began) < 0.05)
    runner.flush()
}

// AC2
@Test func commandsRunInQueueOrder() {
    let ax = FakeAX("abcdef")
    let runner = runner(ax)
    runner.enqueue(.motion(.right), start: 0)
    runner.enqueue(.deleteChar, start: 1)
    runner.enqueue(.undo, start: 2)
    runner.flush()
    #expect(ax.actions == [.select(NSRange(location: 1, length: 0)), .delete(NSRange(location: 1, length: 1)),
                           .select(NSRange(location: 1, length: 0)), .undo])
}

// AC3
@Test func commandReadsNoteWhenItStarts() {
    let ax = FakeAX("abc")
    ax.onPerform = { [unowned ax] action in
        if action == .undo { ax.setText("xyz123") }
    }
    let runner = runner(ax)
    runner.enqueue(.undo, start: 0)
    runner.enqueue(.motion(.lineEnd), start: 1)
    runner.flush()
    #expect(ax.current.selection == NSRange(location: 5, length: 0))
}

// AC4
@Test func queuedIdenticalMotionsMergeIntoOneMove() {
    let text = "one\ntwo\nthree\nfour\nfive\n"
    let ax = FakeAX(text)
    let release = ax.holdNextRead()
    let runner = runner(ax)
    runner.enqueue(.undo, start: 0)
    for i in 1...3 { runner.enqueue(.motion(.down), start: UInt64(i)) }
    release.signal()
    runner.flush()
    #expect(ax.actions.filter(isSelect).count == 1)

    var engine = VimEngine()
    var buffer = VimBuffer(text: text)
    for _ in 0..<3 { buffer.apply(engine.execute(.motion(.down), on: buffer)) }
    #expect(ax.current.selection == buffer.selection)
}

@Test func mergedCommandsAllReportApplied() {
    let ax = FakeAX("a\nb\nc\n")
    let applied = Applied()
    let runner = VimRunner(engine: VimEngine(), ax: ax, onApplied: { applied.add($0) })
    let release = ax.holdNextRead()
    runner.enqueue(.undo, start: 0)
    runner.enqueue(.motion(.down), start: 1)
    runner.enqueue(.motion(.down), start: 2)
    release.signal()
    runner.flush()
    #expect(applied.values == [0, 1, 2])
}

// AC5
@Test func editsAreNeverMerged() {
    let ax = FakeAX("abcdef")
    let release = ax.holdNextRead()
    let runner = runner(ax)
    runner.enqueue(.undo, start: 0)
    for i in 1...3 { runner.enqueue(.deleteChar, start: UInt64(i)) }
    release.signal()
    runner.flush()
    #expect(ax.actions.filter { if case .delete = $0 { true } else { false } }.count == 3)
    #expect(ax.current.text == "def")
}

// AC6
@Test func failedActionDropsTheRestOfItsCommand() {
    let ax = FakeAX("abc")
    ax.failSelect = true
    let runner = runner(ax)
    runner.enqueue(.deleteChar, start: 0)
    runner.enqueue(.motion(.right), start: 1)
    runner.flush()
    #expect(ax.actions == [.delete(NSRange(location: 0, length: 1)), .select(NSRange(location: 0, length: 0)),
                           .select(NSRange(location: 1, length: 0))])
    #expect(ax.current.text == "bc")
}
