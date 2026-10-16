import AppKit
import NotesCore

/// A brief message in a non-activating panel, so Notes keeps focus.
@MainActor
enum Toast {
    private static let label = NSTextField(labelWithString: "")
    private static var hide: DispatchWorkItem?
    private static let panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.8)
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        panel.contentView = label
        return panel
    }()

    static func show(_ text: String) {
        guard let screen = NSScreen.main else { return }
        label.stringValue = text
        let size = label.fittingSize
        let visible = screen.visibleFrame
        panel.setFrame(
            CGRect(x: visible.midX - size.width / 2 - 8, y: visible.minY + 48, width: size.width + 16, height: size.height + 8),
            display: true)
        panel.orderFrontRegardless()
        hide?.cancel()
        let work = DispatchWorkItem { panel.orderOut(nil) }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

/// A translucent button at the editor's bottom-right that opens a menu of actions on the open note.
/// A non-activating panel, so a click leaves Notes' caret and selection alone.
@MainActor
final class ActionButton: NSObject {
    private static let side: CGFloat = 26
    private static let rest: CGFloat = 0.45

    private let tracker: TextFocusTracker
    private let toggles: FeatureToggles
    private let perform: (ActionMenuItem) -> Void
    private let button = NSButton()
    private var menuActions: [ActionMenuItem] = []
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Note actions")
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        button.layer?.cornerRadius = Self.side / 2
        button.alphaValue = Self.rest
        button.target = self
        button.action = #selector(clicked)
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeAlways], owner: self, userInfo: nil)
        button.addTrackingArea(area)
        panel.contentView = button
        return panel
    }()

    init(tracker: TextFocusTracker, toggles: FeatureToggles, perform: @escaping (ActionMenuItem) -> Void) {
        self.tracker = tracker
        self.toggles = toggles
        self.perform = perform
        super.init()
        _ = tracker.subscribe { [weak self] in self?.show($0) }
    }

    private func show(_ state: TextFocusState) {
        guard let frame = state.editorFrame, let primary = NSScreen.screens.first else {
            panel.orderOut(nil)
            return
        }
        let size = CGSize(width: Self.side, height: Self.side)
        panel.setFrame(appKitRect(fromAX: actionButtonRect(in: frame, size: size), primaryScreenHeight: primary.frame.height), display: true)
        panel.orderFrontRegardless()
    }

    @objc func mouseEntered(with event: NSEvent) { button.alphaValue = 0.95 }

    @objc func mouseExited(with event: NSEvent) { button.alphaValue = Self.rest }

    @objc private func clicked() {
        let match = try? CurrentNote.open { try NotesReader().noteKeys(title: $0) }
        let title = match.flatMap { try? NotesReader().note(key: $0.key)?.note.title }
        let model = ActionMenuModel(title: title, ambiguous: match?.ambiguous ?? false)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: model.header, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menuActions = model.items
        for (index, item) in model.items.enumerated() {
            let row = menu.addItem(withTitle: item.title, action: #selector(chose(_:)), keyEquivalent: "")
            row.target = self
            row.tag = index
            row.isEnabled = item != .askNotes || toggles.aiEnabled
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
        button.alphaValue = Self.rest
    }

    @objc private func chose(_ sender: NSMenuItem) {
        perform(menuActions[sender.tag])
    }
}
