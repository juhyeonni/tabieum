import AppKit
import ApplicationServices
import Combine
import NotesCore
import os

/// Turns a Markdown marker typed at the start of a line in Notes into the matching Notes style.
/// Observes Notes only while at least one shortcut is on.
@MainActor
final class MarkdownShortcuts {
    private let tracker: TextFocusTracker
    private let toggles: FeatureToggles
    private var subscription: Int?
    private var previous: TextSnapshot?
    private var togglesSink: AnyCancellable?
    private var loggedMissing: Set<MarkdownStyle> = []
    private let log = Logger(subsystem: "NotesExtension", category: "markdown")

    init(tracker: TextFocusTracker, toggles: FeatureToggles) {
        self.tracker = tracker
        self.toggles = toggles
        togglesSink = toggles.$markdownStyles.sink { [weak self] styles in
            MainActor.assumeIsolated { self?.setObserving(!styles.isEmpty) }
        }
    }

    private func setObserving(_ on: Bool) {
        if on, subscription == nil {
            subscription = tracker.subscribe { [weak self] _ in self?.textChanged() }
        } else if !on, let subscription {
            tracker.unsubscribe(subscription)
            self.subscription = nil
            previous = nil
        }
    }

    private func textChanged() {
        let current = tracker.snapshot()
        defer { previous = current }
        guard let previous, let current,
              let match = markdownMatch(previous: previous, current: current, enabled: toggles.markdownStyles)
        else { return }
        apply(match)
    }

    private func apply(_ match: MarkdownMatch) {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: TextFocusTracker.notesBundleID)
            .first?.processIdentifier else { return }
        guard let item = menuItem(for: match.style, in: AXUIElementCreateApplication(pid)) else {
            if loggedMissing.insert(match.style).inserted {
                log.notice("No Notes menu item for \(match.style.displayName, privacy: .public); its shortcut may be rebound")
            }
            return
        }
        tracker.setSelectedRange(match.range)
        postDelete(to: pid)
        AXUIElementPerformAction(item, kAXPressAction as CFString)
    }

    private func postDelete(to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: keyDown)
            event?.flags = []
            event?.postToPid(pid)
        }
    }

    private func menuItem(for style: MarkdownStyle, in app: AXUIElement) -> AXUIElement? {
        guard let bar = element(app, kAXMenuBarAttribute) else { return nil }
        let (char, modifiers) = style.keyEquivalent
        return find(in: bar, depth: 4) { item in
            guard let cmdChar: String = value(item, kAXMenuItemCmdCharAttribute),
                  cmdChar.caseInsensitiveCompare(char) == .orderedSame else { return false }
            return (value(item, kAXMenuItemCmdModifiersAttribute) as Int? ?? 0) == modifiers
        }
    }

    /// Depth 4 reaches menu bar item → menu → item → submenu → item.
    private func find(in element: AXUIElement, depth: Int, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        guard depth >= 0, let children: [AXUIElement] = value(element, kAXChildrenAttribute) else { return nil }
        for child in children {
            if matches(child) { return child }
            if let found = find(in: child, depth: depth - 1, where: matches) { return found }
        }
        return nil
    }

    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result: CFTypeRef = value(element, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    private func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result as? T
    }
}
