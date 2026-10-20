import AppKit
import NotesCore
import Testing

@testable import App

/// The editor frame is far off screen, so these overlays never show up on a real display.
@MainActor
@Suite(.enabled(if: !NSScreen.screens.isEmpty))
struct VimRenderTests {
    private static let frame = CGRect(x: 50_000, y: 50_000, width: 400, height: 300)

    private func makeVim() -> (vim: VimController, tracker: TextFocusTracker) {
        let source = FakeTextFocusSource(
            frame: Self.frame, text: "Weekly meeting", selection: NSRange(location: 3, length: 0),
            boundsFor: { _ in CGRect(x: 50_010, y: 50_010, width: 8, height: 16) })
        let tracker = TextFocusTracker(source: source)
        let defaults = UserDefaults(suiteName: "vim-render-\(UUID().uuidString)")!
        let vim = VimController(tracker: tracker, toggles: FeatureToggles(defaults: defaults))
        return (vim, tracker)
    }

    private func modeText(_ vim: VimController) -> String? {
        (vim.indicator.panel.contentView as? NSTextField)?.stringValue.trimmingCharacters(in: .whitespaces)
    }

    private func hide(_ vim: VimController) {
        vim.indicator.hide()
        vim.cursorBlock.hide()
    }

    @Test func rendersTheNormalModePanelAndBlockCursorWithoutATap() {
        let (vim, tracker) = makeVim()
        defer { hide(vim) }

        vim.render(tracker.state)

        #expect(vim.indicator.panel.isVisible)
        #expect(modeText(vim) == "-- NORMAL --")
        #expect(vim.cursorBlock.window.isVisible)
    }

    @Test func rendersTheInsertModePanelWithLatencyAndNoBlockCursor() {
        let (vim, tracker) = makeVim()
        defer { hide(vim) }
        vim.engine = VimEngine(mode: .insert)
        vim.latencyText = "last 3ms · p90 5ms"

        vim.render(tracker.state)

        #expect(modeText(vim) == "-- INSERT -- last 3ms · p90 5ms")
        #expect(!vim.cursorBlock.window.isVisible)
    }

    @Test func refreshDrawsNothingWithoutATap() {
        let (vim, tracker) = makeVim()
        defer { hide(vim) }

        vim.refresh(tracker.state)

        #expect(!vim.indicator.panel.isVisible)
        #expect(!vim.cursorBlock.window.isVisible)
    }
}
