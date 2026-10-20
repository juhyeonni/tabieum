import AppKit
import Testing

@testable import App

@MainActor
struct StatusMenuTests {
    @Test func listsTheStatusItemsInOrder() {
        let embedding = NSMenuItem()
        let menu = makeStatusMenu(
            name: "tabieum", embeddingItem: embedding, target: NSObject(),
            showSettings: Selector(("showSettings")), checkForUpdates: Selector(("checkForUpdates")))
        let items = menu.items

        #expect(items.count == 5)
        #expect(items[0].title == "Settings…")
        #expect(items[0].keyEquivalent == ",")
        #expect(items[1] === embedding)
        #expect(items[1].isHidden)
        #expect(!items[1].isEnabled)
        #expect(items[2].isSeparatorItem)
        #expect(items[3].title == "Check for Updates…")
        #expect(items[3].keyEquivalent == "")
        #expect(items[4].title == "Quit tabieum")
        #expect(items[4].keyEquivalent == "q")
    }
}
