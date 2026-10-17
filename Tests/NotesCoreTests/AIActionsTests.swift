import CoreGraphics
import Foundation
import Testing
@testable import NotesCore

private final class CountingProvider: AIProvider, @unchecked Sendable {
    var calls = 0
    func chat(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        calls += 1
        return AsyncThrowingStream { $0.finish() }
    }

    func embed(_ texts: [String]) async throws -> [[Float]] { [] }
}

// AC1
@Test func actionsFollowAIAndSelection() {
    #expect(availableAIActions(aiOn: false, hasSelection: true).isEmpty)
    #expect(availableAIActions(aiOn: false, hasSelection: false).isEmpty)
    #expect(availableAIActions(aiOn: true, hasSelection: true) == [.rewrite, .summarize, .instruction])
    #expect(availableAIActions(aiOn: true, hasSelection: false) == [.prompt])
}

// AC2
@Test(arguments: [AIAction.rewrite, .summarize, .instruction])
func selectionActionsCarrySelectionVerbatim(action: AIAction) throws {
    let selection = "  Mixed *Markdown*\n두 번째 줄  "
    let messages = try aiMessages(for: action, selection: selection, instruction: "make it formal")
    #expect(messages.map(\.role) == [.system, .user])
    #expect(messages[1].content.contains(selection))
    #expect(messages[1].content.contains("make it formal"))
    #expect(messages[0].content.contains("plain text"))
    #expect(messages[0].content.contains("no Markdown"))
}

@Test func freePromptSendsOnlyTheInstruction() throws {
    let messages = try aiMessages(for: .prompt, selection: "note text", instruction: "write a haiku")
    #expect(messages[1].content == "write a haiku")
}

// AC3
@Test func leadingThinkBlockIsRemoved() {
    #expect(strippingThinkBlock("<think>hmm\nso</think>Hello") == "Hello")
    #expect(strippingThinkBlock("  <think>x</think>\n\nHello <think>y</think>") == "\n\nHello <think>y</think>")
    #expect(strippingThinkBlock("Hello <think>x</think>") == "Hello <think>x</think>")
    #expect(strippingThinkBlock("<think>unclosed") == "<think>unclosed")
}

// AC4
@Test func tooLongSelectionIsRefusedWithoutCallingTheProvider() async {
    let provider = CountingProvider()
    let selection = String(repeating: "a", count: maxAISelectionLength + 1)
    var failure: AIPromptError?
    do {
        for try await _ in aiResult(provider: provider, action: .rewrite, selection: selection) {}
    } catch {
        failure = error as? AIPromptError
    }
    #expect(failure == .tooLong)
    #expect(provider.calls == 0)

    _ = aiResult(provider: provider, action: .rewrite, selection: String(selection.dropLast()))
    #expect(provider.calls == 1)
}

// AC5
@Test func insertWritesOnlyIntoTheUnchangedFocusedNote() {
    let snapshot = VimBuffer(text: "hello world", selection: NSRange(location: 0, length: 5))
    func decide(_ front: Bool = true, _ focused: Bool = true, _ current: VimBuffer? = snapshot) -> InsertDecision {
        insertDecision(notesFrontmost: front, bodyFocused: focused, current: current, snapshot: snapshot)
    }
    #expect(decide() == .write)
    #expect(decide(false) == .refuse)
    #expect(decide(true, false) == .refuse)
    #expect(decide(true, true, nil) == .refuse)
    #expect(decide(true, true, VimBuffer(text: "hello there", selection: snapshot.selection)) == .refuse)
    #expect(decide(true, true, VimBuffer(text: snapshot.text, selection: NSRange(location: 1, length: 5))) == .refuse)
}

@Test func shortcutNeedsCommandOrControl() {
    #expect(HotKey.aiDefault.isValid)
    #expect(HotKey.aiDefault.label == "⌃⌥⌘A")
    #expect(!HotKey(keyCode: 0, modifiers: [.maskAlternate], key: "A").isValid)
    #expect(!HotKey(keyCode: 0, modifiers: [.maskAlternate, .maskShift], key: "A").isValid)
    #expect(!HotKey(keyCode: 0, modifiers: [], key: "A").isValid)
    #expect(HotKey.aiDefault.matches(keyCode: 0, flags: [.maskControl, .maskAlternate, .maskCommand, .maskNonCoalesced]))
    #expect(!HotKey.aiDefault.matches(keyCode: 0, flags: [.maskControl, .maskCommand]))
}

@Test func storedShortcutRoundTripsAndInvalidFallsBack() {
    let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    let toggles = FeatureToggles(defaults: defaults)
    #expect(toggles.aiShortcut == .aiDefault)
    let custom = HotKey(keyCode: 11, modifiers: [.maskCommand, .maskShift], key: "B")
    toggles.aiShortcut = custom
    #expect(FeatureToggles(defaults: defaults).aiShortcut == custom)
    defaults.set(Int(CGEventFlags.maskAlternate.rawValue), forKey: "aiShortcutModifiers")
    #expect(FeatureToggles(defaults: defaults).aiShortcut == .aiDefault)
}

@Test func contextIsSelectionThenWholeNoteThenNothing() {
    #expect(aiContext(text: "hello world", selection: NSRange(location: 0, length: 5)) == .selection("hello"))
    #expect(aiContext(text: "hello world", selection: NSRange(location: 3, length: 0)) == .wholeNote("hello world"))
    #expect(aiContext(text: " \n", selection: NSRange(location: 0, length: 0)) == .none)
}

@Test func overlongNoteIsTooLongAndSendsOnlyTheInstruction() throws {
    let note = String(repeating: "a", count: maxAISelectionLength + 1)
    let context = aiContext(text: note, selection: NSRange(location: 0, length: 0))
    #expect(context == .tooLong(note.count))
    let messages = try aiMessages(for: .prompt, selection: "", instruction: "tidy", context: context.text)
    #expect(messages[1].content == "tidy")
}

@Test func freePromptCarriesTheContextWhenGiven() throws {
    let with = try aiMessages(for: .prompt, selection: "", instruction: "tidy", context: "my note")
    #expect(with[1].content.contains("tidy") && with[1].content.contains("my note"))
    let without = try aiMessages(for: .prompt, selection: "", instruction: "tidy")
    #expect(without[1].content == "tidy")
}

@Test func chipTextNamesScopeAndSize() {
    #expect(AIContext.wholeNote(String(repeating: "a", count: 1234)).chip == "Whole note · 1,234 characters")
    #expect(AIContext.selection(String(repeating: "a", count: 120)).chip == "Selection · 120 characters")
    #expect(AIContext.tooLong(12345).chip == "Note too long (12,345 characters) · select a part")
    #expect(AIContext.none.chip == nil)
}
