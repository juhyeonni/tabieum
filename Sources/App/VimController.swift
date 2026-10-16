import AppKit
import Combine
import NotesCore
import os

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NotesExtension", category: "vim")
private let latencyLog = Logger(subsystem: "dev.juhyeonni.notekit", category: "vim-latency")

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let began = DispatchTime.now().uptimeNanoseconds
    let controller = Unmanaged<VimController>.fromOpaque(refcon).takeUnretainedValue()
    let key = TapKey(event)
    let pass = MainActor.assumeIsolated { controller.shouldPass(type, key) }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
    if type == .keyDown { latencyLog.notice("tap callback: \(ms, format: .fixed(precision: 2)) ms") }
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
/// The tap only feeds the engine and queues the command; AX reads and edits run afterwards, in key order, on the runner's background queue.
@MainActor
final class VimController {
    private static let escapeKeyCode: Int64 = 53

    private let tracker: TextFocusTracker
    private let indicator = ModeIndicator()
    private lazy var runner = VimRunner(
        engine: VimEngine(), ax: notes,
        onApplied: { [weak self] start in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.recordLatency(since: start) } }
        },
        onIdle: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshAfterRun() } }
        })
    private let notes = NotesAX(source: AXTextFocusSource())
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var subscription: Int?
    private var cancellables: Set<AnyCancellable> = []

    /// Keys another feature's tap is taking right now, which Vim passes.
    var claimsKey: (Int64) -> Bool = { _ in false }

    private var active = false
    /// The note body is focused but Vim cannot trust AX here (a table or attachment line, a selection that does not stick).
    private var unsupported = false
    private var mismatchLine: NSRange?
    private var swallowed: Set<Int64> = []
    private var latencies = LatencyWindow()
    private var latencyText: String?
    var showsLatency = false {
        didSet { if !showsLatency { latencyText = nil } }
    }

    init(tracker: TextFocusTracker, toggles: FeatureToggles) {
        self.tracker = tracker
        notes.onMismatch = { [weak self] line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.selectionMismatch(on: line) } }
        }
        toggles.$vimJKEnabled.sink { [weak self] on in
            MainActor.assumeIsolated { self?.runner.jkEnabled = on }
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
        runner.clear()
        indicator.hide()
        log.notice("Vim off: event tap removed")
    }

    // MARK: - tap

    fileprivate func shouldPass(_ type: CGEventType, _ event: TapKey) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        if event.tag == NotesAX.eventTag { return true }
        let keyCode = event.keyCode
        if type == .keyUp { return swallowed.remove(keyCode) == nil }
        guard active || unsupported, NSApp.keyWindow == nil, !claimsKey(keyCode) else { return true }
        let mode = runner.mode
        if !active, mode == .insert, keyCode != Self.escapeKeyCode { return true }
        let flags = event.flags
        guard let key = vimKey(
            keyCode: Int(keyCode), shift: flags.contains(.maskShift), control: flags.contains(.maskControl),
            command: flags.contains(.maskCommand), characters: event.characters, mode: mode
        ) else { return true }
        guard case .consume(let command) = runner.feed(key, at: event.time) else { return true }
        swallowed.insert(keyCode)
        if active {
            runner.enqueue(command, start: DispatchTime.now().uptimeNanoseconds)
        } else if let arrow = fallbackArrowKeyCode(for: command) {
            NotesAX.post(keyCode: CGKeyCode(arrow))
        }
        return false
    }

    // MARK: - execution

    private func recordLatency(since start: UInt64) {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        latencies.record(ms)
        let median = latencies.median ?? ms, p90 = latencies.p90 ?? ms
        latencyLog.notice("key to AX applied: \(ms, format: .fixed(precision: 1)) ms (median \(median, format: .fixed(precision: 1)) ms, p90 \(p90, format: .fixed(precision: 1)) ms)")
        if showsLatency { latencyText = String(format: "last %.0fms · p90 %.0fms", ms, p90) }
    }

    private func refreshAfterRun() {
        refresh(tracker.state(withCaretRect: false))
    }

    private func selectionMismatch(on line: NSRange?) {
        mismatchLine = line
        refreshAfterRun()
    }

    // MARK: - focus

    private func refresh(_ state: TextFocusState) {
        guard tap != nil else { return }
        let buffer = tracker.buffer()
        if buffer?.caretLine != mismatchLine { mismatchLine = nil }
        active = buffer != nil && mismatchLine == nil
        unsupported = buffer != nil && !active
        indicator.show(runner.mode, in: state.editorFrame, detail: latencyText)
    }
}

/// Applies Vim actions to the Notes body. Runs on the runner's background queue, so it touches no main-actor state.
private final class NotesAX: VimAXSource, @unchecked Sendable {
    static let eventTag: Int64 = 0x4E4F_5445
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let source: AXTextFocusSource
    var onMismatch: @Sendable (NSRange?) -> Void = { _ in }

    init(source: AXTextFocusSource) {
        self.source = source
    }

    private var isFocused: Bool {
        source.isTrusted && source.frontmostBundleID == TextFocusTracker.notesBundleID
            && source.focusedRole == TextFocusTracker.editorRole
    }

    private var textLength: Int? { isFocused ? source.textLength : nil }

    func buffer() -> VimBuffer? {
        guard isFocused, let text = source.text, let selection = source.selectedRange() else { return nil }
        return VimBuffer(text: text, selection: selection)
    }

    func perform(_ action: VimAction) -> Bool {
        switch action {
        case .select(let range):
            return select(range)
        case .delete(let range):
            guard buffer()?.deleteWouldHitBlockAttachment(range) == false,
                  select(range), let before = textLength else { return false }
            Self.post(keyCode: 51)
            return wait { $0 == before - range.length }
        case .insert(let text, let offset):
            guard select(NSRange(location: offset, length: 0)), let before = textLength else { return false }
            let applied = { (length: Int?) in length == before + text.utf16.count }
            if text == "\n" {
                Self.post(keyCode: 36)
                return wait(applied)
            }
            return paste(text, until: applied)
        case .undo:
            let before = textLength
            Self.post(keyCode: 6, flags: .maskCommand)
            // ponytail: an undo that keeps the length just waits out the timeout; compare text if that feels slow
            _ = wait(attempts: 150) { $0 != before }
            return true
        }
    }

    private func select(_ range: NSRange) -> Bool {
        guard isFocused, let length = source.textLength else { return false }
        let location = min(max(range.location, 0), length)
        source.setSelectedRange(NSRange(location: location, length: min(max(range.length, 0), length - location)))
        guard source.selectedRange() == range else {
            log.info("Vim: selection write read back differently; passing keys through on this line")
            onMismatch(buffer()?.caretLine)
            return false
        }
        return true
    }

    private func paste(_ text: String, until applied: (Int?) -> Bool) -> Bool {
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
        Self.post(keyCode: 9, flags: .maskCommand)
        let ok = wait(applied)
        pasteboard.clearContents()
        pasteboard.writeObjects(saved)
        return ok
    }

    static func post(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let pid = NSRunningApplication.runningApplications(
            withBundleIdentifier: TextFocusTracker.notesBundleID
        ).first?.processIdentifier else { return }
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: eventTag)
            event.postToPid(pid)
        }
    }

    /// Polls the note's length until Notes has applied a synthesized edit, so the next action reads fresh text.
    private func wait(attempts: Int = 250, _ done: (Int?) -> Bool) -> Bool {
        for _ in 0..<attempts {
            if done(textLength) { return true }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return false
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
        label.stringValue = switch mode {
        case .normal: "-- NORMAL --"
        case .insert: "-- INSERT --"
        case .visual: "-- VISUAL --"
        }
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
