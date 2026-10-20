import CoreGraphics
import Testing
@testable import NotesCore

@Suite struct FormatToolbarTests {
    @Test func showsOnlyForASelectionWithFocusAndTheOptionOn() {
        #expect(shouldShowFormatToolbar(selectionLength: 3, isFocused: true, enabled: true))
        #expect(!shouldShowFormatToolbar(selectionLength: 0, isFocused: true, enabled: true))
        #expect(!shouldShowFormatToolbar(selectionLength: nil, isFocused: true, enabled: true))
        #expect(!shouldShowFormatToolbar(selectionLength: 3, isFocused: false, enabled: true))
        #expect(!shouldShowFormatToolbar(selectionLength: 3, isFocused: true, enabled: false))
    }

    @Test func sitsAboveTheSelection() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = formatToolbarFrame(selection: CGRect(x: 400, y: 300, width: 100, height: 20), size: CGSize(width: 200, height: 30), visible: visible)
        #expect(frame.minY == 326)
        #expect(frame.midX == 450)
    }

    @Test func fallsBelowWhenThereIsNoRoomAboveAndStaysOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 200, height: 30)
        let below = formatToolbarFrame(selection: CGRect(x: 400, y: 770, width: 100, height: 20), size: size, visible: visible)
        #expect(below.maxY == 764)
        let corner = formatToolbarFrame(selection: CGRect(x: 980, y: 5, width: 20, height: 10), size: size, visible: visible)
        #expect(visible.contains(corner))
    }
}
