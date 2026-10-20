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

// Date commands
private func dateCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return calendar
}

private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 10, _ min: Int = 10) -> Date {
    dateCalendar().date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func texts(_ now: Date) -> [String] {
    SlashItem.dates(now: now, calendar: dateCalendar()).map { item in
        guard case let .insert(text) = item.action else { return "" }
        return text
    }
}

@Test func dateCommandsGiveIsoDatesAndNow() {
    #expect(SlashItem.dates(now: day(2026, 10, 20), calendar: dateCalendar()).map(\.title) == ["Today", "Tomorrow", "Yesterday", "Now"])
    #expect(texts(day(2026, 10, 20)) == ["2026-10-20", "2026-10-21", "2026-10-19", "2026-10-20 10:10"])
    #expect(texts(day(2026, 10, 20, 9, 5))[3] == "2026-10-20 09:05")
}

@Test func dateCommandsCrossMonthAndYear() {
    #expect(texts(day(2026, 12, 31))[1] == "2027-01-01")
    #expect(texts(day(2026, 3, 1))[2] == "2026-02-28")
}

@Test func timedDateQueries() {
    let now = day(2026, 10, 20)
    func text(_ query: String) -> String? {
        guard case let .insert(text)? = SlashItem.timedDate(query: query, now: now, calendar: dateCalendar())?.action else { return nil }
        return text
    }
    #expect(text("today1010") == "2026-10-20 10:10")
    #expect(text("tomorrow0930") == "2026-10-21 09:30")
    #expect(text("yesterday2359") == "2026-10-19 23:59")
    #expect(SlashItem.timedDate(query: "today1010", now: now, calendar: dateCalendar())?.title == "Today 10:10")
    for bad in ["today2460", "today1060", "today99", "today10100", "now1010", "todayabc", "today"] {
        #expect(text(bad) == nil)
    }
}
