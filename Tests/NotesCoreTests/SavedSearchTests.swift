import Foundation
import Testing
@testable import NotesCore

@Test func parserTakesTheConditionsOutOfTheWords() {
    let plain = ParsedQuery("budget in:Work since:7d")
    #expect(plain.words == "budget" && plain.folder == "Work" && plain.days == 7)
    let quoted = ParsedQuery("in:\"Work Notes\" budget plan")
    #expect(quoted.words == "budget plan" && quoted.folder == "Work Notes" && quoted.days == nil)
    let none = ParsedQuery("just words")
    #expect(none.words == "just words" && !none.hasConditions)
}

private func note(_ id: String, folder: String, daysAgo: Double, now: Date) -> SearchResult {
    SearchResult(id: id, title: id, folder: folder, modified: now.addingTimeInterval(-daysAgo * 86400), snippet: "", ownerIdentifier: nil)
}

@Test func conditionsKeepOnlyMatchingHits() {
    let now = Date()
    let hits = [note("a", folder: "Work", daysAgo: 1, now: now), note("b", folder: "Home", daysAgo: 1, now: now),
                note("c", folder: "Work", daysAgo: 30, now: now)]
    let ids = { (q: String) in hits.filter { ParsedQuery(q).keeps($0, now: now) }.map(\.id) }
    #expect(ids("x in:work") == ["a", "c"])
    #expect(ids("x since:7d") == ["a", "b"])
    #expect(ids("x in:Work since:7d") == ["a"])
    #expect(ids("x") == ["a", "b", "c"])
}

@Test func conditionalPanelSearchFiltersAFixtureIndex() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite")
    let index = try SearchIndex(url: url)
    let now = Date()
    try index.upsert([
        IndexedNote(id: "a", title: "Budget", folder: "Work", modified: now, body: "budget plan", owner: ""),
        IndexedNote(id: "b", title: "Budget", folder: "Home", modified: now, body: "budget plan", owner: ""),
        IndexedNote(id: "c", title: "Budget", folder: "Work", modified: now.addingTimeInterval(-30 * 86400), body: "budget plan", owner: ""),
    ])
    func ids(_ q: String) throws -> [String] { try index.conditionalPanelSearch(q, embedder: nil).map(\.note.id).sorted() }
    #expect(try ids("budget") == ["a", "b", "c"])
    #expect(try ids("budget in:Work") == ["a", "c"])
    #expect(try ids("budget since:7d") == ["a", "b"])
    #expect(try ids("budget in:Work since:7d") == ["a"])
}

@Test func savedSearchesPersistInOrderAndReplaceByName() {
    let name = "test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let toggles = FeatureToggles(defaults: defaults)
    toggles.savedSearches.save(SavedSearch(name: "a", query: "one"))
    toggles.savedSearches.save(SavedSearch(name: "b", query: "two"))
    toggles.savedSearches.save(SavedSearch(name: "a", query: "three"))
    #expect(FeatureToggles(defaults: defaults).savedSearches.map(\.query) == ["three", "two"])
}
