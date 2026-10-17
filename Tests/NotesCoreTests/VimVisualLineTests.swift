import Foundation
import Testing
@testable import NotesCore

// AC1 (#75)
@Test func visualLineSelectsAndExtends() {
    var h = Harness("a\nb|c\nd\ne")
    h.type("V")
    #expect(h.mode == .visualLine)
    #expect(h.marked == "a\n[bc\n]d\ne")
    h.type("j")
    #expect(h.marked == "a\n[bc\nd\n]e")
    h.type("kk")
    #expect(h.marked == "[a\nbc\n]d\ne")
    h.type("jjj")
    #expect(h.marked == "a\n[bc\nd\ne]")
}

// AC2 (#75)
@Test func visualLineDeleteAndYank() {
    #expect(run("a\nb|c\nd\ne", "Vjd") == "a\n|e")
    #expect(run("a\nb|c\nd", "Vjd") == "|a")
    #expect(run("|a\nb\nc", "Vjx") == "|c")
    #expect(run("a\nb|c\nd\ne", "Vjyp") == "a\nbc\n|bc\nd\nd\ne")
}

// AC3 (#75)
@Test func visualLineSwapsEnds() {
    var h = Harness("a\n|b\nc\nd")
    h.type("Vjo")
    #expect(h.marked == "a\n[b\nc\n]d")
    h.type("k")
    #expect(h.marked == "[a\nb\nc\n]d")
}

// AC4 (#75)
@Test func visualLineJoins() {
    #expect(run("|a\n  b\nc\nd", "VjjJ") == "a b| c\nd")
    #expect(run("|a\nb\nc", "VJ") == "a| b\nc")
}

// AC5 (#75)
@Test func visualLineIndents() {
    var h = Harness("a\n|b\nc\nd")
    h.type("Vj")
    var engine = h.engine
    #expect(engine.execute(.indentSelection(outdent: false), on: h.buffer).first
        == .indent(NSRange(location: 2, length: 4), outdent: false))
    h.type("<")
    #expect(h.mode == .normal)
    h = Harness("a\n|b\nc\nd")
    h.type("Vj>")
    #expect(h.mode == .normal)
    #expect(h.buffer.text == "a\nb\nc\nd")
}

// AC6 (#75)
@Test func visualLineLeaves() {
    var h = Harness("a\n|b")
    h.type("V")
    h.press(.escape)
    #expect(h.mode == .normal)
    #expect(h.marked == "a\n|b")
    h.type("VV")
    #expect(h.mode == .normal)
    h.type("Vv")
    #expect(h.mode == .visual)
    #expect(h.marked == "a\n[b]")
    h.type("V")
    #expect(h.mode == .visualLine)
}

// D6 (#75)
@Test func visualLineDeleteKeepsAttachmentGuard() {
    var h = Harness("a\n|\u{FFFC}\nb")
    h.type("Vd")
    #expect(h.buffer.text == "a\n\u{FFFC}\nb")
    #expect(h.mode == .normal)
}
