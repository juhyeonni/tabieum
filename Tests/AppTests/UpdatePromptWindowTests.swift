import AppKit
import NotesCore
import Testing

@testable import App

@MainActor
struct UpdatePromptWindowTests {
    private func make(_ titles: [String], notes: [NotesBlock] = []) -> UpdatePromptWindow {
        UpdatePromptWindow(title: "T", text: "Body", notes: notes, buttonTitles: titles)
    }

    @Test func showsTitleTextAndButtonsInOrder() {
        let w = make(["Install and Relaunch", "Open Release Page", "Later"])
        #expect(w.window.title == "T")
        #expect(w.buttons.map(\.title) == ["Install and Relaunch", "Open Release Page", "Later"])
        let labels = w.window.contentView?.descendants(of: NSTextField.self).map(\.stringValue)
        #expect(labels?.contains("Body") == true)
    }

    @Test(arguments: [3, 2]) func firstIsDefaultAndLastIsEscape(count: Int) {
        let w = make((0..<count).map { "B\($0)" })
        #expect(w.buttons.first?.keyEquivalent == "\r")
        #expect(w.buttons.last?.keyEquivalent == "\u{1b}")
        #expect(w.buttons.dropFirst().dropLast().allSatisfy { $0.keyEquivalent.isEmpty })
    }

    @Test func pressingAButtonChoosesItsIndex() {
        let w = make(["Install and Relaunch", "Open Release Page", "Later"])
        w.buttons[2].performClick(nil)
        #expect(w.chosen == 2)
        w.buttons[0].performClick(nil)
        #expect(w.chosen == 0)
    }

    @Test func notesBoxExistsOnlyWithNotes() {
        #expect(make(["Close"]).notesView == nil)
        let w = make(["Close"], notes: [.paragraph("Fixed things")])
        #expect(w.notesView?.hasVerticalScroller == true)
        #expect(w.window.contentView?.descendants(of: NSScrollView.self).count == 1)
    }
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + subviews.flatMap { $0.descendants(of: type) }
    }
}
