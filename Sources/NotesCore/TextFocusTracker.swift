import CoreGraphics
import Foundation

/// AX rects are global with a top-left origin at the primary screen; AppKit's origin is the primary screen's bottom-left.
public func appKitRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
}

/// The live Accessibility calls the tracker needs. Ranges count UTF-16 code units.
@MainActor
public protocol TextFocusSource: AnyObject {
    var isTrusted: Bool { get }
    var frontmostBundleID: String? { get }
    var focusedRole: String? { get }
    var textLength: Int? { get }
    var text: String? { get }
    /// The focused editor's frame, in AX coordinates.
    var frame: CGRect? { get }
    /// The characters scrolled into view, or nil when the editor does not say.
    var visibleRange: NSRange? { get }
    func selectedRange() -> NSRange?
    func setSelectedRange(_ range: NSRange)
    func bounds(for range: NSRange) -> CGRect?
    func startObserving(_ onChange: @escaping () -> Void)
    func stopObserving()
}

extension TextFocusSource {
    public var visibleRange: NSRange? { nil }
}

public struct TextFocusState: Equatable, Sendable {
    public var isFocused: Bool
    public var selection: NSRange?
    /// In AX coordinates.
    public var caretRect: CGRect?
    /// In AX coordinates.
    public var editorFrame: CGRect?

    public static let notFocused = TextFocusState(isFocused: false)

    public init(isFocused: Bool, selection: NSRange? = nil, caretRect: CGRect? = nil, editorFrame: CGRect? = nil) {
        self.isFocused = isFocused
        self.selection = selection
        self.caretRect = caretRect
        self.editorFrame = editorFrame
    }
}

@MainActor
public final class TextFocusTracker {
    nonisolated public static let notesBundleID = "com.apple.Notes"
    nonisolated public static let editorRole = "AXTextArea"

    private let source: TextFocusSource
    private var subscribers: [Int: (handler: (TextFocusState) -> Void, needsCaretRect: Bool)] = [:]
    private var nextID = 0
    /// Valid only while one change notification is delivered, so its subscribers share one read.
    private var cache: (focused: Bool, text: String??)?

    public init(source: TextFocusSource) {
        self.source = source
    }

    public var isFocused: Bool {
        if let cache { return cache.focused }
        return readFocused()
    }

    private func readFocused() -> Bool {
        source.isTrusted
            && source.frontmostBundleID == Self.notesBundleID
            && source.focusedRole == Self.editorRole
    }

    private var text: String? {
        if let cached = cache?.text { return cached }
        let text = source.text
        cache?.text = .some(text)
        return text
    }

    private func inNotification<T>(_ body: () -> T) -> T {
        guard cache == nil else { return body() }
        cache = (readFocused(), nil)
        defer { cache = nil }
        return body()
    }

    public var state: TextFocusState { state(withCaretRect: true) }

    public func state(withCaretRect: Bool) -> TextFocusState {
        guard isFocused else { return .notFocused }
        return TextFocusState(
            isFocused: true, selection: source.selectedRange(), caretRect: withCaretRect ? caretRect() : nil,
            editorFrame: source.frame)
    }

    public func selectedRange() -> NSRange? {
        isFocused ? source.selectedRange() : nil
    }

    /// The note text and caret, or nil without a focused note body or with a non-empty selection.
    public func snapshot() -> TextSnapshot? {
        guard isFocused, let text, let range = source.selectedRange(), range.length == 0 else { return nil }
        return TextSnapshot(text: text, caret: range.location)
    }

    /// Always read live: callers poll it to see an edit land, which also drops the text read earlier in this notification.
    public var textLength: Int? {
        cache?.text = nil
        return isFocused ? source.textLength : nil
    }

    public func buffer() -> VimBuffer? {
        guard isFocused, let text, let selection = source.selectedRange() else { return nil }
        return VimBuffer(text: text, selection: selection, visible: source.visibleRange)
    }

    public func setSelectedRange(_ range: NSRange) {
        guard isFocused, let length = source.textLength else { return }
        let location = min(max(range.location, 0), length)
        source.setSelectedRange(NSRange(location: location, length: min(max(range.length, 0), length - location)))
    }

    public func caretRect() -> CGRect? {
        guard isFocused, let range = source.selectedRange() else { return nil }
        if range.length > 0 { return source.bounds(for: range) }
        return neighbourBounds(of: range.location)
    }

    /// Notes puts the rect of an empty range one line too high, so a caret takes the bounds of a neighbouring character: the previous one unless it is a line break (which belongs to the line above), else the one at the caret.
    private func neighbourBounds(of caret: Int) -> CGRect? {
        guard let text = text.map({ $0 as NSString }) else { return nil }
        let location: Int
        if caret > 0, caret <= text.length, !Self.lineBreaks.contains(text.character(at: caret - 1)) {
            location = caret - 1
        } else if caret < text.length {
            location = caret
        } else {
            return nil
        }
        guard let rect = source.bounds(for: NSRange(location: location, length: 1)), rect.size != .zero else { return nil }
        return rect
    }

    private static let lineBreaks: Set<unichar> = [0x0A, 0x0D, 0x2028, 0x2029]

    /// Observing starts with the first subscriber and stops after the last one leaves.
    /// The caret rect costs AX bounds queries, so it is filled in only when a subscriber asks for it.
    public func subscribe(needsCaretRect: Bool = false, _ handler: @escaping (TextFocusState) -> Void) -> Int {
        nextID += 1
        subscribers[nextID] = (handler, needsCaretRect)
        if subscribers.count == 1 {
            source.startObserving { [weak self] in self?.notify() }
        }
        inNotification { handler(state(withCaretRect: needsCaretRect)) }
        return nextID
    }

    public func unsubscribe(_ id: Int) {
        guard subscribers.removeValue(forKey: id) != nil, subscribers.isEmpty else { return }
        source.stopObserving()
    }

    private func notify() {
        inNotification {
            let current = state(withCaretRect: subscribers.values.contains { $0.needsCaretRect })
            for subscriber in subscribers.values { subscriber.handler(current) }
        }
    }
}
