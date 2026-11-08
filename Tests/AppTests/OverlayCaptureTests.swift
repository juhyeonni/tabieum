import AppKit
import NotesCore
import Testing

@testable import App

/// Run through `scripts/ui-capture.sh overlays`; without `UI_CAPTURE_DIR` this does nothing.
@MainActor
struct OverlayCaptureTests {
    private static let overlayLevel = -9
    private static let caret = NSRange(location: 20, length: 0)

    @Test(.enabled(if: Capture.enabled))
    func captureOverlays() throws {
        Capture.prepareApp()
        let suite = "ui-capture-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let editor = StandInEditor()
        defer { editor.window.orderOut(nil) }
        let tracker = TextFocusTracker(source: editor.source(selection: Self.caret))
        let toggles = FeatureToggles(defaults: defaults)

        let action = ActionButton(tracker: tracker, toggles: toggles, perform: { _ in })
        defer { action.panel.orderOut(nil) }
        action.panel.level = NSWindow.Level(rawValue: Self.overlayLevel)

        let caretOverlay = CaretOverlay(tracker: tracker)
        caretOverlay.window.level = NSWindow.Level(rawValue: Self.overlayLevel)
        caretOverlay.set(true)
        Capture.wait()
        try Capture.composite(base: editor.window, overlays: [caretOverlay.window, action.panel], as: "overlays-caret-action")
        caretOverlay.set(false)

        let vim = VimController(tracker: tracker, toggles: toggles)
        vim.indicator.panel.level = NSWindow.Level(rawValue: Self.overlayLevel)
        vim.cursorBlock.window.level = NSWindow.Level(rawValue: Self.overlayLevel)
        defer {
            vim.indicator.hide()
            vim.cursorBlock.hide()
        }
        let overlays = [vim.cursorBlock.window, vim.indicator.panel, action.panel]

        vim.render(tracker.state)
        Capture.wait()
        try Capture.composite(base: editor.window, overlays: overlays, as: "overlays-vim-normal")

        vim.engine = VimEngine(mode: .insert)
        vim.latencyText = "last 3ms · p90 5ms"
        vim.render(tracker.state)
        Capture.wait()
        try Capture.composite(base: editor.window, overlays: overlays, as: "overlays-vim-insert")
    }
}
