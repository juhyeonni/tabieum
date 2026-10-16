import AppKit
import NotesCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private let status = PermissionStatus()
    private let toggles = FeatureToggles()
    private lazy var ai = AIFeature(toggles: toggles, factory: AISettings.makeProvider)
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let tracker = TextFocusTracker(source: AXTextFocusSource())
    private lazy var caretOverlay = CaretOverlay(tracker: tracker)
    private var markdownShortcuts: MarkdownShortcuts?
    private var vim: VimController?
    private var slashCommands: SlashCommands?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let name = ProductInfo.main?.name ?? ProcessInfo.processInfo.processName
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: name)
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        let overlayItem = menu.addItem(withTitle: "Show Caret Overlay", action: #selector(toggleCaretOverlay(_:)), keyEquivalent: "")
        overlayItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        ai.config = AISettings.savedConfig()
        markdownShortcuts = MarkdownShortcuts(tracker: tracker, toggles: toggles)
        vim = VimController(tracker: tracker, toggles: toggles)
        slashCommands = SlashCommands(tracker: tracker, toggles: toggles)
        vim?.claimsKey = { [weak self] in self?.slashCommands?.claims(keyCode: $0) ?? false }

        Task {
            await status.refresh()
            if !status.allGranted { showOnboarding() }
        }
    }

    @objc private func showSettings() {
        let window = settingsWindow ?? makeWindow(title: "Settings", view: SettingsView(
            status: status, toggles: toggles, ai: ai, showOnboarding: { [weak self] in self?.showOnboarding() }))
        settingsWindow = window
        show(window)
    }

    private func showOnboarding() {
        let window = onboardingWindow ?? makeWindow(title: "Permissions", view: OnboardingView(
            status: status, later: { [weak self] in self?.onboardingWindow?.close() }))
        onboardingWindow = window
        show(window)
    }

    private func makeWindow(title: String, view: some View) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask.remove(.resizable)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func show(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        status.setPolling(true)
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let anyVisible = [onboardingWindow, settingsWindow].contains { $0 != nil && $0 !== closing && $0!.isVisible }
        status.setPolling(anyVisible)
    }

    @objc private func toggleCaretOverlay(_ sender: NSMenuItem) {
        caretOverlay.toggle()
        sender.state = caretOverlay.isOn ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
