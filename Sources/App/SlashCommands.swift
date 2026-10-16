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
    private var slashRange: NSRange?
    private lazy var panel = SlashPanel { [weak self] in self?.choose($0) }
    private let log = Logger(subsystem: "NotesExtension", category: "slash")

    init(tracker: TextFocusTracker, toggles: FeatureToggles) {
        self.tracker = tracker
        self.toggles = toggles
        _ = tracker.subscribe { [weak self] _ in self?.textChanged() }
    }

    private func textChanged() {
        let current = tracker.snapshot()
        defer { previous = current }
        guard !panel.isVisible, let previous, let current,
              let range = slashTrigger(previous: previous, current: current),
              let caret = tracker.caretRect(), let primary = NSScreen.screens.first
        else { return }
        slashRange = range
        let folder = toggles.templateFolder
        let templates = templates(in: folder)
        let message: String? = switch templates {
        case nil: "Can't read templates from Notes. Check Automation in Settings."
        case let list? where list.isEmpty: "No templates: the folder “\(folder)” is missing or empty."
        default: nil
        }
        panel.show(items: (templates ?? []) + SlashItem.builtIns + registry.items, message: message,
                   at: appKitRect(fromAX: caret, primaryScreenHeight: primary.frame.height))
    }

    private func choose(_ item: SlashItem) {
        guard let range = slashRange, let pid = NotesControl.pid,
              let text = tracker.snapshot()?.text.utf16, range.location < text.count,
              text[text.index(text.startIndex, offsetBy: range.location)] == UInt16(UInt8(ascii: "/"))
        else { return }
        switch item.action {
        case let .style(style):
            NotesControl.apply(style, replacing: range, tracker: tracker)
        case let .template(id):
            guard let (html, plain) = content(of: id) else { return }
            tracker.setSelectedRange(range)
            NotesControl.postDelete(to: pid)
            paste(html: strippingFirstLine(html: html), plain: strippingFirstLine(plainText: plain), pid: pid)
        case let .command(index):
            tracker.setSelectedRange(range)
            NotesControl.postDelete(to: pid)
            registry.commands[index].run()
        }
    }

    private func paste(html: String, plain: String, pid: pid_t) {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        let item = NSPasteboardItem()
        item.setString("<meta charset=\"utf-8\">" + html, forType: .html)
        item.setString(plain, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        NotesControl.postPaste(to: pid)
        // ponytail: fixed delay for Notes to read the paste; nothing reports when it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
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

/// A non-activating panel that takes keyboard focus while Notes stays the active app.
@MainActor
final class SlashPanel: NSPanel, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let field = NSTextField()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    private var all: [SlashItem] = []
    private var shown: [SlashItem] = []
    private let onChoose: (SlashItem) -> Void

    init(onChoose: @escaping (SlashItem) -> Void) {
        self.onChoose = onChoose
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 260),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear

        field.placeholderString = "Search templates and styles"
        field.delegate = self
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        table.backgroundColor = .clear

        let stack = NSStackView(views: [field, message, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        for view in [field, message, scroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
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
        contentView = background
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    /// `caret` is in AppKit coordinates; the panel opens below it, or above it near the screen's bottom.
    func show(items: [SlashItem], message text: String?, at caret: CGRect) {
        all = items
        field.stringValue = ""
        message.stringValue = text ?? ""
        message.isHidden = text == nil
        refilter()
        var origin = NSPoint(x: caret.minX, y: caret.minY - frame.height)
        if let visible = (NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main)?.visibleFrame {
            if origin.y < visible.minY { origin.y = caret.maxY }
            origin.x = max(visible.minX, min(origin.x, visible.maxX - frame.width))
        }
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    private func refilter() {
        shown = filterSlashItems(all, query: field.stringValue)
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private func choose(row: Int) {
        guard shown.indices.contains(row) else { return }
        let item = shown[row]
        orderOut(nil)
        onChoose(item)
    }

    @objc private func clicked() { choose(row: table.clickedRow) }

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.insertNewline(_:)): choose(row: table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): orderOut(nil)
        default: return false
        }
        return true
    }

    private func move(by step: Int) {
        guard !shown.isEmpty else { return }
        let row = min(max(table.selectedRow + step, 0), shown.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: shown[row].title)
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}
