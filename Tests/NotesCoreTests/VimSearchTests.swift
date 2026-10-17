import Foundation
import Testing
@testable import NotesCore

private func find(_ h: inout Harness, _ pattern: String, forward: Bool = true) {
    h.buffer.apply(h.engine.execute(.search(pattern, forward: forward), on: h.buffer))
}

private func search(_ marked: String, _ pattern: String, forward: Bool = true) -> Harness {
    var h = Harness(marked)
    find(&h, pattern, forward: forward)
    return h
}

// AC1
@Test func searchFindsTheNextMatchAndWraps() {
    let text = "foo bar foo"
    #expect(vimSearch(in: text, pattern: "foo", from: 0, forward: true) == NSRange(location: 8, length: 3))
    #expect(vimSearch(in: text, pattern: "foo", from: 8, forward: true) == NSRange(location: 0, length: 3))
    #expect(vimSearch(in: text, pattern: "foo", from: 8, forward: false) == NSRange(location: 0, length: 3))
    #expect(vimSearch(in: text, pattern: "foo", from: 0, forward: false) == NSRange(location: 8, length: 3))
    #expect(vimSearch(in: text, pattern: "zzz", from: 0, forward: true) == nil)
    #expect(vimSearch(in: text, pattern: "", from: 0, forward: true) == nil)
}

// AC2
@Test func smartcase() {
    #expect(vimSearch(in: "a FOO", pattern: "foo", from: 0, forward: true) == NSRange(location: 2, length: 3))
    #expect(vimSearch(in: "a FOO foo", pattern: "Foo", from: 0, forward: true) == nil)
    #expect(vimSearch(in: "a FOO foo", pattern: "FOO", from: 4, forward: true) == NSRange(location: 2, length: 3))
}

// AC3
@Test func searchCommandSelectsNextAndPrevious() {
    #expect(search("|a foo b foo", "foo").marked == "a [foo] b foo")
    #expect(search("a foo b |foo", "foo", forward: false).marked == "a [foo] b foo")
}

// AC4
@Test func nAndShiftNRepeat() {
    var h = search("|a foo b foo c foo", "foo")
    h.type("n")
    #expect(h.marked == "a foo b [foo] c foo")
    h.type("n")
    #expect(h.marked == "a foo b foo c [foo]")
    h.type("n")
    #expect(h.marked == "a [foo] b foo c foo")
    h.type("N")
    #expect(h.marked == "a foo b foo c [foo]")

    var back = search("a foo b foo c |foo", "foo", forward: false)
    #expect(back.marked == "a foo b [foo] c foo")
    back.type("n")
    #expect(back.marked == "a [foo] b foo c foo")
}

// AC5
@Test func starAndHashSearchTheWordUnderTheCaret() {
    #expect(run("|foo bar foo", "*") == "foo bar [foo]")
    #expect(run("foo bar |foo", "#") == "[foo] bar foo")
    #expect(run("foo b|ar foo bar", "*") == "foo bar foo [bar]")
    var h = Harness("|foo x foo y foo")
    h.type("*n")
    #expect(h.marked == "foo x foo y [foo]")
}

// AC6
@Test func slashAndQuestionMarkAskForTheInput() {
    var h = Harness("a |foo b foo")
    #expect(h.press(VimKey("/")) == .consume(.promptSearch(forward: true)))
    #expect(h.press(VimKey("?")) == .consume(.promptSearch(forward: false)))
    #expect(h.mode == .normal)
    #expect(h.marked == "a |foo b foo")
    h.type("x")
    #expect(h.buffer.text == "a oo b foo")
}

@Test func emptyPatternRepeatsTheLastSearch() {
    var h = search("a |foo b foo", "fo")
    #expect(h.marked == "a foo b [fo]o")
    find(&h, "")
    #expect(h.marked == "a [fo]o b foo")
    var none = Harness("|a foo")
    find(&none, "")
    #expect(none.marked == "|a foo")
}

// AC7
@Test func searchNeverChangesTheText() {
    var h = search("|a foo b foo", "foo")
    h.type("n*#N")
    find(&h, "a")
    #expect(h.buffer.text == "a foo b foo")
}

// AC8
@Test func koreanPatternFindsKoreanText() {
    #expect(search("|가 나다 가", "나다").marked == "가 [나다] 가")
    #expect(search("|오늘 감사 합니다", "감사").marked == "오늘 [감사] 합니다")
}
