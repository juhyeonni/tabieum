import AppKit
import ApplicationServices
import NotesCore

/// Live Accessibility calls against Apple Notes. Holds an AXObserver and a Notes process reference only while observing.
@MainActor
final class AXTextFocusSource: TextFocusSource {
    private var onChange: (() -> Void)?
    private var observer: AXObserver?
    private var workspaceTokens: [NSObjectProtocol] = []

    var isTrusted: Bool { AXIsProcessTrusted() }

    var frontmostBundleID: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    var focusedRole: String? {
        focusedElement().flatMap { value($0, kAXRoleAttribute) as String? }
    }

    var textLength: Int? {
        focusedElement().flatMap { value($0, kAXNumberOfCharactersAttribute) as Int? }
    }

    /// AXStringForRange costs about 0.04 ms where AXValue costs 3.5 ms or more on the same text.
    var text: String? {
        guard let element = focusedElement() else { return nil }
        guard let length: Int = value(element, kAXNumberOfCharactersAttribute) else { return nil }
        var range = CFRange(location: 0, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &result
        ) == .success else { return value(element, kAXValueAttribute) }
        return result as? String
    }

    /// The editor's visible part: a long note's text area runs past the window, so it is clipped to its scroll area.
    var frame: CGRect? {
        guard let element = focusedElement(), let rect = axFrame(element) else { return nil }
        let visible = (value(element, kAXParentAttribute) as AXUIElement?).flatMap(axFrame)
        return visible.map { rect.intersection($0) } ?? rect
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let axValue: AXValue = value(element, "AXFrame") else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(axValue, .cgRect, &rect) ? rect : nil
    }

    var visibleRange: NSRange? {
        guard let element = focusedElement(),
              let axValue: AXValue = value(element, kAXVisibleCharacterRangeAttribute)
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    func selectedRange() -> NSRange? {
        guard let element = focusedElement(),
              let axValue: AXValue = value(element, kAXSelectedTextRangeAttribute)
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    func setSelectedRange(_ range: NSRange) {
        guard let element = focusedElement() else { return }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axValue = AXValueCreate(.cfRange, &cfRange) else { return }
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue)
    }

    func bounds(for range: NSRange) -> CGRect? {
        guard let element = focusedElement() else { return nil }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &result
        ) == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    func startObserving(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        workspaceTokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let terminatedNotes = name == NSWorkspace.didTerminateApplicationNotification
                    && app?.bundleIdentifier == TextFocusTracker.notesBundleID
                MainActor.assumeIsolated { self?.workspaceChanged(notesTerminated: terminatedNotes) }
            }
        }
        attach()
    }

    func stopObserving() {
        workspaceTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceTokens = []
        detach()
        onChange = nil
    }

    private func workspaceChanged(notesTerminated: Bool) {
        if notesTerminated { detach() } else { attach() }
        onChange?()
    }

    private func attach() {
        guard observer == nil, isTrusted, let pid = notesPID() else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let source = Unmanaged<AXTextFocusSource>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { source.onChange?() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedUIElementChangedNotification, kAXSelectedTextChangedNotification, kAXValueChangedNotification] {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    private func detach() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }

    private func notesPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: TextFocusTracker.notesBundleID).first?.processIdentifier
    }

    /// The default timeout is about 6 s, and the event tap shares the main thread with these calls.
    private static let messagingTimeout: Float = 0.1

    private func focusedElement() -> AXUIElement? {
        guard isTrusted, let pid = notesPID() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        guard let element: CFTypeRef = value(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        let focused = element as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)
        return focused
    }

    private func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result as? T
    }
}
