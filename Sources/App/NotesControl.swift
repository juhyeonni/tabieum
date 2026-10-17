import AppKit
import ApplicationServices
import NotesCore
import os

/// Keystrokes and Format menu presses sent to Apple Notes.
@MainActor
enum NotesControl {
    static var pid: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: TextFocusTracker.notesBundleID).first?.processIdentifier
    }

    static func postDelete(to pid: pid_t) { postKey(51, flags: [], to: pid) }

    static func postPaste(to pid: pid_t) { postKey(9, flags: .maskCommand, to: pid) }

    /// Pastes through a transient pasteboard item and puts the previous contents back afterwards.
    static func paste(plain: String, html: String? = nil, to pid: pid_t) {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        let item = NSPasteboardItem()
        if let html { item.setString("<meta charset=\"utf-8\">" + html, forType: .html) }
        item.setString(plain, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        postPaste(to: pid)
        // ponytail: fixed delay for Notes to read the paste; nothing reports when it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
        }
    }

    private static func postKey(_ key: CGKeyCode, flags: CGEventFlags, to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown)
            event?.flags = flags
            event?.postToPid(pid)
        }
    }

    private static var loggedMissing: Set<NotesStyle> = []
    private static let log = Logger(subsystem: "NotesExtension", category: "notes")

    /// Deletes `range`, waits until Notes has applied the delete, then presses the style's Format menu item.
    /// Pressing first would turn an empty line into an empty list item that the late delete then unlists.
    static func apply(_ style: NotesStyle, replacing range: NSRange, tracker: TextFocusTracker) {
        guard let pid else { return }
        guard let item = menuItem(for: style, pid: pid) else {
            if loggedMissing.insert(style).inserted {
                log.notice("No Notes menu item for \(style.displayName, privacy: .public); its shortcut may be rebound")
            }
            return
        }
        tracker.setSelectedRange(range)
        let before = tracker.textLength
        postDelete(to: pid)
        Task {
            // ponytail: gives up after 0.5 s and presses anyway
            for _ in 0..<50 where tracker.textLength == before {
                try? await Task.sleep(for: .milliseconds(10))
            }
            AXUIElementPerformAction(item, kAXPressAction as CFString)
        }
    }

    /// The Edit menu's Undo (⌘Z) or Redo (⇧⌘Z) item.
    static func historyItem(redo: Bool, pid: pid_t) -> AXUIElement? {
        menuItem(char: "Z", modifiers: redo ? 1 : 0, pid: pid)
    }

    static func isEnabled(_ item: AXUIElement) -> Bool {
        value(item, kAXEnabledAttribute) as Bool? ?? false
    }

    static func press(_ item: AXUIElement) {
        AXUIElementPerformAction(item, kAXPressAction as CFString)
    }

    private static func menuItem(for style: NotesStyle, pid: pid_t) -> AXUIElement? {
        let (char, modifiers) = style.keyEquivalent
        return menuItem(char: char, modifiers: modifiers, pid: pid)
    }

    private static func menuItem(char: String, modifiers: Int, pid: pid_t) -> AXUIElement? {
        guard let bar = element(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) else { return nil }
        return find(in: bar, depth: 4) { item in
            guard let cmdChar: String = value(item, kAXMenuItemCmdCharAttribute),
                  cmdChar.caseInsensitiveCompare(char) == .orderedSame else { return false }
            return (value(item, kAXMenuItemCmdModifiersAttribute) as Int? ?? 0) == modifiers
        }
    }

    /// Depth 4 reaches menu bar item → menu → item → submenu → item.
    private static func find(in element: AXUIElement, depth: Int, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        guard depth >= 0, let children: [AXUIElement] = value(element, kAXChildrenAttribute) else { return nil }
        for child in children {
            if matches(child) { return child }
            if let found = find(in: child, depth: depth - 1, where: matches) { return found }
        }
        return nil
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result: CFTypeRef = value(element, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result as? T
    }
}
