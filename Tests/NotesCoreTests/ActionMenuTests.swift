import CoreGraphics
import Testing
@testable import NotesCore

@Suite struct ActionMenuTests {
    @Test func buttonSitsInsideTheFrameAtItsBottomRight() {
        let size = CGSize(width: 28, height: 28)
        for frame in [CGRect(x: 100, y: 50, width: 800, height: 600), CGRect(x: -300, y: 20, width: 200, height: 90)] {
            let rect = actionButtonRect(in: frame, size: size)
            #expect(frame.contains(rect))
            #expect(rect.size == size)
            #expect(frame.maxX - rect.maxX == 8)
            #expect(frame.maxY - rect.maxY == 8)
        }
    }

    @Test func modelListsTheTitleThenTheFiveActions() {
        let model = ActionMenuModel(title: "Groceries", ambiguous: false)
        #expect(model.header == "Groceries")
        #expect(model.items.map(\.title) == ["Copy as Markdown", "Copy Deeplink", "Backlinks", "Ask my notes…", "Settings…"])
    }

    @Test func ambiguousTitleIsFlaggedNextToTheTitle() {
        #expect(ActionMenuModel(title: "Ideas", ambiguous: true).header == "Ideas (another note has this title)")
        #expect(ActionMenuModel(title: nil, ambiguous: false).header == "No note open")
    }
}
