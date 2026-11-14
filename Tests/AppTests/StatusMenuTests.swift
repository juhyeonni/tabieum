import AppKit
import Testing

@testable import App

@MainActor
struct StatusMenuTests {
    @Test func listsTheStatusItemsInOrder() {
        let embedding = NSMenuItem()
        let relaunch = NSMenuItem()
        let menu = makeStatusMenu(
            name: "Tabieum", version: "1.2.3", embeddingItem: embedding, relaunchItem: relaunch,
            target: NSObject(), showSettings: Selector(("showSettings")), checkForUpdates: Selector(("checkForUpdates")),
            relaunch: Selector(("relaunch")))
        let items = menu.items

        #expect(items.count == 7)
        #expect(items[0].title == "Settings…")
        #expect(items[0].keyEquivalent == ",")
        #expect(items[1] === embedding)
        #expect(items[1].isHidden)
        #expect(!items[1].isEnabled)
        #expect(items[2].isSeparatorItem)
        #expect(items[3] === relaunch)
        #expect(items[3].isHidden)
        #expect(items[3].action == Selector(("relaunch")))
        #expect(items[4].title == "Check for Updates…")
        #expect(items[4].keyEquivalent == "")
        #expect(items[5].title == "Tabieum 1.2.3")
        #expect(!items[5].isEnabled)
        #expect(items[5].action == nil)
        #expect(items[6].title == "Quit Tabieum")
        #expect(items[6].keyEquivalent == "q")
    }
}
