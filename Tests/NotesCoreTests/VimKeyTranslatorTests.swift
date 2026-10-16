import Foundation
import Testing
@testable import NotesCore

private func key(_ code: Int, shift: Bool = false, control: Bool = false, command: Bool = false,
                 chars: String = "", mode: VimMode = .normal) -> VimKey? {
    vimKey(keyCode: code, shift: shift, control: control, command: command, characters: chars, mode: mode)
}

// AC1
@Test func normalModeReadsUSANSIKeycodesWhateverTheCharacters() {
    #expect(key(4, chars: "ㅗ") == VimKey("h"))
    #expect(key(38, chars: "ㅓ") == VimKey("j"))
    #expect(key(40, chars: "ㅏ") == VimKey("k"))
    #expect(key(37) == VimKey("l"))
    #expect(key(29) == VimKey("0"))
    #expect(key(5) == VimKey("g"))
    #expect(key(7, mode: .visual) == VimKey("x"))
}

@Test func shiftSelectsTheShiftedCharacter() {
    #expect(key(21, shift: true) == VimKey("$"))
    #expect(key(22, shift: true) == VimKey("^"))
    #expect(key(5, shift: true) == VimKey("G"))
    #expect(key(34, shift: true) == VimKey("I"))
    #expect(key(0, shift: true) == VimKey("A"))
    #expect(key(31, shift: true) == VimKey("O"))
}

@Test func escapeAndControlBracketMapToEscapeInEveryMode() {
    for mode in [VimMode.normal, .insert, .visual] {
        #expect(key(53, mode: mode) == .escape)
        #expect(key(33, control: true, chars: "\u{1B}", mode: mode) == .escape)
    }
    #expect(key(33) == VimKey("["))
}

@Test func commandKeysAreMarked() {
    #expect(key(9, command: true) == VimKey("v", command: true))
    #expect(key(6, command: true, chars: "z", mode: .insert) == VimKey("z", command: true))
    #expect(key(53, command: true) == VimKey("\u{1B}", command: true))
}

@Test func insertModeTakesTheEventsCharacters() {
    #expect(key(38, chars: "ㅓ", mode: .insert) == VimKey("ㅓ"))
    #expect(key(38, chars: "j", mode: .insert) == VimKey("j"))
    #expect(key(123, chars: "", mode: .insert) == nil)
}

@Test func unmappedKeysPassThrough() {
    #expect(key(123) == nil)
}

@Test func hangulInInsertNeverTriggersJK() {
    var engine = VimEngine(mode: .insert, jkEnabled: true)
    #expect(engine.feed(key(38, chars: "ㅓ", mode: .insert)!, at: 0) == .passThrough)
    #expect(engine.feed(key(40, chars: "ㅏ", mode: .insert)!, at: 0.1) == .passThrough)
    #expect(engine.mode == .insert)
}

@Test func deletesNeverCrossATableLineButMayCrossAHashtag() {
    let buffer = VimBuffer(text: "one\n\u{FFFC}\ntwo #tag\u{FFFC}\nthree")
    #expect(buffer.caretLine == NSRange(location: 0, length: 4))
    #expect(buffer.deleteWouldHitBlockAttachment(NSRange(location: 2, length: 4)))
    #expect(buffer.deleteWouldHitBlockAttachment(NSRange(location: 4, length: 2)))
    #expect(!buffer.deleteWouldHitBlockAttachment(NSRange(location: 6, length: 9)))
    #expect(!buffer.deleteWouldHitBlockAttachment(NSRange(location: 0, length: 3)))
}

@Test func unsupportedLinesTurnBasicMotionsIntoArrowKeys() {
    #expect(fallbackArrowKeyCode(for: .motion(.left)) == 123)
    #expect(fallbackArrowKeyCode(for: .motion(.right)) == 124)
    #expect(fallbackArrowKeyCode(for: .motion(.down)) == 125)
    #expect(fallbackArrowKeyCode(for: .motion(.up)) == 126)
    #expect(fallbackArrowKeyCode(for: .motion(.wordForward)) == nil)
    #expect(fallbackArrowKeyCode(for: .deleteChar) == nil)
    #expect(fallbackArrowKeyCode(for: .none) == nil)
}
