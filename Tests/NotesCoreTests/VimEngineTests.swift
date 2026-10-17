import Foundation
import Testing
@testable import NotesCore

/// Drives the engine like the event tap would: consumed keys run on the buffer, passed keys are typed in Insert.
/// Buffers are written with `|` for the cursor and `[...]` for a selection.
struct Harness {
    var engine: VimEngine
    var buffer: VimBuffer
    var time: TimeInterval = 0

    init(_ marked: String, mode: VimMode = .normal, jk: Bool = false) {
        let offset = (marked as NSString).range(of: "|").location
        buffer = VimBuffer(
            text: marked.replacingOccurrences(of: "|", with: ""),
            selection: NSRange(location: offset, length: 0))
        engine = VimEngine(mode: mode, jkEnabled: jk)
    }

    var marked: String {
        let s = NSMutableString(string: buffer.text)
        let r = buffer.selection
        if r.length == 0 {
            s.insert("|", at: r.location)
        } else {
            s.insert("]", at: r.location + r.length)
            s.insert("[", at: r.location)
        }
        return s as String
    }

    var mode: VimMode { engine.mode }

    @discardableResult
    mutating func press(_ key: VimKey, after delay: TimeInterval = 0.1) -> VimDecision {
        time += delay
        let decision = engine.feed(key, at: time)
        switch decision {
        case .consume(let command):
            buffer.apply(engine.execute(command, on: buffer))
        case .passThrough:
            if engine.mode == .insert && key.control == false && key.command == false {
                buffer.apply(.insert(String(key.character), at: buffer.selection.location))
            }
        }
        return decision
    }

    mutating func type(_ keys: String) {
        keys.forEach { press(VimKey($0)) }
    }
}

func run(_ marked: String, _ keys: String) -> String {
    var h = Harness(marked)
    h.type(keys)
    return h.marked
}

let ctrlBracket = VimKey("[", control: true)

// AC1
@Test func hAndLStayInLineAndStepOverGraphemes() {
    #expect(run("|가😀b", "l") == "가|😀b")
    #expect(run("|가😀b", "ll") == "가😀|b")
    #expect(run("|가😀b", "lll") == "가😀|b")
    #expect(run("가😀|b", "h") == "가|😀b")
    #expect(run("가😀|b", "hhh") == "|가😀b")
    #expect(run("a|b\ncd", "l") == "a|b\ncd")
    #expect(run("ab\n|cd", "h") == "ab\n|cd")
}

// AC2
@Test func jAndKKeepTheDesiredColumn() {
    #expect(run("abcd|ef\nab\nabcdef", "j") == "abcdef\na|b\nabcdef")
    #expect(run("abcd|ef\nab\nabcdef", "jj") == "abcdef\nab\nabcd|ef")
    #expect(run("abcdef\nab\nabcd|ef", "kk") == "abcd|ef\nab\nabcdef")
    #expect(run("ab|c\n\nabc", "j") == "abc\n|\nabc")
    #expect(run("ab|c\n\nabc", "jj") == "abc\n\nab|c")
    #expect(run("a|b\nabcdef", "$j") == "ab\nabcde|f")
    #expect(run("|abc\nx", "kk") == "|abc\nx")
}

// AC3
@Test func wordMotionsFollowTheClasses() {
    let text = "foo.bar  baz\n\nqux"
    #expect(run("|" + text, "w") == "foo|.bar  baz\n\nqux")
    #expect(run("|" + text, "ww") == "foo.|bar  baz\n\nqux")
    #expect(run("|" + text, "www") == "foo.bar  |baz\n\nqux")
    #expect(run("|" + text, "wwww") == "foo.bar  baz\n|\nqux")
    #expect(run("|" + text, "wwwww") == "foo.bar  baz\n\n|qux")
    #expect(run("foo.bar  baz\n\n|qux", "b") == "foo.bar  baz\n|\nqux")
    #expect(run("foo.bar  baz\n\n|qux", "bb") == "foo.bar  |baz\n\nqux")
    #expect(run("foo.bar  baz\n\n|qux", "bbbb") == "foo|.bar  baz\n\nqux")
    #expect(run("foo.bar  baz\n\n|qux", "bbbbb") == "|foo.bar  baz\n\nqux")
    #expect(run("|" + text, "e") == "fo|o.bar  baz\n\nqux")
    #expect(run("|" + text, "ee") == "foo|.bar  baz\n\nqux")
    #expect(run("|" + text, "eee") == "foo.ba|r  baz\n\nqux")
    #expect(run("|" + text, "eeee") == "foo.bar  ba|z\n\nqux")
    #expect(run("|" + text, "eeeee") == "foo.bar  baz\n\nqu|x")
    #expect(run("|한글_1 abc", "w") == "한글_1 |abc")
    #expect(run("|한글_1 abc", "e") == "한글_|1 abc")
    #expect(run("한글_1 |abc", "b") == "|한글_1 abc")
    #expect(run("ab |cd", "w") == "ab c|d")
}

// AC4
@Test func lineAndFileMotions() {
    #expect(run("  ab |cd\n  ef", "0") == "|  ab cd\n  ef")
    #expect(run("  ab |cd\n  ef", "^") == "  |ab cd\n  ef")
    #expect(run("  ab |cd\n  ef", "$") == "  ab c|d\n  ef")
    #expect(run("  ab cd\n  e|f", "gg") == "  |ab cd\n  ef")
    #expect(run("  ab |cd\n  ef", "G") == "  ab cd\n  |ef")
}

// AC5
@Test func xDeletesTheCharacterUnderTheCursor() {
    #expect(run("a|bc", "x") == "a|c")
    #expect(run("a|bc", "xp") == "ac|b")
    #expect(run("ab|c", "x") == "a|b")
    #expect(run("a😀|가b", "x") == "a😀|b")
    #expect(run("a\n|\nb", "x") == "a\n|\nb")
    #expect(run("|ab\n\nc", "xjxp") == "b\n|a\nc")
}

// AC6
@Test func ddDeletesTheLine() {
    #expect(run("one\n  t|wo\nthree", "dd") == "one\n|three")
    #expect(run("a\n|b\n  c", "dd") == "a\n  |c")
    #expect(run("  one\ntw|o", "dd") == "  |one")
    #expect(run("  o|ne", "dd") == "|")
    #expect(run("one\n  t|wo\nthree", "ddp") == "one\nthree\n  |two")
}

// AC7
@Test func yyAndPut() {
    #expect(run("a|b\ncd", "yy") == "a|b\ncd")
    #expect(run("a|b\ncd", "yyp") == "ab\n|ab\ncd")
    #expect(run("ab\nc|d", "yyp") == "ab\ncd\n|cd")
    #expect(run("a|bc", "xhp") == "a|bc")
    #expect(run("|", "p") == "|")
}

// AC8
@Test func uUndoesOnce() {
    var engine = VimEngine()
    let decision = engine.feed(VimKey("u"), at: 0)
    #expect(decision == .consume(.undo))
    #expect(engine.execute(.undo, on: VimBuffer(text: "abc")) == [.undo])
}

// AC9
@Test func insertEntries() {
    var h = Harness("ab|c")
    h.type("i")
    #expect(h.mode == .insert)
    #expect(h.marked == "ab|c")
    #expect(run("ab|c", "a") == "abc|")
    #expect(run("|", "a") == "|")
    #expect(run("  a|bc", "I") == "  |abc")
    #expect(run("   |", "I") == "   |")
    #expect(run("  a|bc\nd", "A") == "  abc|\nd")
    #expect(run("a|b\ncd", "o") == "ab\n|\ncd")
    #expect(run("ab\nc|d", "o") == "ab\ncd\n|")
    #expect(run("ab\nc|d", "O") == "ab\n|\ncd")
    #expect(run("a|b\ncd", "ox") == "ab\nx|\ncd")
}

// AC10
@Test func escapeLeavesInsertAndVisual() {
    var h = Harness("ab|c")
    h.type("A")
    h.press(.escape)
    #expect(h.mode == .normal)
    #expect(h.marked == "ab|c")

    h = Harness("ab\n|cd", mode: .insert)
    h.press(ctrlBracket)
    #expect(h.mode == .normal)
    #expect(h.marked == "ab\n|cd")

    h = Harness("a|bcd")
    h.type("vl")
    h.press(.escape)
    #expect(h.mode == .normal)
    #expect(h.marked == "ab|cd")

    h = Harness("a|bcd")
    h.type("vl")
    h.press(ctrlBracket)
    #expect(h.mode == .normal)
    #expect(h.marked == "ab|cd")
}

// AC11
@Test func jkLeavesInsertWhenEnabled() {
    var h = Harness("ab|", mode: .insert, jk: true)
    #expect(h.press(VimKey("j")) == .passThrough)
    #expect(h.press(VimKey("k"), after: 0.5) != .passThrough)
    #expect(h.mode == .normal)
    #expect(h.marked == "a|b")

    h = Harness("ab|", mode: .insert, jk: true)
    #expect(h.press(VimKey("j")) == .passThrough)
    #expect(h.press(VimKey("k"), after: 1.5) == .passThrough)
    #expect(h.mode == .insert)
    #expect(h.marked == "abjk|")

    h = Harness("ab|", mode: .insert, jk: true)
    h.type("jxk")
    #expect(h.mode == .insert)
    #expect(h.marked == "abjxk|")

    h = Harness("ab|", mode: .insert)
    #expect(h.press(VimKey("j")) == .passThrough)
    #expect(h.press(VimKey("k"), after: 0.1) == .passThrough)
    #expect(h.mode == .insert)
    #expect(h.marked == "abjk|")
}

// AC12
@Test func visualSelectsAndOperates() {
    var h = Harness("ab|cdef")
    h.type("v")
    #expect(h.mode == .visual)
    #expect(h.marked == "ab[c]def")
    h.type("ll")
    #expect(h.marked == "ab[cde]f")
    h.type("hhhh")
    #expect(h.marked == "[abc]def")
    h.type("x")
    #expect(h.mode == .normal)
    #expect(h.marked == "|def")
    h.type("p")
    #expect(h.marked == "dab|cef")

    h = Harness("ab|cdef")
    h.type("vld")
    #expect(h.mode == .normal)
    #expect(h.marked == "ab|ef")

    h = Harness("a|bcd")
    h.type("vly")
    #expect(h.mode == .normal)
    #expect(h.marked == "a|bcd")
    h.type("p")
    #expect(h.marked == "abb|ccd")

    h = Harness("a|bc\nde")
    h.type("vj")
    #expect(h.marked == "a[bc\nde]")
    h.type("d")
    #expect(h.marked == "|a")

    h = Harness("abc|d")
    h.type("vhv")
    #expect(h.mode == .normal)
    #expect(h.marked == "ab|cd")
}

// AC13
@Test func pendingOperatorCancels() {
    #expect(run("a|b\ncd", "gx") == "a|b\ncd")
    #expect(run("a|b\ncd", "gxx") == "|a\ncd")
    #expect(run("a|b\ncd", "dx") == "a|b\ncd")
    #expect(run("a|b\ncd", "dxx") == "|a\ncd")

    var h = Harness("a|b\ncd")
    h.type("d")
    h.press(.escape)
    #expect(h.marked == "a|b\ncd")
    h.type("x")
    #expect(h.marked == "|a\ncd")

    h = Harness("ab\nc|d")
    h.type("g")
    #expect(h.press(VimKey("g", command: true)) == .passThrough)
    h.type("g")
    #expect(h.marked == "ab\nc|d")
}

// AC14
@Test func passThroughRules() {
    var h = Harness("|", mode: .insert)
    #expect(h.press(VimKey("x")) == .passThrough)
    #expect(h.press(VimKey("a", control: true)) == .passThrough)
    #expect(h.press(VimKey("c", command: true)) == .passThrough)

    h = Harness("a|b")
    #expect(h.press(VimKey("c", command: true)) == .passThrough)
    #expect(h.press(VimKey("z")) == .consume(.none))
    #expect(h.press(VimKey("Q")) == .consume(.none))
    #expect(h.press(VimKey("a", control: true)) == .consume(.none))
    #expect(h.marked == "a|b")

    h.type("v")
    #expect(h.press(VimKey("c", command: true)) == .passThrough)
    #expect(h.press(VimKey("z")) == .consume(.none))
    #expect(h.mode == .visual)
}

// AC1 (#71)
@Test func countsRepeatCommands() {
    #expect(run("|a\nb\nc\nd", "3j") == "a\nb\nc\n|d")
    #expect(run("|abcdefg", "5x") == "|fg")
    #expect(run("|a\nb\nc", "2dd") == "|c")
    #expect(run("|a\nb\nc\nd", "2dd") == "|c\nd")
    #expect(run("|ab", "x2p") == "ba|a")
    #expect(run("|a\nb\nc", "yy2p") == "a\n|a\na\nb\nc")
    #expect(run("|0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11", "10j") == "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n|10\n11")
    #expect(run("  ab|c", "0") == "|  abc")
    #expect(run("|a b c d e", "2d2w") == "|e")
}

// AC2 (#71)
@Test func deleteWithMotions() {
    #expect(run("|one two three", "dw") == "|two three")
    #expect(run("one |two", "d$") == "one |")
    #expect(run("one |two", "d0") == "|two")
    #expect(run("one |two", "dw") == "one |")
    #expect(run("a\n|b\nc", "dG") == "|a")
    #expect(run("a\nb\n|c", "dgg") == "|")
    #expect(run("a\n|b\nc", "dgg") == "|c")
    #expect(run("a|b\ncd\ne", "dj") == "|e")
    #expect(run("one |two", "db") == "|two")
    #expect(run("|one two", "de") == "| two")
}

// AC3 (#71)
@Test func changeWithMotions() {
    var h = Harness("|one two")
    h.type("cw")
    #expect(h.marked == "| two")
    #expect(h.mode == .insert)

    h = Harness("a\n  b|c\nd")
    h.type("cc")
    #expect(h.marked == "a\n|\nd")
    #expect(h.mode == .insert)
}

// AC4 (#71)
@Test func yankWithMotions() {
    #expect(run("|one two", "ywP") == "one| one two")
    #expect(run("|one two", "ywp") == "oone| ne two")
    #expect(run("one |two", "y$P") == "one tw|otwo")
    #expect(run("|one two", "dwP") == "one| two")
    #expect(run("|one\ntwo", "yjGp") == "one\ntwo\n|one\ntwo")
}

// AC5 (#71)
@Test func oneKeyEdits() {
    #expect(run("one |two", "D") == "one |")
    var h = Harness("one |two")
    h.type("C")
    #expect(h.marked == "one |")
    #expect(h.mode == .insert)
    #expect(run("a|b", "xP") == "|ba")
    #expect(run("ab|c", "rx") == "ab|x")
    #expect(run("a|bc", "rx") == "a|xc")
    #expect(run("a|bcd", "2rx") == "ax|xd")
    #expect(run("a|b\n  cd", "J") == "ab| cd")
    #expect(run("a|b\n\ncd", "J") == "a|b\ncd")
    #expect(run("|aBc", "~") == "A|Bc")
    #expect(run("|aBc", "3~") == "Ab|C")
    #expect(run("a|1", "~") == "a|1")
}

// AC6 (#71)
@Test func ctrlRIsRedo() {
    var engine = VimEngine()
    #expect(engine.feed(VimKey("r", control: true), at: 0) == .consume(.redo))
    #expect(engine.execute(.redo, on: VimBuffer(text: "abc")) == [.redo])
    #expect(engine.feed(VimKey("u"), at: 0) == .consume(.undo))
}

// AC7 (#71)
@Test func escapeCancelsCountAndOperator() {
    var h = Harness("a|bc\nd")
    h.type("3")
    h.press(.escape)
    h.type("x")
    #expect(h.marked == "a|c\nd")

    h = Harness("a|bc\nd")
    h.type("d")
    h.press(.escape)
    h.type("x")
    #expect(h.marked == "a|c\nd")
    #expect(h.mode == .normal)
}

// AC8 (#71)
@Test func operatorsRefuseToCrossAnAttachmentLine() {
    let table = "a\n\u{FFFC}\nb"
    #expect(run("|" + table, "dj") == "|" + table)
    #expect(run("|" + table, "2dd") == "|" + table)
    #expect(run("|" + table, "dG") == "|" + table)
    #expect(run("|" + table, "yjjp") != table)

    var h = Harness("|" + table)
    h.type("cj")
    #expect(h.marked == "|" + table)
    #expect(h.mode == .normal)
}
