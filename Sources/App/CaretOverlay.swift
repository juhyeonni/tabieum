import AppKit
import NotesCore

/// Debug overlay: a click-through window outlining the caret rect while the Notes body is focused.
@MainActor
final class CaretOverlay {
    private let tracker: TextFocusTracker
    private var subscription: Int?
    private lazy var window: NSWindow = {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.systemGray.withAlphaComponent(0.35).cgColor
        view.layer?.borderWidth = 1
        window.contentView = view
        return window
    }()

    init(tracker: TextFocusTracker) {
        self.tracker = tracker
    }

    var isOn: Bool { subscription != nil }

    func set(_ on: Bool) {
        if on != isOn { toggle() }
    }

    func toggle() {
        if let subscription {
            tracker.unsubscribe(subscription)
            self.subscription = nil
            window.orderOut(nil)
            return
        }
        subscription = tracker.subscribe(needsCaretRect: true) { [weak self] in self?.show($0) }
    }

    private func show(_ state: TextFocusState) {
        guard let caret = state.caretRect, let primary = NSScreen.screens.first else {
            window.orderOut(nil)
            return
        }
        let rect = appKitRect(fromAX: caret, primaryScreenHeight: primary.frame.height)
        window.setFrame(rect.insetBy(dx: -2, dy: -2), display: true)
        window.orderFrontRegardless()
    }
}
