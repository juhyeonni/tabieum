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
    func selectedRange() -> NSRange?
    func setSelectedRange(_ range: NSRange)
    func bounds(for range: NSRange) -> CGRect?
    func startObserving(_ onChange: @escaping () -> Void)
    func stopObserving()
}

public struct TextFocusState: Equatable, Sendable {
    public var isFocused: Bool
    public var selection: NSRange?
    /// In AX coordinates.
    public var caretRect: CGRect?

    public static let notFocused = TextFocusState(isFocused: false)

    public init(isFocused: Bool, selection: NSRange? = nil, caretRect: CGRect? = nil) {
        self.isFocused = isFocused
        self.selection = selection
        self.caretRect = caretRect
    }
}

@MainActor
public final class TextFocusTracker {
    nonisolated public static let notesBundleID = "com.apple.Notes"
    nonisolated public static let editorRole = "AXTextArea"

    private let source: TextFocusSource
    private var subscribers: [Int: (TextFocusState) -> Void] = [:]
    private var nextID = 0

    public init(source: TextFocusSource) {
        self.source = source
    }

    public var isFocused: Bool {
        source.isTrusted
            && source.frontmostBundleID == Self.notesBundleID
            && source.focusedRole == Self.editorRole
    }

    public var state: TextFocusState {
        guard isFocused else { return .notFocused }
        return TextFocusState(isFocused: true, selection: source.selectedRange(), caretRect: caretRect())
    }

    public func selectedRange() -> NSRange? {
        isFocused ? source.selectedRange() : nil
    }

    /// The note text and caret, or nil without a focused note body or with a non-empty selection.
    public func snapshot() -> TextSnapshot? {
        guard isFocused, let text = source.text, let range = source.selectedRange(), range.length == 0 else { return nil }
        return TextSnapshot(text: text, caret: range.location)
    }

    public var textLength: Int? {
        isFocused ? source.textLength : nil
    }

    public func buffer() -> VimBuffer? {
        guard isFocused, let text = source.text, let selection = source.selectedRange() else { return nil }
        return VimBuffer(text: text, selection: selection)
    }

    public func setSelectedRange(_ range: NSRange) {
        guard isFocused, let length = source.textLength else { return }
        let location = min(max(range.location, 0), length)
        source.setSelectedRange(NSRange(location: location, length: min(max(range.length, 0), length - location)))
    }

    public func caretRect() -> CGRect? {
        guard isFocused, let range = source.selectedRange() else { return nil }
        let rect = source.bounds(for: range)
        if let rect, range.length > 0 || rect.size != .zero { return rect }
        if range.length > 0 { return nil }
        return neighbourBounds(of: range.location)
    }

    private func neighbourBounds(of caret: Int) -> CGRect? {
        let neighbour: NSRange
        if caret > 0 {
            neighbour = NSRange(location: caret - 1, length: 1)
        } else {
            guard let length = source.textLength, length > 0 else { return nil }
            neighbour = NSRange(location: 0, length: 1)
        }
        guard let rect = source.bounds(for: neighbour), rect.size != .zero else { return nil }
        return rect
    }

    /// Observing starts with the first subscriber and stops after the last one leaves.
    public func subscribe(_ handler: @escaping (TextFocusState) -> Void) -> Int {
        nextID += 1
        subscribers[nextID] = handler
        if subscribers.count == 1 {
            source.startObserving { [weak self] in self?.notify() }
        }
        handler(state)
        return nextID
    }

    public func unsubscribe(_ id: Int) {
        guard subscribers.removeValue(forKey: id) != nil, subscribers.isEmpty else { return }
        source.stopObserving()
    }

    private func notify() {
        let current = state
        for handler in subscribers.values { handler(current) }
    }
}
