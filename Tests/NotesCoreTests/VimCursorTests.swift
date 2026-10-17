import CoreGraphics
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

private let caret = CGRect(x: 10, y: 20, width: 1, height: 16)

private func blockRect(_ text: String, _ selection: NSRange, char: CGRect? = CGRect(x: 5, y: 6, width: 7, height: 8),
                       caret: CGRect? = caret, looked: ((NSRange) -> Void)? = nil) -> CGRect? {
    vimCursorBlockRect(text: text, selection: selection,
                       boundsFor: { looked?($0); return char }, caretRect: { caret })
}

@Test func blockOnNormalCharacter() {
    #expect(blockRect("abc", NSRange(location: 1, length: 0)) == CGRect(x: 5, y: 6, width: 7, height: 8))
}

@Test(arguments: ["가나", "a😀b"])
func blockLooksUpWholeComposedCharacter(text: String) {
    var range = NSRange()
    let rect = blockRect(text, NSRange(location: 1, length: 0), looked: { range = $0 })
    #expect(rect == CGRect(x: 5, y: 6, width: 7, height: 8))
    #expect(range == (text as NSString).rangeOfComposedCharacterSequence(at: 1))
}

@Test func blockOfSelectionIsItsLastCharacter() {
    var range = NSRange()
    _ = blockRect("abcd", NSRange(location: 1, length: 2), looked: { range = $0 })
    #expect(range == NSRange(location: 2, length: 1))
}

@Test func blockOnEmptyLineStartsAtCaretLeft() {
    #expect(blockRect("a\n\nb", NSRange(location: 2, length: 0)) == CGRect(x: 10, y: 20, width: 8, height: 16))
}

@Test func blockAtEndOfNoteStartsAtCaretRight() {
    #expect(blockRect("abc", NSRange(location: 3, length: 0)) == CGRect(x: 11, y: 20, width: 8, height: 16))
}

@Test func blockIsNilWithoutAnyRect() {
    #expect(blockRect("abc", NSRange(location: 3, length: 0), char: nil, caret: nil) == nil)
    #expect(blockRect("abc", NSRange(location: 1, length: 0), char: nil, caret: nil) == nil)
}

@Test func zeroSizeCharacterRectFallsBackToLineRule() {
    #expect(blockRect("abc", NSRange(location: 1, length: 0), char: CGRect(x: 1, y: 1, width: 0, height: 0))
        == CGRect(x: 11, y: 20, width: 8, height: 16))
}
