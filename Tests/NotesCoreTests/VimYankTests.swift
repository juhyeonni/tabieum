import Foundation
import Testing
@testable import NotesCore

private func yanks(_ marked: String, _ keys: String) -> [String] {
    var h = Harness(marked)
    h.type(keys)
    return h.engine.takeYanks()
}

@Test func linewiseYanksEndWithANewline() {
    #expect(yanks("a|bc\ndef", "yy") == ["abc\n"])
    #expect(yanks("|one\ntwo\nthree\nfour", "3yy") == ["one\ntwo\nthree\n"])
    #expect(yanks("|one\ntwo\nthree\nfour", "Vjjy") == ["one\ntwo\nthree\n"])
}

@Test func charwiseYanksAreExactlyTheYankedText() {
    #expect(yanks("|foo bar", "yw") == ["foo "])
    #expect(yanks("|foo bar", "vly") == ["fo"])
    #expect(yanks("f|oo bar", "yiw") == ["foo"])
}

@Test func deletesAndChangesAreNotYanks() {
    #expect(yanks("|one\ntwo", "dd").isEmpty)
    #expect(yanks("|one", "x").isEmpty)
    #expect(yanks("|one two", "cw").isEmpty)
    #expect(yanks("|one two", "vld").isEmpty)
}

@Test func eachYankInAMacroIsReported() {
    var h = Harness("|one\ntwo")
    h.type("qayyjywq")
    #expect(h.engine.takeYanks() == ["one\n", "two"])
    h.type("k@a")
    #expect(h.engine.takeYanks() == ["one\n", "two"])
    #expect(h.engine.takeYanks().isEmpty)
}
