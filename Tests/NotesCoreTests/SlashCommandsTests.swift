import Foundation
import Testing
@testable import NotesCore

private func items(_ titles: String...) -> [SlashItem] {
    titles.map { SlashItem(title: $0, action: .template($0)) }
}

// AC1
@Test func emptyQueryListsEverythingInSourceOrder() {
    let all = items("Meeting", "Daily") + SlashItem.builtIns
    #expect(filterSlashItems(all, query: "") == all)
}

@Test func matchingIgnoresCase() {
    #expect(filterSlashItems(items("Meeting", "Daily"), query: "mEEt").map(\.title) == ["Meeting"])
}

@Test func prefixMatchesRankFirstAndTiesKeepSourceOrder() {
    let all = items("Weekly heading", "Heading notes", "Subheading", "Head start")
    #expect(filterSlashItems(all, query: "head").map(\.title) == ["Heading notes", "Head start", "Weekly heading", "Subheading"])
}

@Test func nfdQueryMatchesNfcTitle() {
    let title = "회의록".precomposedStringWithCanonicalMapping
    let query = "회의".decomposedStringWithCanonicalMapping
    #expect(query.unicodeScalars.count != "회의".precomposedStringWithCanonicalMapping.unicodeScalars.count)
    #expect(filterSlashItems(items(title), query: query).map(\.title) == [title])
}

@Test func queryMatchingNothingReturnsNothing() {
    #expect(filterSlashItems(items("Meeting") + SlashItem.builtIns, query: "zzz").isEmpty)
}

@Test func builtInsAreNotesFormatStylesInMenuOrder() {
    #expect(SlashItem.builtIns.map(\.title) == [
        "Title", "Heading", "Subheading", "Body", "Monostyled",
        "Bulleted list", "Dashed list", "Numbered list", "Checklist", "Block quote",
    ])
}

// AC2
private func typeSlash(after before: String, then after: String = "") -> NSRange? {
    slashTrigger(previous: TextSnapshot(text: before + after, caret: before.utf16.count),
                 current: TextSnapshot(text: before + "/" + after, caret: before.utf16.count + 1))
}

@Test func slashAtLineStartOrAfterSpaceTriggers() {
    #expect(typeSlash(after: "") == NSRange(location: 0, length: 1))
    #expect(typeSlash(after: "first\n", then: "\nlast") == NSRange(location: 6, length: 1))
    #expect(typeSlash(after: "word ") == NSRange(location: 5, length: 1))
}

@Test func slashInsideTextOrUrlDoesNotTrigger() {
    #expect(typeSlash(after: "a", then: "b") == nil)
    #expect(typeSlash(after: "http:") == nil)
    #expect(typeSlash(after: "http:/") == nil)
}

@Test func pastedSlashDoesNotTrigger() {
    let previous = TextSnapshot(text: "x ", caret: 2)
    #expect(slashTrigger(previous: previous, current: TextSnapshot(text: "x /a", caret: 4)) == nil)
    #expect(slashTrigger(previous: TextSnapshot(text: "x /", caret: 0), current: TextSnapshot(text: "x /", caret: 3)) == nil)
}

@Test func otherCharacterTypedDoesNotTrigger() {
    #expect(slashTrigger(previous: TextSnapshot(text: "", caret: 0), current: TextSnapshot(text: "a", caret: 1)) == nil)
}

// AC3
@Test func strippingFirstLineKeepsTheRestUnchanged() {
    let rest = "<div><b>Bold</b> and <i>italic</i></div>\n<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n<div><br></div>\n"
    #expect(strippingFirstLine(html: "<div><h1>Recipe</h1></div>\n" + rest) == rest)
    #expect(strippingFirstLine(html: "<div>Title<br></div>\n" + rest) == rest)
    #expect(strippingFirstLine(html: "<div><div>Nested</div></div>" + rest) == rest)
    #expect(strippingFirstLine(html: "<h1>Only</h1>") == "")
}

@Test func strippingFirstLineOfPlainText() {
    #expect(strippingFirstLine(plainText: "Title\nline 1\nline 2") == "line 1\nline 2")
    #expect(strippingFirstLine(plainText: "Title") == "")
}

// AC4
@MainActor @Test func registeredCommandsAreListedOnlyWhileVisible() {
    let registry = SlashCommandRegistry()
    var aiOn = false
    registry.register("AI", isVisible: { aiOn }) {}
    registry.register("Always") {}
    #expect(registry.items == [SlashItem(title: "Always", action: .command(1))])
    aiOn = true
    #expect(registry.items.map(\.title) == ["AI", "Always"])
}

@Test func queryIsTheTextBetweenSlashAndCaret() {
    #expect(slashQuery(text: "a /head", slashOffset: 2, caret: 3) == "")
    #expect(slashQuery(text: "a /head", slashOffset: 2, caret: 7) == "head")
    #expect(slashQuery(text: "a /제목 rest", slashOffset: 2, caret: 5) == "제목")
}

@Test func queryIsNilWhenTheMenuShouldClose() {
    #expect(slashQuery(text: "a head", slashOffset: 2, caret: 4) == nil)
    #expect(slashQuery(text: "a /head", slashOffset: 2, caret: 2) == nil)
    #expect(slashQuery(text: "a /head", slashOffset: 2, caret: 1) == nil)
    #expect(slashQuery(text: "a /he ad", slashOffset: 2, caret: 8) == nil)
    #expect(slashQuery(text: "a /", slashOffset: 5, caret: 3) == nil)
}

@Test func groupsAreTemplatesStylesCommandsWithoutEmptySections() {
    let template = SlashItem(title: "Meeting", action: .template("1"))
    let command = SlashItem(title: "AI", action: .command(0))
    let groups = groupSlashItems([command, SlashItem.builtIns[0], template, SlashItem.builtIns[1]])
    #expect(groups.map(\.section) == [.templates, .styles, .commands])
    #expect(groups[1].items.map(\.title) == ["Title", "Heading"])
    #expect(groupSlashItems(SlashItem.builtIns).map(\.section) == [.styles])
}

@Test func styleShortcutsComeFromKeyEquivalents() {
    #expect(NotesStyle.heading.shortcut == "⇧⌘H")
    #expect(NotesStyle.blockQuote.shortcut == "⌘'")
    #expect(SlashItem(title: "Meeting", action: .template("1")).shortcut == nil)
    #expect(SlashItem(title: "AI", action: .command(0)).shortcut == nil)
    #expect(SlashItem.builtIns[1].shortcut == "⇧⌘H")
}

@Test func menuIsClosedOnlyForAQueryThatMatchesNothing() {
    #expect(slashMenuStaysOpen(SlashItem.builtIns, query: ""))
    #expect(slashMenuStaysOpen(SlashItem.builtIns, query: "head"))
    #expect(!slashMenuStaysOpen(SlashItem.builtIns, query: "zzz"))
}

@Test func templateFolderDefaultsToTemplatesAndPersists() {
    let name = "test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(FeatureToggles(defaults: defaults).templateFolder == "Templates")
    FeatureToggles(defaults: defaults).templateFolder = "Snippets"
    #expect(FeatureToggles(defaults: defaults).templateFolder == "Snippets")
}

// Issue #178
private func tableItems(_ query: String) -> [SlashItem] {
    filterSlashItems(SlashItem.builtIns + [.table], query: query)
}

@Test func tableOffersADefaultThreeByThree() {
    #expect(tableItems("table") == [.table])
    #expect(SlashItem.table.action == .table(columns: 3, rows: 3))
}

@Test func tableSizeSetsColumnsByRows() {
    #expect(tableItems("table4x2").map(\.action) == [.table(columns: 4, rows: 2)])
    #expect(tableItems("table1x1").map(\.action) == [.table(columns: 1, rows: 1)])
    #expect(tableItems("table10x20").map(\.action) == [.table(columns: 10, rows: 20)])
}

@Test func invalidTableSizesAddNoSizedItem() {
    for query in ["table0x3", "table11x3", "table3x21", "table3x", "table3", "tablexyz"] {
        #expect(tableSize(query: query) == nil)
        #expect(!tableItems(query).contains { $0.title.contains("×") })
    }
}

@Test func tableHTMLIsOnlyTheRequestedCells() {
    let html = tableHTML(columns: 4, rows: 2)
    #expect(html.hasPrefix("<table>") && html.hasSuffix("</table>"))
    #expect(html.components(separatedBy: "<tr>").count - 1 == 2)
    #expect(html.components(separatedBy: "<td></td>").count - 1 == 8)
    let rest = ["<table>", "</table>", "<tr>", "</tr>", "<td></td>"].reduce(html) { $0.replacing($1, with: "") }
    #expect(rest.isEmpty)
}
