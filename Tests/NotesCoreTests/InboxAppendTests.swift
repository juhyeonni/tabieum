import Foundation
import Testing
@testable import NotesCore

private final class FakeInbox: InboxWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var hasNote = false

    var calls: [String] { lock.withLock { log } }

    func append(html: String, toNoteTitled title: String) async throws -> Bool {
        lock.withLock { log.append("append \(title) \(html)") }
        return hasNote
    }

    func createNote(titled title: String, html: String) async throws {
        lock.withLock { log.append("create \(title) \(html)") }
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
    #expect(toggles.appendShortcut.display == "⌃⌥⌘A")
    toggles.inboxTitle = "Capture"
    toggles.appendShortcut = Shortcut(keyCode: 1, modifiers: [.command, .shift])
    let reloaded = FeatureToggles(defaults: defaults)
    #expect(reloaded.inboxTitle == "Capture")
    #expect(reloaded.appendShortcut == Shortcut(keyCode: 1, modifiers: [.command, .shift]))
}
