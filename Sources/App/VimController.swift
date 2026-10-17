import AppKit
import Combine
import NotesCore
import os

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NotesExtension", category: "vim")
private let latencyLog = Logger(subsystem: "dev.juhyeonni.notekit", category: "vim-latency")

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<VimController>.fromOpaque(refcon).takeUnretainedValue()
    let key = TapKey(event)
    let pass = MainActor.assumeIsolated { controller.shouldPass(type, key) }
    return pass ? Unmanaged.passUnretained(event) : nil
}

/// The parts of a key event the tap needs, read before hopping onto the main actor.
private struct TapKey: Sendable {
    var keyCode: Int64
    var flags: CGEventFlags
    var characters: String
    var time: TimeInterval
    var tag: Int64

    init(_ event: CGEvent) {
        keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        flags = event.flags
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        characters = String(utf16CodeUnits: chars, count: length)
        time = TimeInterval(event.timestamp) / 1_000_000_000
        tag = event.getIntegerValueField(.eventSourceUserData)
    }
}

/// Drives the Notes body with the Vim engine through an active event tap that exists only while Vim is on.
/// The tap only feeds the engine; AX reads and edits run afterwards, in key order, on the main actor.
@MainActor
final class VimController {
    private static let eventTag: Int64 = 0x4E4F_5445
    private static let escapeKeyCode: Int64 = 53
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let tracker: TextFocusTracker
    private let indicator = ModeIndicator()
    private let searchInput = SearchInput()
    private let shading = SearchShading()
    private var scrollMonitor: Any?
    private var editorFrame: CGRect?
    private var engine = VimEngine()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var subscription: Int?
    private var cancellables: Set<AnyCancellable> = []

    /// Keys another feature's tap is taking right now, which Vim passes.
    var claimsKey: (Int64) -> Bool = { _ in false }

    private var active = false
    /// The note body is focused but Vim cannot trust AX here (a table or attachment line, a selection that does not stick).
    private var unsupported = false
    private var searchOpen = false
    private var mismatchLine: NSRange?
    private var swallowed: Set<Int64> = []
    private var queue: [(command: VimCommand, start: UInt64)] = []
    private var draining = false
    private var latencies = LatencyWindow()
    private var latencyText: String?
    var showsLatency = false {
        didSet { if !showsLatency { latencyText = nil } }
    }

    init(tracker: TextFocusTracker, toggles: FeatureToggles) {
        self.tracker = tracker
        toggles.$vimJKEnabled.sink { [weak self] on in
            MainActor.assumeIsolated { self?.engine.jkEnabled = on }
        }.store(in: &cancellables)
        toggles.$vimEnabled.sink { [weak self] on in
            MainActor.assumeIsolated { on ? self?.install() : self?.remove() }
        }.store(in: &cancellables)
    }

    private func install() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: tapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("Vim on: event tap could not be created; is Accessibility granted?")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        runLoopSource = source
        subscription = tracker.subscribe { [weak self] in self?.refresh($0) }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshShading() }
        }
        log.notice("Vim on: event tap installed")
    }

    private func remove() {
        guard let tap else {
            log.notice("Vim off: no event tap installed")
            return
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        self.tap = nil
        runLoopSource = nil
        if let subscription { tracker.unsubscribe(subscription) }
        subscription = nil
        active = false
        unsupported = false
        swallowed = []
        queue = []
        engine.searchStatus = nil
        engine.clearSearchPattern()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        shading.hide()
        indicator.hide()
        log.notice("Vim off: event tap removed")
    }

    // MARK: - tap

    fileprivate func shouldPass(_ type: CGEventType, _ event: TapKey) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        if event.tag == Self.eventTag { return true }
        let keyCode = event.keyCode
        if type == .keyUp { return swallowed.remove(keyCode) == nil }
        guard active || unsupported, NSApp.keyWindow == nil, !claimsKey(keyCode) else { return true }
        if !active, engine.mode == .insert, keyCode != Self.escapeKeyCode { return true }
        let flags = event.flags
        guard let key = vimKey(
            keyCode: Int(keyCode), shift: flags.contains(.maskShift), control: flags.contains(.maskControl),
            command: flags.contains(.maskCommand), characters: event.characters, mode: engine.mode
        ) else { return true }
        guard case .consume(let command) = engine.feed(key, at: event.time) else { return true }
        swallowed.insert(keyCode)
        if case .promptSearch(let forward) = command {
            if active { openSearch(forward: forward) }
        } else if active {
            enqueue(command, start: DispatchTime.now().uptimeNanoseconds)
        } else if let arrow = fallbackArrowKeyCode(for: command) {
            post(keyCode: CGKeyCode(arrow))
        }
        return false
    }

    // MARK: - execution

    private func enqueue(_ command: VimCommand, start: UInt64) {
        queue.append((command, start))
        guard !draining else { return }
        draining = true
        Task {
            while !queue.isEmpty {
                let (command, start) = queue.removeFirst()
                await run(command)
                recordLatency(since: start)
            }
            draining = false
            refresh(tracker.state(withCaretRect: false))
        }
    }

    private func recordLatency(since start: UInt64) {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        latencies.record(ms)
        let median = latencies.median ?? ms, p90 = latencies.p90 ?? ms
        latencyLog.notice("key to AX applied: \(ms, format: .fixed(precision: 1)) ms (median \(median, format: .fixed(precision: 1)) ms, p90 \(p90, format: .fixed(precision: 1)) ms)")
        if showsLatency { latencyText = String(format: "last %.0fms · p90 %.0fms", ms, p90) }
    }

    private func run(_ command: VimCommand) async {
        guard let buffer = tracker.buffer() else { return }
        for action in engine.execute(command, on: buffer) {
            guard await perform(action) else { return }
        }
    }

    private func perform(_ action: VimAction) async -> Bool {
        switch action {
        case .select(let range):
            return select(range)
        case .delete(let range):
            guard tracker.buffer()?.deleteWouldHitBlockAttachment(range) == false,
                  select(range), let before = tracker.textLength else { return false }
            post(keyCode: 51)
            return await wait { $0 == before - range.length }
        case .insert(let text, let offset):
            guard select(NSRange(location: offset, length: 0)), let before = tracker.textLength else { return false }
            let applied = { (length: Int?) in length == before + text.utf16.count }
            if text == "\n" {
                post(keyCode: 36)
                return await wait(applied)
            }
            return await paste(text, until: applied)
        case .indent(let range, let outdent):
            guard select(range) else { return false }
            post(keyCode: outdent ? 33 : 30, flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(30))
            return true
        case .undo, .redo:
            let before = tracker.textLength
            post(keyCode: 6, flags: action == .redo ? [.maskCommand, .maskShift] : .maskCommand)
            // ponytail: an undo that keeps the length just waits out the timeout; compare text if that feels slow
            _ = await wait(attempts: 150) { $0 != before }
            return true
        }
    }

    private func select(_ range: NSRange) -> Bool {
        tracker.setSelectedRange(range)
        guard tracker.selectedRange() == range else {
            mismatchLine = tracker.buffer()?.caretLine
            log.info("Vim: selection write read back differently; passing keys through on this line")
            refresh(tracker.state(withCaretRect: false))
            return false
        }
        return true
    }

    private func paste(_ text: String, until applied: @escaping (Int?) -> Bool) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, Self.transientType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.transientType)
        post(keyCode: 9, flags: .maskCommand)
        let ok = await wait(applied)
        pasteboard.clearContents()
        pasteboard.writeObjects(saved)
        return ok
    }

    private func post(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let pid = NSRunningApplication.runningApplications(
            withBundleIdentifier: TextFocusTracker.notesBundleID
        ).first?.processIdentifier else { return }
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
            event.postToPid(pid)
        }
    }

    /// Polls the note's length until Notes has applied a synthesized edit, so the next action reads fresh text.
    private func wait(attempts: Int = 250, _ done: (Int?) -> Bool) async -> Bool {
        for _ in 0..<attempts {
            if done(tracker.textLength) { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    // MARK: - focus

    private func refresh(_ state: TextFocusState) {
        guard tap != nil else { return }
        let buffer = tracker.buffer()
        if buffer?.caretLine != mismatchLine { mismatchLine = nil }
        active = buffer != nil && mismatchLine == nil
        unsupported = buffer != nil && !active
        editorFrame = state.editorFrame
        if searchOpen {
            indicator.hide()
        } else {
            indicator.show(
                engine.mode, in: state.editorFrame,
                detail: [engine.searchStatus, latencyText].compactMap { $0 }.joined(separator: " "))
        }
        showShading(buffer, frame: state.editorFrame)
    }

    private func refreshShading() {
        guard tap != nil else { return }
        showShading(tracker.buffer(), frame: tracker.state(withCaretRect: false).editorFrame)
    }

    private func showShading(_ buffer: VimBuffer?, frame: CGRect?) {
        guard let buffer, let visible = buffer.visible, let frame else { return shading.hide() }
        let matches = vimVisibleMatches(
            in: buffer.text, pattern: engine.searchPattern, visible: visible, current: buffer.selection)
        let rects = matches.compactMap { match in
            tracker.bounds(for: match.range).flatMap { $0.size == .zero ? nil : (rect: $0, isCurrent: match.isCurrent) }
        }
        shading.show(rects, in: frame)
    }

    // MARK: - search

    private func openSearch(forward: Bool) {
        guard let editorFrame else { return }
        searchOpen = true
        indicator.hide()
        searchInput.show(forward: forward, in: editorFrame) { [weak self] pattern in
            self?.searchOpen = false
            self?.closeSearch(pattern, forward: forward)
            self?.refresh(self?.tracker.state ?? .notFocused)
        }
    }

    private func closeSearch(_ pattern: String?, forward: Bool) {
        guard let pid = NotesControl.pid else { return }
        Task {
            NSRunningApplication(processIdentifier: pid)?.activate()
            for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let pattern else { return }
            enqueue(.search(pattern, forward: forward), start: DispatchTime.now().uptimeNanoseconds)
        }
    }
}

/// A click-through window over the editor that shades search matches; the current one is drawn stronger.
@MainActor
final class SearchShading {
    private final class ShadeView: NSView {
        var rects: [(rect: CGRect, isCurrent: Bool)] = []
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            for (rect, isCurrent) in rects {
                NSColor.systemYellow.withAlphaComponent(isCurrent ? 0.6 : 0.25).setFill()
                rect.fill()
            }
        }
    }

    private let view = ShadeView()
    private lazy var window: NSWindow = {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = view
        return window
    }()

    /// `rects` are in AX coordinates.
    func show(_ rects: [(rect: CGRect, isCurrent: Bool)], in frame: CGRect) {
        guard !rects.isEmpty, let primary = NSScreen.screens.first else { return hide() }
        view.rects = rects.map { (CGRect(x: $0.rect.minX - frame.minX, y: $0.rect.minY - frame.minY, width: $0.rect.width, height: $0.rect.height), $0.isCurrent) }
        window.setFrame(appKitRect(fromAX: frame, primaryScreenHeight: primary.frame.height), display: true)
        view.needsDisplay = true
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}

/// A borderless, non-activating, click-through panel showing the mode in the editor's bottom-left corner.
@MainActor
final class ModeIndicator {
    private let label = NSTextField(labelWithString: "")
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        panel.contentView = label
        return panel
    }()

    func show(_ mode: VimMode, in frame: CGRect?, detail: String? = nil) {
        guard let frame, let primary = NSScreen.screens.first else { return hide() }
        let text = switch mode {
        case .normal: "-- NORMAL --"
        case .insert: "-- INSERT --"
        case .visual: "-- VISUAL --"
        case .visualLine: "-- VISUAL LINE --"
        }
        label.stringValue = text
        if let detail { label.stringValue += " " + detail }
        let size = label.fittingSize
        let rect = appKitRect(fromAX: frame, primaryScreenHeight: primary.frame.height)
        panel.setFrame(
            CGRect(x: rect.minX + 8, y: rect.minY + 8, width: size.width + 10, height: size.height + 2),
            display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// A small text input in the indicator's corner for a `/` or `?` pattern: a real field, so the input method can compose.
@MainActor
final class SearchInput: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let prefix = NSTextField(labelWithString: "/")
    private let field = NSTextField()
    private var done: ((String?) -> Void)?
    private lazy var panel: KeyPanel = {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        prefix.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.delegate = self
        field.focusRingType = .none
        let stack = NSStackView(views: [prefix, field])
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        panel.contentView = stack
        return panel
    }()

    func show(forward: Bool, in frame: CGRect, done: @escaping (String?) -> Void) {
        guard let primary = NSScreen.screens.first else { return }
        self.done = done
        prefix.stringValue = forward ? "/" : "?"
        field.stringValue = ""
        let rect = appKitRect(fromAX: frame, primaryScreenHeight: primary.frame.height)
        panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
        panel.setFrameOrigin(CGPoint(x: rect.minX + 8, y: rect.minY + 8))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func finish(_ pattern: String?) {
        let done = done
        self.done = nil
        panel.orderOut(nil)
        done?(pattern)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): finish(field.stringValue)
        case #selector(NSResponder.cancelOperation(_:)): finish(nil)
        default: return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        guard done != nil else { return }
        finish(nil)
    }
}
