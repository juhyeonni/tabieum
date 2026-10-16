import AppKit
import Combine
import NotesCore
import os

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NotesExtension", category: "vim")

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
    private var mismatchLine: NSRange?
    private var swallowed: Set<Int64> = []
    private var queue: [VimCommand] = []
    private var draining = false

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
        if active {
            enqueue(command)
        } else if let arrow = fallbackArrowKeyCode(for: command) {
            post(keyCode: CGKeyCode(arrow))
        }
        return false
    }

    // MARK: - execution

    private func enqueue(_ command: VimCommand) {
        queue.append(command)
        guard !draining else { return }
        draining = true
        Task {
            while !queue.isEmpty {
                await run(queue.removeFirst())
            }
            draining = false
            refresh(tracker.state)
        }
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
            guard select(range), let before = tracker.textLength else { return false }
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
        case .undo:
            let before = tracker.textLength
            post(keyCode: 6, flags: .maskCommand)
            // ponytail: an undo that keeps the length just waits out the timeout; compare text if that feels slow
            _ = await wait(attempts: 30) { $0 != before }
            return true
        }
    }

    private func select(_ range: NSRange) -> Bool {
        tracker.setSelectedRange(range)
        guard tracker.selectedRange() == range else {
            mismatchLine = tracker.buffer()?.caretLine
            log.info("Vim: selection write read back differently; passing keys through on this line")
            refresh(tracker.state)
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
    private func wait(attempts: Int = 50, _ done: (Int?) -> Bool) async -> Bool {
        for _ in 0..<attempts {
            if done(tracker.textLength) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    // MARK: - focus

    private func refresh(_ state: TextFocusState) {
        guard tap != nil else { return }
        let buffer = tracker.buffer()
        if buffer?.caretLine != mismatchLine { mismatchLine = nil }
        active = buffer.map { !$0.caretLineHasAttachment && mismatchLine == nil } ?? false
        unsupported = buffer != nil && !active
        indicator.show(engine.mode, in: state.editorFrame)
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

    func show(_ mode: VimMode, in frame: CGRect?) {
        guard let frame, let primary = NSScreen.screens.first else { return hide() }
        label.stringValue = switch mode {
        case .normal: "-- NORMAL --"
        case .insert: "-- INSERT --"
        case .visual: "-- VISUAL --"
        }
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
