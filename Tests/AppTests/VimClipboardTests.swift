import AppKit
import Testing

@testable import App

@MainActor
struct VimClipboardTests {
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("vim-clipboard-\(UUID().uuidString)"))
        board.clearContents()
        board.setString("before", forType: .string)
        return board
    }

    @Test func yanksArePlainCopiesAndTheLastOneWins() {
        let board = pasteboard()
        VimController.copy(["one\n", "two"], enabled: true, to: board)
        #expect(board.string(forType: .string) == "two")
        let types = board.types ?? []
        #expect(!types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
        #expect(!types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
        board.releaseGlobally()
    }

    @Test func yanksLeaveTheClipboardAloneWhenTheSettingIsOff() {
        let board = pasteboard()
        VimController.copy(["one\n"], enabled: false, to: board)
        #expect(board.string(forType: .string) == "before")
        board.releaseGlobally()
    }
}
