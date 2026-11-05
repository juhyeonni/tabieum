import AppKit
import ApplicationServices
import Combine
import NotesCore
import os

/// A row of format buttons next to the selection in Notes. Observes Notes only while the option is on.
/// A non-activating panel that never becomes key, so a click leaves Notes' selection and focus alone.
@MainActor
final class FormatToolbar: NSObject {
    private static let settle: Duration = .milliseconds(150)

    private let tracker: TextFocusTracker
    private let toggles: FeatureToggles
    private var subscription: Int?
    private var togglesSink: AnyCancellable?
    private var pending: Task<Void, Never>?
    private var loggedMissing: Set<FormatTool> = []
    private let log = Logger(subsystem: "NotesExtension", category: "format-toolbar")
    private let buttons: [NSButton]
    let panel: NSPanel

    var isObserving: Bool { subscription != nil }

    init(tracker: TextFocusTracker, toggles: FeatureToggles) {
        self.tracker = tracker
        self.toggles = toggles
        buttons = FormatTool.allCases.map {
            NSButton(image: NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: $0.displayName) ?? NSImage(),
                     target: nil, action: nil)
        }
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        for (index, button) in buttons.enumerated() {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.toolTip = FormatTool.allCases[index].displayName
            button.tag = index
            button.target = self
            button.action = #selector(clicked(_:))
        }
        let stack = NSStackView(views: buttons)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        togglesSink = toggles.$formatToolbarEnabled.sink { [weak self] on in
            MainActor.assumeIsolated { self?.setObserving(on) }
        }
    }

    private func setObserving(_ on: Bool) {
        if on, subscription == nil {
            subscription = tracker.subscribe { [weak self] in self?.selectionChanged($0) }
        } else if !on, let subscription {
            tracker.unsubscribe(subscription)
            self.subscription = nil
            hide()
        }
    }

    private func hide() {
        pending?.cancel()
        panel.orderOut(nil)
    }

    private func selectionChanged(_ state: TextFocusState) {
        guard shouldShowFormatToolbar(
            selectionLength: state.selection?.length, isFocused: state.isFocused, enabled: toggles.formatToolbarEnabled)
        else { return hide() }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            self?.show()
        }
    }

    private func show() {
        guard let range = tracker.selectedRange(), range.length > 0, let pid = NotesControl.pid,
              let rect = tracker.bounds(for: range), rect.size != .zero, let primary = NSScreen.screens.first
        else { return panel.orderOut(nil) }
        for (button, tool) in zip(buttons, FormatTool.allCases) {
            button.isHidden = NotesControl.menuItem(for: tool, pid: pid) == nil
            if button.isHidden, loggedMissing.insert(tool).inserted {
                log.notice("No Notes menu item for \(tool.displayName, privacy: .public); its shortcut may be rebound")
            }
        }
        guard buttons.contains(where: { !$0.isHidden }) else { return panel.orderOut(nil) }
        let selection = appKitRect(fromAX: rect, primaryScreenHeight: primary.frame.height)
        let size = panel.contentView?.fittingSize ?? .zero
        let visible = (NSScreen.screens.first { $0.frame.intersects(selection) } ?? NSScreen.main)?.visibleFrame ?? selection
        panel.setFrame(formatToolbarFrame(selection: selection, size: size, visible: visible), display: true)
        panel.orderFrontRegardless()
    }

    @objc private func clicked(_ sender: NSButton) {
        hide()
        guard let pid = NotesControl.pid, let item = NotesControl.menuItem(for: FormatTool.allCases[sender.tag], pid: pid) else { return }
        NotesControl.press(item)
    }
}
