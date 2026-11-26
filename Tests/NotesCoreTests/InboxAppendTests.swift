import Foundation
import Testing
@testable import NotesCore

private final class FakeInbox: InboxWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var hasNote = false
    var failure: Error?
    var appendFailure: Error?

    var calls: [String] { lock.withLock { log } }

    func append(html: String, toNoteTitled title: String) async throws -> Bool {
        if let appendFailure { throw appendFailure }
        lock.withLock { log.append("append \(title) \(html)") }
        return hasNote
    }

    func createNote(titled title: String, html: String) async throws {
        lock.withLock { log.append("create \(title) \(html)") }
        hasNote = true
    }

    func showNote(titled title: String) async throws -> Bool {
        if let failure { throw failure }
        lock.withLock { log.append("show \(title) \(hasNote)") }
        return hasNote
    }
}

@MainActor @Test func appendsToAnExistingNote() async {
    let writer = FakeInbox()
    writer.hasNote = true
    #expect(await AppendModel(text: "hi", title: "Inbox", writer: writer).submit())
    #expect(writer.calls == ["append Inbox <div>hi</div>"])
}

@MainActor @Test func createsTheNoteWhenItIsMissing() async {
    let writer = FakeInbox()
    #expect(await AppendModel(text: "hi", title: "Notes to file", writer: writer).submit())
    #expect(writer.calls == ["append Notes to file <div>hi</div>", "create Notes to file <div>hi</div>"])
}

@MainActor @Test func blankLinesWriteNothing() async {
    let writer = FakeInbox()
    #expect(!(await AppendModel(text: " \t", title: "Inbox", writer: writer).submit()))
    #expect(!(await AppendModel(title: "Inbox", writer: writer).submit()))
    #expect(writer.calls.isEmpty)
}

@MainActor @Test func openingWithBlankTextOnlyShowsTheNote() async {
    let writer = FakeInbox()
    writer.hasNote = true
    #expect(await AppendModel(text: " ", title: "Inbox", writer: writer).open())
    #expect(writer.calls == ["show Inbox true"])
}

@MainActor @Test func openingAppendsTheTypedLineFirst() async {
    let writer = FakeInbox()
    #expect(await AppendModel(text: "hi", title: "Inbox", writer: writer).open())
    #expect(writer.calls == ["append Inbox <div>hi</div>", "create Inbox <div>hi</div>", "show Inbox true"])
}

@MainActor @Test func openingCreatesAnEmptyNoteWhenItIsMissing() async {
    let writer = FakeInbox()
    #expect(await AppendModel(title: "Capture", writer: writer).open())
    #expect(writer.calls == ["show Capture false", "create Capture ", "show Capture true"])
}

@MainActor @Test func openingFailureKeepsTheText() async {
    let writer = FakeInbox()
    writer.failure = WriteFailure.automationDenied
    let model = AppendModel(text: "hi", title: "Inbox", writer: writer)
    #expect(!(await model.open()))
    #expect(model.text == "hi")
    #expect(model.error?.contains("Automation") == true)
}

@MainActor @Test func openingStopsWhenTheAppendFails() async {
    let writer = FakeInbox()
    writer.appendFailure = WriteFailure.failed("busy")
    let model = AppendModel(text: "hi", title: "Inbox", writer: writer)
    #expect(!(await model.open()))
    #expect(model.text == "hi")
    #expect(model.error != nil)
    #expect(writer.calls.isEmpty)
}

@MainActor @Test func captionNamesTheSecondPress() {
    let writer = FakeInbox()
    #expect(AppendModel(title: "Inbox", writer: writer).caption == "Adds to \"Inbox\"")
    let model = AppendModel(title: "Inbox", openShortcut: Shortcut.append.display, writer: writer)
    #expect(model.caption == "Adds to \"Inbox\" · ⌃⌥⌘I again to open")
}

@Test func lineHTMLIsEscaped() {
    #expect(NoteHTML.line("<b>x</b> & y") == "<div>&lt;b&gt;x&lt;/b&gt; &amp; y</div>")
}

@Test func parsesUrlActions() {
    let id = "0F8B1A7C-2D3E-4F50-8A9B-1C2D3E4F5A6B"
    func parse(_ string: String) -> TabieumAction? { URL(string: string).flatMap(TabieumURL.parse) }
    #expect(parse("tabieum://search?q=a%20b") == .search("a b"))
    #expect(parse("tabieum://open?id=\(id)") == .open(id))
    #expect(parse("tabieum://append?text=hi") == .append("hi"))
    #expect(parse("tabieum://nope?q=a") == nil)
    #expect(parse("tabieum://search") == nil)
    #expect(parse("tabieum://append?text=") == nil)
    #expect(parse("tabieum://open?id=123") == nil)
    #expect(parse("other://search?q=a") == nil)
    #expect(parse("tabieum://append?text=" + String(repeating: "a", count: 3000)) == .append(String(repeating: "a", count: 2000)))
}

@MainActor @Test func appendUrlFillsTheInputWithoutWriting() async {
    let writer = FakeInbox()
    guard case .append(let text)? = URL(string: "tabieum://append?text=hi").flatMap(TabieumURL.parse) else {
        Issue.record("not an append action")
        return
    }
    let model = AppendModel(text: text, title: "Inbox", writer: writer)
    #expect(model.text == "hi")
    #expect(writer.calls.isEmpty)
    _ = await model.submit()
    #expect(writer.calls.count == 2)
}

@Test func inboxSettingsPersist() {
    let name = "test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let toggles = FeatureToggles(defaults: defaults)
    #expect(toggles.inboxTitle == "Inbox")
    #expect(toggles.appendShortcut.display == "⌃⌥⌘I")
    toggles.inboxTitle = "Capture"
    toggles.appendShortcut = Shortcut(keyCode: 1, modifiers: [.command, .shift])
    let reloaded = FeatureToggles(defaults: defaults)
    #expect(reloaded.inboxTitle == "Capture")
    #expect(reloaded.appendShortcut == Shortcut(keyCode: 1, modifiers: [.command, .shift]))
}

@Test func defaultShortcutsUseDifferentKeys() {
    let codes = [
        Shortcut.default.keyCode, Shortcut.copyMarkdown.keyCode, Shortcut.copyLink.keyCode, Shortcut.dailyNote.keyCode,
        Shortcut.append.keyCode, UInt32(HotKey.aiDefault.keyCode),
    ]
    #expect(Set(codes).count == codes.count)
}
