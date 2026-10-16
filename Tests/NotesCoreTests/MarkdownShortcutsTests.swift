import Foundation
import Testing
@testable import NotesCore

private let all = Set(MarkdownStyle.allCases)

/// Types `typed` one character at a time at the end of `before`, ahead of `after`, and returns every match.
private func type(_ typed: String, before: String = "first line\n", after: String = "\nlast line",
                  enabled: Set<MarkdownStyle> = all) -> [MarkdownMatch] {
    var snapshot = TextSnapshot(text: before + after, caret: before.utf16.count)
    var matches: [MarkdownMatch] = []
    var line = ""
    for character in typed {
        line.append(character)
        let next = TextSnapshot(text: before + line + after, caret: (before + line).utf16.count)
        if let match = markdownMatch(previous: snapshot, current: next, enabled: enabled) { matches.append(match) }
        snapshot = next
    }
    return matches
}

// AC1
@Test(arguments: MarkdownStyle.allCases)
func eachMarkerTypedOnAnEmptyLineMatches(style: MarkdownStyle) {
    let before = "first line\n"
    let range = NSRange(location: before.utf16.count, length: style.marker.utf16.count)
    #expect(type(style.marker, before: before) == [MarkdownMatch(style: style, range: range)])
}

@Test func markerOnTheFirstLineMatches() {
    #expect(type("# ", before: "", after: "") == [MarkdownMatch(style: .title, range: NSRange(location: 0, length: 2))])
}

// AC2
@Test func markerAfterOtherTextDoesNotMatch() {
    #expect(type("# ", before: "first line\nword ").isEmpty)
}

@Test func caretMovedAfterExistingMarkerDoesNotMatch() {
    let text = "first line\n# \nlast"
    let previous = TextSnapshot(text: text, caret: 0)
    let current = TextSnapshot(text: text, caret: 13)
    #expect(markdownMatch(previous: previous, current: current, enabled: all) == nil)
}

@Test func pastedMarkerDoesNotMatch() {
    let previous = TextSnapshot(text: "first line\n", caret: 11)
    let current = TextSnapshot(text: "first line\n# ", caret: 13)
    #expect(markdownMatch(previous: previous, current: current, enabled: all) == nil)
}

@Test func deletingBackToAMarkerDoesNotMatch() {
    let previous = TextSnapshot(text: "# x", caret: 3)
    let current = TextSnapshot(text: "# ", caret: 2)
    #expect(markdownMatch(previous: previous, current: current, enabled: all) == nil)
}

// AC3
@Test func backticksThenReturnCoverTheNewline() {
    #expect(type("```\n", before: "a\n", after: "") == [MarkdownMatch(style: .monostyled, range: NSRange(location: 2, length: 4))])
}

@Test func backticksFollowedByOtherCharactersDoNotMatch() {
    #expect(type("```a\n").isEmpty)
    #expect(type("``` \n").isEmpty)
    #expect(type("```swift").isEmpty)
}

// AC4
@Test(arguments: MarkdownStyle.allCases)
func disabledTriggerNeverMatches(style: MarkdownStyle) {
    var enabled = all
    enabled.remove(style)
    #expect(type(style.marker, enabled: enabled).isEmpty)
}

@Test func markdownTogglesAreOnByDefaultAndPersist() {
    let name = "test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let toggles = FeatureToggles(defaults: defaults)
    #expect(toggles.markdownStyles == all)
    toggles.markdownStyles.remove(.blockQuote)
    #expect(FeatureToggles(defaults: defaults).markdownStyles == all.subtracting([.blockQuote]))
}
