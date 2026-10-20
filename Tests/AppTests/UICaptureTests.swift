import AppKit
import Foundation
import NotesCore
import SwiftUI
import Testing

@testable import App

/// Run through `scripts/ui-capture.sh`; without `UI_CAPTURE_DIR` it does nothing.
@MainActor
struct UICaptureTests {
    @Test(.enabled(if: Capture.enabled))
    func captureSettingsTabs() throws {
        Capture.prepareApp()
        let window = NSWindow(contentViewController: NSHostingController(rootView: makeSettingsView()))
        window.title = "Settings"
        window.setContentSize(NSSize(width: 800, height: 700))
        Capture.lower(window)
        defer { window.orderOut(nil) }
        Capture.wait()

        let tabView = try #require(findTabView(in: window.contentView))
        let only = ProcessInfo.processInfo.environment["UI_CAPTURE_TAB"].flatMap { $0.isEmpty ? nil : $0 }
        let items = tabView.tabViewItems.filter { only == nil || $0.label == only }
        #expect(!items.isEmpty)
        for item in items {
            tabView.selectTabViewItem(item)
            Capture.wait()
            try Capture.capture(window, as: "settings-\(item.label.replacingOccurrences(of: " ", with: "-"))")
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
}
