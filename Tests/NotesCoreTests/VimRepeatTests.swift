import Foundation
import Testing
@testable import NotesCore

// AC1 (#76)
@Test func dotRepeatsOperators() {
    #expect(run("|one two three", "dw.") == "|three")
    var h = Harness("|one two")
    h.type("ciwX")
    h.press(.escape)
    h.type("w.")
    #expect(h.marked == "X |X")
}

// AC2 (#76)
@Test func dotRepeatsInsert() {
    var h = Harness("ab|c\nde")
    h.type("A!")
    h.press(.escape)
    h.type("j.")
    #expect(h.marked == "abc!\nde|!")
    #expect(h.mode == .normal)
}

// AC3 (#76)
@Test func macrosRecordAndPlay() {
    #expect(run("|abcdefg", "qaxq") == "|bcdefg")
    #expect(run("|abcdefg", "qaxq@a") == "|cdefg")
    #expect(run("|abcdefg", "qaxq@a@@") == "|defg")
    #expect(run("|abcdefg", "qaxq2@a") == "|defg")
    #expect(run("|abcdefg", "qaxq@b") == "|bcdefg")
}

@Test func macrosReplayInsertedText() {
    var h = Harness("|a\nb")
    h.type("qaA!")
    h.press(.escape)
    h.type("jq0@a")
    #expect(h.marked == "a!\nb|!")
}

// AC4 (#76)
@Test func recordingRunsKeysOnceAndStopsOnQ() {
    var h = Harness("|abcd")
    h.type("qa")
    #expect(h.engine.isRecording)
    h.type("x")
    #expect(h.marked == "|bcd")
    h.type("q")
    #expect(!h.engine.isRecording)
    h.type("@a")
    #expect(h.marked == "|cd")
}

// AC5 (#76)
@Test func marksJump() {
    #expect(run("one |two three", "mawwb0'a") == "one |two three")
    #expect(run("one |two", "'a") == "one |two")
}

// AC6 (#76)
@Test func marksShiftWithVimEdits() {
    #expect(run("|one two three", "wwma0dw'a") == "two |three")
    #expect(run("|one two three", "wwma0x'a") == "ne two |three")
}
