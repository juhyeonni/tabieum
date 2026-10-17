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
