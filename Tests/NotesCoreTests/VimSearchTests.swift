import Foundation
import Testing
@testable import NotesCore

private let enter = VimKey("\n")
private let backspace = VimKey("\u{7F}")

private func search(_ marked: String, _ keys: String) -> Harness {
    var h = Harness(marked)
    h.type(keys)
    h.press(enter)
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
@Test func slashSelectsNextAndQuestionMarkPrevious() {
    #expect(search("|a foo b foo", "/foo").marked == "a [foo] b foo")
    #expect(search("a foo b |foo", "?foo").marked == "a [foo] b foo")
}

// AC4
@Test func nAndShiftNRepeat() {
    var h = search("|a foo b foo c foo", "/foo")
    h.type("n")
    #expect(h.marked == "a foo b [foo] c foo")
    h.type("n")
    #expect(h.marked == "a foo b foo c [foo]")
    h.type("n")
    #expect(h.marked == "a [foo] b foo c foo")
    h.type("N")
    #expect(h.marked == "a foo b foo c [foo]")

    var back = search("a foo b foo c |foo", "?foo")
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
@Test func escapeBackspaceAndEmptyEnter() {
    var h = Harness("a |foo b foo")
    h.type("/fo")
    #expect(h.engine.searchPrompt == "/fo")
    h.press(.escape)
    #expect(h.marked == "a |foo b foo")
    #expect(h.mode == .normal)
    #expect(h.engine.searchPrompt == nil)

    h.type("/fx")
    h.press(backspace)
    h.type("o")
    #expect(h.engine.searchPrompt == "/fo")
    h.press(enter)
    #expect(h.marked == "a foo b [fo]o")

    h.type("/")
    h.press(enter)
    #expect(h.marked == "a [fo]o b foo")
}

// AC7
@Test func searchNeverChangesTheText() {
    var h = search("|a foo b foo", "/foo")
    h.type("n*#N?a")
    h.press(enter)
    #expect(h.buffer.text == "a foo b foo")
}

// AC8
@Test func nonLatinPatternIsAccepted() {
    #expect(search("|가 나다 가", "/나다").marked == "가 [나다] 가")
    #expect(vimKey(keyCode: 0, shift: false, control: false, command: false, characters: "ㅁ", mode: .search) == VimKey("ㅁ"))
    #expect(vimKey(keyCode: 36, shift: false, control: false, command: false, characters: "\r", mode: .search) == enter)
    #expect(vimKey(keyCode: 51, shift: false, control: false, command: false, characters: "\u{7F}", mode: .search) == backspace)
}
