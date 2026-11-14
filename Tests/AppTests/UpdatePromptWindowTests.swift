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
        let prompt = make(["Install and Relaunch", "Open Release Page", "Later"])
        #expect(prompt.window.title == "T")
        #expect(prompt.buttons.map(\.title) == ["Install and Relaunch", "Open Release Page", "Later"])
        let labels = prompt.window.contentView?.descendants(of: NSTextField.self).map(\.stringValue)
        #expect(labels?.contains("Body") == true)
    }

    @Test(arguments: [3, 2]) func firstIsDefaultAndLastIsEscape(count: Int) {
        let prompt = make((0..<count).map { "B\($0)" })
        #expect(prompt.buttons.first?.keyEquivalent == "\r")
        #expect(prompt.buttons.last?.keyEquivalent == "\u{1b}")
        #expect(prompt.buttons.dropFirst().dropLast().allSatisfy { $0.keyEquivalent.isEmpty })
    }

    @Test func aSingleButtonStaysTheDefault() {
        #expect(make(["Close"]).buttons.first?.keyEquivalent == "\r")
    }

    @Test func pressingAButtonChoosesItsIndex() {
        let prompt = make(["Install and Relaunch", "Open Release Page", "Later"])
        prompt.buttons[2].performClick(nil)
        #expect(prompt.chosen == 2)
        prompt.buttons[0].performClick(nil)
        #expect(prompt.chosen == 0)
    }

    @Test func notesBoxExistsOnlyWithNotes() {
        #expect(make(["Close"]).notesView == nil)
        let prompt = make(["Close"], notes: [.paragraph("Fixed things")])
        #expect(prompt.notesView?.hasVerticalScroller == true)
        #expect(prompt.window.contentView?.descendants(of: NSScrollView.self).count == 1)
    }
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + subviews.flatMap { $0.descendants(of: type) }
    }
}
