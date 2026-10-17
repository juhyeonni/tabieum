import Foundation
import Testing
@testable import NotesCore

private func screen(_ marked: String, _ keys: [VimKey]) -> String {
    var h = Harness(marked)
    h.buffer.visible = NSRange(location: 3, length: 12)
    keys.forEach { h.press($0) }
    return h.marked
}

private let lines = "l0\nl1\nl2\nl3\nl4\nl5"

// AC1
@Test func findAndTillMoveOnTheLine() {
    #expect(run("|ab.c.d", "f.") == "ab|.c.d")
    #expect(run("|ab.c.d", "t.") == "a|b.c.d")
    #expect(run("a.bcd|e", "F.") == "a|.bcde")
    #expect(run("a.bcd|e", "T.") == "a.|bcde")
    #expect(run("|a.b.c.d", "2f.") == "a.b|.c.d")
}

@Test func semicolonRepeatsAndCommaReverses() {
    #expect(run("|a.b.c", "f.;") == "a.b|.c")
    #expect(run("|a.b.c", "f.;,") == "a|.b.c")
    #expect(run("|ab.c.d", "t.;") == "ab.|c.d")
}

@Test func findWithoutMatchStaysAndNeverLeavesTheLine() {
    #expect(run("|abc", "fx") == "|abc")
    #expect(run("|ab\nc.d", "f.") == "|ab\nc.d")
    #expect(run("|abc", ";") == "|abc")
}

// AC2
@Test func percentJumpsBetweenBrackets() {
    #expect(run("|(a[b]{c})", "%") == "(a[b]{c}|)")
    #expect(run("(a[b]{c}|)", "%") == "|(a[b]{c})")
    #expect(run("|(a(b)c)", "%") == "(a(b)c|)")
    #expect(run("(a|(b)c)", "%") == "(a(b|)c)")
    #expect(run("|foo (x)", "%") == "foo (x|)")
    #expect(run("|(a\nb)", "%") == "(a\nb|)")
}

@Test func percentWithoutBracketDoesNothing() {
    #expect(run("|abc", "%") == "|abc")
    #expect(run("|(a", "%") == "|(a")
}

// AC3
@Test func bracesMoveByParagraph() {
    let text = "a\nb\n\nc\nd"
    #expect(run("|" + text, "}") == "a\nb\n|\nc\nd")
    #expect(run("|" + text, "}}") == "a\nb\n\nc\n|d")
    #expect(run("a\nb\n\nc\n|d", "{") == "a\nb\n|\nc\nd")
    #expect(run("a\nb\n\nc\n|d", "{{") == "|a\nb\n\nc\nd")
}

// AC4
@Test func bigWordsAreRunsOfNonWhitespace() {
    #expect(run("|foo-bar baz", "W") == "foo-bar |baz")
    #expect(run("|foo-bar baz", "w") == "foo|-bar baz")
    #expect(run("|foo-bar baz", "E") == "foo-ba|r baz")
    #expect(run("foo-bar |baz", "B") == "|foo-bar baz")
}

// AC6
@Test func newMotionsExtendTheVisualSelection() {
    #expect(run("|ab.cd", "vf.") == "[ab.]cd")
    #expect(run("|(a)b", "v%") == "[(a)]b")
    #expect(run("|foo-bar baz", "vW") == "[foo-bar b]az")
}

@Test func newMotionsWorkAfterAnOperator() {
    #expect(run("|ab.cd", "df.") == "|cd")
    #expect(run("|ab.cd", "dt.") == "|.cd")
    #expect(run("ab.c|d", "dF.") == "ab|d")
    #expect(run("|(a)b", "d%") == "|b")
    #expect(run("|a\nb\n\nc", "d}") == "|\nc")
    #expect(run("|foo-bar baz", "dW") == "|baz")
    #expect(run("|ab.cd", "dfx") == "|ab.cd")
}

@Test func screenMotionsAreRelativeToTheVisibleLines() {
    #expect(screen("|" + lines, [VimKey("H")]) == "l0\n|l1\nl2\nl3\nl4\nl5")
    #expect(screen("|" + lines, [VimKey("M")]) == "l0\nl1\n|l2\nl3\nl4\nl5")
    #expect(screen("|" + lines, [VimKey("L")]) == "l0\nl1\nl2\nl3\n|l4\nl5")
    #expect(screen("l0\n|l1\nl2\nl3\nl4\nl5", [VimKey("d"), VimKey("L")]) == "l0\n|l5")
}

@Test func scrollKeysMoveByHalfAndWholePages() {
    let d = VimKey("d", control: true), u = VimKey("u", control: true)
    let f = VimKey("f", control: true), b = VimKey("b", control: true)
    #expect(screen("|" + lines, [d]) == "l0\nl1\n|l2\nl3\nl4\nl5")
    #expect(screen("|" + lines, [f]) == "l0\nl1\nl2\nl3\n|l4\nl5")
    #expect(screen("l0\nl1\nl2\nl3\nl4\n|l5", [u]) == "l0\nl1\nl2\n|l3\nl4\nl5")
    #expect(screen("l0\nl1\nl2\nl3\nl4\n|l5", [b]) == "l0\n|l1\nl2\nl3\nl4\nl5")
}
