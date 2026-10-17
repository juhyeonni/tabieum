import Foundation
import Testing
@testable import NotesCore

private func shifts(_ marked: String, _ keys: String) -> (ranges: [NSRange], outdents: [Bool], h: Harness) {
    var h = Harness(marked)
    var ranges: [NSRange] = [], outdents: [Bool] = []
    for c in keys {
        h.time += 0.1
        guard case .consume(let command) = h.engine.feed(VimKey(c), at: h.time) else { continue }
        let actions = h.engine.execute(command, on: h.buffer)
        for case .indent(let range, let outdent) in actions {
            ranges.append(range)
            outdents.append(outdent)
        }
        h.buffer.apply(actions)
    }
    return (ranges, outdents, h)
}

// AC1 (#109)
@Test func doubleKeyShiftsCurrentLine() {
    var r = shifts("a\nb|c\nd", ">>")
    #expect(r.ranges == [NSRange(location: 2, length: 3)])
    #expect(r.outdents == [false])
    #expect(r.h.mode == .normal)
    #expect(r.h.buffer.text == "a\nbc\nd")
    r = shifts("a\nb|c\nd", "<<")
    #expect(r.outdents == [true])
}

// AC2 (#109)
@Test func countedShiftClamps() {
    #expect(shifts("a\n|b\nc\nd", "3>>").ranges == [NSRange(location: 2, length: 5)])
    #expect(shifts("a\n|b\nc", "9>>").ranges == [NSRange(location: 2, length: 3)])
}

// AC3 (#109)
@Test func shiftWithMotionAndObject() {
    #expect(shifts("a\n|b\nc\nd", ">j").ranges == [NSRange(location: 2, length: 4)])
    #expect(shifts("|a\nb\n\nc", ">}").ranges == [NSRange(location: 0, length: 5)])
    #expect(shifts("x\n\na\nb|\n\nc", ">ip").ranges == [NSRange(location: 3, length: 4)])
}

// AC4 (#109)
@Test func visualShiftLeavesVisual() {
    let r = shifts("a\nb|c\nd\ne", "vj>")
    #expect(r.ranges == [NSRange(location: 2, length: 5)])
    #expect(r.h.mode == .normal)
}

// AC5 (#109)
@Test func escapeCancelsShift() {
    var h = Harness("a\n|b")
    h.type(">")
    h.press(.escape)
    h.type("j")
    #expect(h.mode == .normal)
    #expect(h.marked == "a\n|b")
}
