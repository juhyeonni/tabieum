import Testing
@testable import NotesCore

// AC1
@Test func neighbouringUndosMerge() {
    let merged = mergeHistory([.undo, .undo, .undo, .redo, .redo, .deleteChar, .undo])
    #expect(merged == [.counted(.undo, 3), .counted(.redo, 2), .deleteChar, .undo])
}

@Test func countedUndoJoinsTheRun() {
    #expect(mergeHistory([.counted(.undo, 3), .undo]) == [.counted(.undo, 4)])
}

// AC2
@Test func mergedCountIsCapped() {
    let merged = mergeHistory(Array(repeating: .undo, count: 250))
    #expect(merged == [.counted(.undo, 100)])
}

// AC3
@Test func pressingStopsWhenDisabled() {
    var left = 3, presses = 0
    let done = pressHistory(count: 10, isEnabled: { left > 0 }, press: { left -= 1; presses += 1 })
    #expect(done == 3)
    #expect(presses == 3)
}

private final class FakeNotes {
    var text: String
    init(_ text: String) { self.text = text }
    func undo() { _ = text.popLast() }
}

// #110 AC1
@Test func undoRepeatsUntilTheTextMatches() async {
    let notes = FakeNotes("abcdef")
    let steps = await undoUntil(target: "abc", read: { notes.text }, undo: { notes.undo() })
    #expect(steps == 3)
    #expect(notes.text == "abc")
}

// #110 AC2
@Test func undoStopsAtTheLimit() async {
    let notes = FakeNotes(String(repeating: "a", count: 300))
    let steps = await undoUntil(target: "never", read: { notes.text }, undo: { notes.undo() })
    #expect(steps == 100)
}

@Test func undoStopsWhenAStepChangesNothing() async {
    var calls = 0
    let steps = await undoUntil(target: "x", read: { "abc" }, undo: { calls += 1 })
    #expect(steps == 1)
    #expect(calls == 1)
}

// #110 AC3
@Test func onlyInsertCommandsStartASession() {
    #expect(!VimCommand.deleteChar.startsInsert)
    #expect(!VimCommand.operate(.delete, .wordForward).startsInsert)
    #expect(VimCommand.operate(.change, .wordForward).startsInsert)
    #expect(VimCommand.insert(.before).startsInsert)
}

// #110 AC4
@Test func redoReplaysTheStepsOfTheGroupedUndo() {
    var presses = 0
    let done = pressHistory(count: 3, isEnabled: { true }, press: { presses += 1 })
    #expect(done == 3 && presses == 3)
}
