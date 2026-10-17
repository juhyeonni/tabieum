import Foundation
import Testing
@testable import NotesCore

// AC1 (#74)
@Test func wordObjects() {
    var h = Harness("one |two three")
    h.type("ciw")
    #expect(h.marked == "one | three")
    #expect(h.mode == .insert)
    #expect(run("one |two three", "daw") == "one |three")
    #expect(run("one two |three", "daw") == "one two|")
    #expect(run("one |two three", "diw") == "one | three")
}

// AC2 (#74)
@Test func paragraphObjects() {
    #expect(run("a\n|b\n\nc", "dip") == "|\nc")
    #expect(run("a\n|b\n\nc", "dap") == "|c")
    #expect(run("a\n\nc\n|d", "dap") == "|a")
}

// AC3 (#74)
@Test func quoteObjects() {
    #expect(run("say \"he|llo\" now", "di\"") == "say \"|\" now")
    #expect(run("say \"he|llo\" now", "da\"") == "say | now")
    #expect(run("say 'he|llo' now", "di'") == "say '|' now")
    #expect(run("say 'he|llo' now", "da'") == "say | now")
}

// AC4 (#74)
@Test func bracketObjects() {
    #expect(run("f(a, (b|c), d)", "di(") == "f(a, (|), d)")
    #expect(run("f(a, (b|c), d)", "da(") == "f(a, |, d)")
    #expect(run("[a, |b]", "di[") == "[|]")
    #expect(run("{a|\nb}", "da{") == "|")
    #expect(run("f(a|)", "di)") == "f(|)")
}

// AC5 (#74)
@Test func yankAndVisualObjects() {
    #expect(run("|one two", "yiwp") == "oon|ene two")
    #expect(run("one |two three", "viw") == "one [two] three")
    #expect(run("a\n|b\n\nc", "vip") == "[a\nb]\n\nc")
    #expect(run("(a|b)", "vi(") == "([ab])")
}

// AC6 (#74)
@Test func missingObjectChangesNothing() {
    #expect(run("a |b c", "di\"") == "a |b c")
    #expect(run("a |b c", "da(") == "a |b c")
    #expect(run("a |b c", "vi(") == "a [b] c")
    var h = Harness("a |b c")
    h.type("ci(")
    #expect(h.marked == "a |b c")
    #expect(h.mode == .normal)
}
