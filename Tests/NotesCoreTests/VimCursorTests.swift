import Foundation
import Testing
@testable import NotesCore

@Test(arguments: [(VimMode.normal, VimCursorShape.block), (.visual, .block), (.visualLine, .block), (.insert, .bar)])
func modeBasedShape(mode: VimMode, shape: VimCursorShape) {
    #expect(vimCursorShape(mode: mode, setting: .modeBased) == shape)
}

@Test(arguments: [VimMode.normal, .insert, .visual, .visualLine])
func alwaysBarShape(mode: VimMode) {
    #expect(vimCursorShape(mode: mode, setting: .alwaysBar) == .bar)
}

@Test func cursorSettingDefaultsPersistsAndFallsBack() {
    let name = "test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let toggles = FeatureToggles(defaults: defaults)
    #expect(toggles.vimCursorShape == .modeBased)
    toggles.vimCursorShape = .alwaysBar
    #expect(FeatureToggles(defaults: defaults).vimCursorShape == .alwaysBar)
    defaults.set("nonsense", forKey: "vimCursorShape")
    #expect(FeatureToggles(defaults: defaults).vimCursorShape == .modeBased)
}
