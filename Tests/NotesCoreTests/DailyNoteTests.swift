import Foundation
import Testing
@testable import NotesCore

@MainActor
private final class FakeStore: DailyNoteStore {
    var existing: String?
    var template: String?
    var created: [String] = []
    var shown: [String] = []

    func existingNote(titled title: String) throws -> String? { existing }
    func dailyTemplate() throws -> String? { template }
    func create(html: String) throws -> String {
        created.append(html)
        return "new"
    }
    func show(_ handle: String) throws { shown.append(handle) }
}

private let noon = Date(timeIntervalSince1970: 1_793_966_400)  // 2026-11-06 12:00 UTC
private let utc = TimeZone(identifier: "UTC")!

@Test func dailyTitleIsIsoDateInTheGivenTimeZone() {
    let lateEvening = noon.addingTimeInterval(11.5 * 3600)
    #expect(DailyNote.title(for: noon, in: utc) == "2026-11-06")
    #expect(DailyNote.title(for: lateEvening, in: utc) == "2026-11-06")
    #expect(DailyNote.title(for: lateEvening, in: TimeZone(identifier: "Asia/Seoul")!) == "2026-11-07")
    #expect(DailyNote.title(for: lateEvening, in: TimeZone(identifier: "America/Los_Angeles")!) == "2026-11-06")
}

@MainActor @Test func dailyNoteWithoutTemplateHoldsOnlyTheTitle() throws {
    let store = FakeStore()
    #expect(try DailyNote.open(now: noon, in: utc, store: store) == .created)
    #expect(store.created == ["<div><h1>2026-11-06</h1></div>"])
    #expect(store.shown == ["new"])
}

@MainActor @Test func dailyNoteTemplateReplacesItsFirstLineWithTheTitle() throws {
    let store = FakeStore()
    store.template = "<div><h1>Daily</h1></div>\n<div>Plan</div><ul><li>one</li></ul>"
    _ = try DailyNote.open(now: noon, in: utc, store: store)
    #expect(store.created == ["<div><h1>2026-11-06</h1></div><div>Plan</div><ul><li>one</li></ul>"])
}

@MainActor @Test func dailyNoteThatExistsIsOpenedAndNeverCreatedAgain() throws {
    let store = FakeStore()
    store.existing = "old"
    #expect(try DailyNote.open(now: noon, in: utc, store: store) == .opened)
    #expect(store.created.isEmpty)
    #expect(store.shown == ["old"])
}

@Test func dailyNoteShortcutDefaultsAndPersists() {
    let name = "test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    #expect(FeatureToggles(defaults: defaults).dailyNoteShortcut.display == "⌃⌥⌘D")
    let custom = Shortcut(keyCode: 1, modifiers: [.command, .shift])
    FeatureToggles(defaults: defaults).dailyNoteShortcut = custom
    #expect(FeatureToggles(defaults: defaults).dailyNoteShortcut == custom)
}
