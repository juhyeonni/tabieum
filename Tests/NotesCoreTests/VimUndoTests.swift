import Foundation
import Testing
@testable import NotesCore

private func applied(_ actions: [VimAction]?, to text: String) -> String? {
    guard let actions else { return nil }
    var buffer = VimBuffer(text: text)
    buffer.apply(actions)
    return buffer.text
}

@Test func anEditIsTheReplacementBetweenTwoTexts() throws {
    let deleted = try #require(VimEdit(from: "alpha beta gamma", to: "alpha gamma"))
    #expect(deleted == VimEdit(from: "alpha beta gamma", to: "alpha gamma"))
    #expect(deleted.location == 6 && deleted.removed == "beta " && deleted.inserted == "")

    let inserted = try #require(VimEdit(from: "ab", to: "aXYb"))
    #expect(inserted.location == 1 && inserted.removed == "" && inserted.inserted == "XY")

    let replaced = try #require(VimEdit(from: "one two three", to: "one 2 three"))
    #expect(replaced.location == 4 && replaced.removed == "two" && replaced.inserted == "2")

    #expect(VimEdit(from: "same", to: "same") == nil)
}

@Test func anEditNeverSplitsAnEmojiPair() throws {
    let edit = try #require(VimEdit(from: "a😀b", to: "a😁b"))
    #expect(edit.removed == "😀" && edit.inserted == "😁")
    #expect(edit.removed.utf16.count == 2)
}

@Test func undoAndRedoRestoreTheTextExactly() throws {
    let cases = [
        ("alpha beta gamma", "alpha gamma"), ("ab", "aXYb"), ("one two three", "one 2 three"),
        ("", "new text"), ("gone", ""), ("a😀b", "a😁b"), ("한글 노트", "한글 메모 노트")
    ]
    for (old, new) in cases {
        var stack = VimUndoStack()
        stack.record(try #require(VimEdit(from: old, to: new)))
        let undo = stack.undo(on: new)
        #expect(applied(undo, to: new) == old, "undo \(old) -> \(new)")
        let redo = stack.redo(on: old)
        #expect(applied(redo, to: old) == new, "redo \(old) -> \(new)")
    }
}

@Test func eachRecordedCommandIsItsOwnStep() throws {
    var stack = VimUndoStack()
    let texts = ["alpha beta gamma delta", "alpha eta gamma delta", "alpha ta gamma delta", "alpha a gamma delta"]
    for pair in zip(texts, texts.dropFirst()) { stack.record(try #require(VimEdit(from: pair.0, to: pair.1))) }

    var text = texts[3]
    for expected in texts.dropLast().reversed() {
        let actions = stack.undo(on: text)
        text = try #require(applied(actions, to: text))
        #expect(text == expected)
    }
    #expect(stack.undo(on: text) == nil)

    for expected in texts.dropFirst() {
        let actions = stack.redo(on: text)
        text = try #require(applied(actions, to: text))
        #expect(text == expected)
    }
    #expect(stack.redo(on: text) == nil)
}

@Test func aNewEditDropsWhatWasUndone() throws {
    var stack = VimUndoStack()
    stack.record(try #require(VimEdit(from: "a b", to: "a")))
    _ = stack.undo(on: "a")
    stack.record(try #require(VimEdit(from: "a b", to: "b")))
    #expect(stack.redo(on: "b") == nil)
}

@Test func theCaretGoesToTheStartOfTheChange() throws {
    var stack = VimUndoStack()
    stack.record(try #require(VimEdit(from: "alpha beta", to: "alpha ")))
    let undo = stack.undo(on: "alpha ")
    let actions = try #require(undo)
    #expect(actions.last == .select(NSRange(location: 6, length: 0)))
}

@Test func aNoteChangedFromOutsideDropsTheHistory() throws {
    var stack = VimUndoStack()
    stack.record(try #require(VimEdit(from: "alpha beta", to: "alpha ")))
    #expect(stack.undo(on: "something else entirely") == nil)
    #expect(stack.undo(on: "alpha ") == nil)

    var sameLength = VimUndoStack()
    sameLength.record(try #require(VimEdit(from: "alpha beta", to: "alpha ")))
    #expect(sameLength.undo(on: "zzzzzz") == nil)
    var sameStart = VimUndoStack()
    sameStart.record(try #require(VimEdit(from: "alpha beta", to: "alpha ")))
    #expect(sameStart.undo(on: "alpha!") == nil)

    stack.record(try #require(VimEdit(from: "ab", to: "a")))
    _ = stack.undo(on: "a")
    #expect(stack.redo(on: "zzz") == nil)
    #expect(stack.redo(on: "ab") == nil)
}

@Test func theHistoryIsCapped() throws {
    var stack = VimUndoStack()
    var text = ""
    for _ in 0..<600 {
        let next = text + "x"
        stack.record(try #require(VimEdit(from: text, to: next)))
        text = next
    }
    var steps = 0
    while let actions = stack.undo(on: text) {
        text = applied(actions, to: text) ?? text
        steps += 1
    }
    #expect(steps == 500)
}

@Test func undoAndRedoCommandsCarryTheirCount() {
    #expect(VimCommand.undo.historyRun?.redo == false && VimCommand.undo.historyRun?.count == 1)
    #expect(VimCommand.redo.historyRun?.redo == true && VimCommand.redo.historyRun?.count == 1)
    #expect(VimCommand.counted(.undo, 3).historyRun?.count == 3)
    #expect(VimCommand.counted(.redo, 2).historyRun?.redo == true)
    #expect(VimCommand.deleteChar.historyRun == nil)
    #expect(VimCommand.counted(.deleteChar, 3).historyRun == nil)
}
