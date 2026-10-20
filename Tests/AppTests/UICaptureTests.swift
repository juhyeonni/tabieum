import AppKit
import Foundation
import NotesCore
import SwiftUI
import Testing

@testable import App

private let env = ProcessInfo.processInfo.environment

/// Run through `scripts/ui-capture.sh`; without `UI_CAPTURE_DIR` it does nothing.
@MainActor
struct UICaptureTests {
    @Test(.enabled(if: env["UI_CAPTURE_DIR"] != nil))
    func captureSettingsTabs() throws {
        let dir = URL(fileURLWithPath: try #require(env["UI_CAPTURE_DIR"]))
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentViewController: NSHostingController(rootView: makeSettingsView()))
        window.title = "Settings"
        window.setContentSize(NSSize(width: 800, height: 700))
        window.level = NSWindow.Level(rawValue: -10)
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        wait()

        let tabView = try #require(findTabView(in: window.contentView))
        let only = env["UI_CAPTURE_TAB"].flatMap { $0.isEmpty ? nil : $0 }
        let items = tabView.tabViewItems.filter { only == nil || $0.label == only }
        #expect(!items.isEmpty)
        for item in items {
            tabView.selectTabViewItem(item)
            wait()
            let file = dir.appendingPathComponent("settings-\(item.label.replacingOccurrences(of: " ", with: "-")).png")
            try capture(window, to: file)
        }
    }

    private func makeSettingsView() -> SettingsView {
        let toggles = FeatureToggles()
        return SettingsView(
            status: PermissionStatus(), toggles: toggles, ai: AIFeature(toggles: toggles, factory: AISettings.makeProvider),
            embedding: EmbeddingState(), install: ModelInstall(), shortcuts: [],
            showOnboarding: {}, setRAG: { _ in }, chooseModel: { _ in }, retryInstall: {})
    }

    private func findTabView(in view: NSView?) -> NSTabView? {
        guard let view else { return nil }
        if let tabView = view as? NSTabView { return tabView }
        for subview in view.subviews {
            if let found = findTabView(in: subview) { return found }
        }
        return nil
    }

    private func wait() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    private func capture(_ window: NSWindow, to file: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-l", String(window.windowNumber), "-o", file.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
