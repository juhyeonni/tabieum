import AppKit
import NotesCore
import os

/// Opens the `/` panel when `/` is typed at the start of a line or after whitespace in Notes,
/// and inserts the chosen template or applies the chosen style.
@MainActor
final class SlashCommands {
    private let tracker: TextFocusTracker
    private let toggles: FeatureToggles
    let registry = SlashCommandRegistry()
    private var previous: TextSnapshot?
    private var slashOffset: Int?
    private var allItems: [SlashItem] = []
    private lazy var panel = SlashPanel(onChoose: { [weak self] in self?.choose($0) }, onClose: { [weak self] in self?.close() })
    private lazy var keyTap = SlashKeyTap { [weak self] in self?.handle($0) }
    private let log = Logger(subsystem: "NotesExtension", category: "slash")

    init(tracker: TextFocusTracker, toggles: FeatureToggles) {
        self.tracker = tracker
        self.toggles = toggles
        _ = tracker.subscribe { [weak self] _ in self?.textChanged() }
    }

    /// True for the keys the open menu takes, so Vim mode's tap passes them.
    func claims(keyCode: Int64) -> Bool { slashOffset != nil && SlashKeyTap.keys[keyCode] != nil }

    private func textChanged() {
        let current = tracker.snapshot()
        defer { previous = current }
        if let offset = slashOffset { return update(offset, current) }
        guard let previous, let current,
              let range = slashTrigger(previous: previous, current: current),
              let caret = tracker.caretRect(), let primary = NSScreen.screens.first
        else { return }
        let folder = toggles.templateFolder
        let templates = templates(in: folder)
        let message: String? = switch templates {
        case nil: "Can't read templates from Notes. Check Automation in Settings."
        default: nil
        }
        slashOffset = range.location
        allItems = (templates ?? []) + SlashItem.builtIns + registry.items
        panel.show(items: allItems, message: message,
                   at: appKitRect(fromAX: caret, primaryScreenHeight: primary.frame.height))
        keyTap.start()
    }

    /// A nil snapshot is a selection or a moment Notes has no caret; only losing focus closes the menu then.
    private func update(_ offset: Int, _ current: TextSnapshot?) {
        guard tracker.isFocused else { return close() }
        guard let current else { return }
        guard let query = slashQuery(text: current.text, slashOffset: offset, caret: current.caret),
              slashMenuStaysOpen(allItems, query: query)
        else { return close() }
        panel.filter(query)
    }

    private func close() {
        slashOffset = nil
        keyTap.stop()
        panel.orderOut(nil)
    }

    private func handle(_ key: SlashKeyTap.Key) {
        guard slashOffset != nil else { return }
        switch key {
        case .up: panel.move(by: -1)
        case .down: panel.move(by: 1)
        case .choose: panel.chooseSelected()
        case .close: close()
        }
    }

    private func choose(_ item: SlashItem) {
        guard let offset = slashOffset, let pid = NotesControl.pid, let snapshot = tracker.snapshot(),
              let query = slashQuery(text: snapshot.text, slashOffset: offset, caret: snapshot.caret)
        else { return close() }
        close()
        let range = NSRange(location: offset, length: 1 + query.utf16.count)
        switch item.action {
        case let .style(style):
            NotesControl.apply(style, replacing: range, tracker: tracker)
        case let .template(id):
            guard let (html, plain) = content(of: id) else { return }
            tracker.setSelectedRange(range)
            NotesControl.postDelete(to: pid)
            NotesControl.paste(plain: strippingFirstLine(plainText: plain), html: strippingFirstLine(html: html), to: pid)
        case let .command(index):
            tracker.setSelectedRange(range)
            NotesControl.postDelete(to: pid)
            registry.commands[index].run()
        }
    }

    /// The notes in every account's folder named `folder`, by name, or nil when Notes can't be asked.
    private func templates(in folder: String) -> [SlashItem]? {
        let script = """
        tell application "Notes"
            set out to {}
            repeat with a in accounts
                repeat with f in (folders of a whose name is \(quoted(folder)))
                    repeat with n in notes of f
                        set end of out to {id of n, name of n}
                    end repeat
                end repeat
            end repeat
            return out
        end tell
        """
        guard let result = run(script) else { return nil }
        let items = (0..<result.numberOfItems).compactMap { index -> SlashItem? in
            guard let pair = result.atIndex(index + 1), let id = pair.atIndex(1)?.stringValue,
                  let name = pair.atIndex(2)?.stringValue else { return nil }
            return SlashItem(title: name, action: .template(id))
        }
        return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func content(of id: String) -> (html: String, plain: String)? {
        guard let result = run("tell application \"Notes\" to get {body, plaintext} of note id \(quoted(id))"),
              let html = result.atIndex(1)?.stringValue, let plain = result.atIndex(2)?.stringValue
        else { return nil }
        return (html, plain)
    }

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            log.error("AppleScript failed: \(error, privacy: .public)")
            return nil
        }
        return result
    }

    private func quoted(_ string: String) -> String {
        "\"" + string.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    }
}

private let slashTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<SlashKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags.rawValue
    let pass = MainActor.assumeIsolated { tap.shouldPass(type, code, flags) }
    return pass ? Unmanaged.passUnretained(event) : nil
}

/// Takes Up, Down, Return and Esc from Notes through an event tap that exists only while the menu is open.
@MainActor
final class SlashKeyTap {
    enum Key { case up, down, choose, close }

    static let keys: [Int64: Key] = [126: .up, 125: .down, 36: .choose, 76: .choose, 53: .close]

    private let onKey: (Key) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowed: Set<Int64> = []
    private let log = Logger(subsystem: "NotesExtension", category: "slash")

    init(onKey: @escaping (Key) -> Void) { self.onKey = onKey }

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: slashTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("Slash menu: event tap could not be created; is Accessibility granted?")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.tap = nil
        source = nil
        swallowed = []
    }

    fileprivate func shouldPass(_ type: CGEventType, _ code: Int64, _ flags: UInt64) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .keyUp:
            return swallowed.remove(code) == nil
        case .keyDown:
            guard let key = Self.keys[code],
                  CGEventFlags(rawValue: flags).isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate])
            else { return true }
            swallowed.insert(code)
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onKey(key) } }
            return false
        default:
            return true
        }
    }
}

private func symbolName(for item: SlashItem) -> String {
    switch item.action {
    case .template: "doc.text"
    case .command: "sparkles"
    case let .style(style):
        switch style {
        case .title: "textformat.size.larger"
        case .heading: "textformat.size"
        case .subheading: "textformat.size.smaller"
        case .body: "text.alignleft"
        case .monostyled: "chevron.left.forwardslash.chevron.right"
        case .bulletedList: "list.bullet"
        case .dashedList: "list.dash"
        case .numberedList: "list.number"
        case .checklist: "checklist"
        case .blockQuote: "text.quote"
        }
    }
}

private final class ClickableTable: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class SelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

/// A non-activating panel that never becomes key: Notes keeps the keyboard and the user keeps typing the query there.
@MainActor
final class SlashPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case header(String), message(String), item(SlashItem), close

        var isSelectable: Bool {
            switch self {
            case .item, .close: true
            case .header, .message: false
            }
        }

        var height: CGFloat {
            switch self {
            case .header: 24
            case .message: 40
            case .item, .close: 28
            }
        }
    }

    private static let width: CGFloat = 300
    private static let maxHeight: CGFloat = 340
    private static let inset: CGFloat = 4

    private let table = ClickableTable()
    private var all: [SlashItem] = []
    private var note: String?
    private var rows: [Row] = []
    private var caret: CGRect = .zero
    private let onChoose: (SlashItem) -> Void
    private let onClose: () -> Void

    init(onChoose: @escaping (SlashItem) -> Void, onClose: @escaping () -> Void) {
        self.onChoose = onChoose
        self.onClose = onClose
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear

        table.addTableColumn(NSTableColumn(identifier: .init("row")))
        table.headerView = nil
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.addSubview(scroll)
        let inset = Self.inset
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: inset),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -inset),
            scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: inset),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -inset),
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `caret` is in AppKit coordinates; the panel opens below it, or above it near the screen's bottom.
    func show(items: [SlashItem], message text: String?, at caret: CGRect) {
        all = items
        note = text
        self.caret = caret
        filter("")
        orderFrontRegardless()
    }

    func filter(_ query: String) {
        rows = note.map { [Row.message($0)] } ?? []
        for group in groupSlashItems(filterSlashItems(all, query: query)) {
            rows.append(.header(group.section.rawValue))
            rows += group.items.map(Row.item)
        }
        rows.append(.close)
        table.reloadData()
        select(rows.firstIndex { $0.isSelectable })
        resize()
    }

    private func resize() {
        let content = rows.reduce(0) { $0 + $1.height } + 2 * Self.inset
        setContentSize(NSSize(width: Self.width, height: min(content, Self.maxHeight)))
        var origin = NSPoint(x: caret.minX, y: caret.minY - frame.height)
        if let visible = (NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main)?.visibleFrame {
            if origin.y < visible.minY { origin.y = caret.maxY }
            origin.x = max(visible.minX, min(origin.x, visible.maxX - frame.width))
        }
        setFrameOrigin(origin)
    }

    private func select(_ row: Int?) {
        guard let row else { return table.deselectAll(nil) }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func move(by step: Int) {
        var row = table.selectedRow + step
        while rows.indices.contains(row), !rows[row].isSelectable { row += step }
        if rows.indices.contains(row) { select(row) }
    }

    func chooseSelected() { choose(row: table.selectedRow) }

    private func choose(row: Int) {
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case let .item(item): onChoose(item)
        case .close: onClose()
        case .header, .message: break
        }
    }

    @objc private func clicked() { choose(row: table.clickedRow) }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].height }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].isSelectable }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .header(title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return padded(label, top: 8)
        case let .message(text):
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            return padded(label, top: 0)
        case let .item(item):
            return cell(symbol: symbolName(for: item), title: item.title, trailing: item.shortcut)
        case .close:
            return cell(symbol: "xmark.circle", title: "Close menu", trailing: "esc")
        }
    }

    private func padded(_ label: NSTextField, top: CGFloat) -> NSView {
        let view = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: top / 2),
        ])
        return view
    }

    private func cell(symbol: String, title: String, trailing: String?) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let label = NSTextField(labelWithString: title)
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let hint = NSTextField(labelWithString: trailing ?? "")
        hint.textColor = .secondaryLabelColor
        hint.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [icon, label, hint])
        stack.spacing = 8
        let view = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }
}
