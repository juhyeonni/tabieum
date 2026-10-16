import AppKit
import NotesCore
import os

extension CurrentNote {
    /// The database key of the one note selected in Notes, or nil for none or several. Main thread only: `NSAppleScript`.
    @MainActor
    static func selectedKey() -> Int? {
        guard NotesControl.pid != nil else { return nil }
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application \"Notes\" to get id of selection")
        guard let result = script?.executeAndReturnError(&error), error == nil else { return nil }
        let ids = result.numberOfItems > 0
            ? (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
            : [result.stringValue].compactMap { $0 }
        guard ids.count == 1 else { return nil }
        return key(coreDataID: ids[0])
    }
}

/// A floating panel listing the notes that link to the note open in Notes.
@MainActor
final class BacklinksPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private static let log = Logger(subsystem: "NotesExtension", category: "backlinks")

    private let indexURL: URL
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 320),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                                backing: .buffered, defer: true)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    private var rows: [Backlink] = []
    private var timer: Timer?
    private var lastKey: Int?

    init(indexURL: URL) {
        self.indexURL = indexURL
        super.init()
        panel.title = "Backlinks"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        panel.setFrameAutosaveName("BacklinksPanel")

        message.textColor = .secondaryLabelColor
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let stack = NSStackView(views: [message, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        for view in [message, scroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        panel.contentView = stack
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
            stopPolling()
            return
        }
        panel.orderFrontRegardless()
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TextFocusTracker.notesBundleID else { return }
        refresh(force: false)
    }

    private func refresh(force: Bool) {
        let key = CurrentNote.selectedKey()
        guard force || key != lastKey else { return }
        lastKey = key
        guard let key else { return show([], "Select one note in Notes.") }
        do {
            guard let id = try NotesReader().noteIdentifier(key: key) else { return show([], "Select one note in Notes.") }
            let backlinks = try SearchIndex(url: indexURL, readOnly: true).backlinks(to: id)
            show(backlinks, backlinks.isEmpty ? "No notes link here." : "")
        } catch {
            Self.log.error("cannot read backlinks: \(String(describing: error), privacy: .public)")
            show([], "Can't read backlinks. Check Full Disk Access in Settings, and wait for the first index.")
        }
    }

    private func show(_ backlinks: [Backlink], _ text: String) {
        rows = backlinks
        message.stringValue = text
        message.isHidden = text.isEmpty
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let backlink = rows[row]
        let date = backlink.modified.formatted(date: .abbreviated, time: .omitted)
        return "\(backlink.title) · \(backlink.folder) · \(date)"
    }

    @objc private func clicked() {
        guard rows.indices.contains(table.clickedRow), let url = NoteLink.url(for: rows[table.clickedRow].id) else { return }
        NSWorkspace.shared.open(url)
    }
}
