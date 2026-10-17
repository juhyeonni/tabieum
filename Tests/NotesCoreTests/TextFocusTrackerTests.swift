import CoreGraphics
import Foundation
import Testing
@testable import NotesCore

@MainActor
final class FakeSource: TextFocusSource {
    var isTrusted = true
    var frontmostBundleID: String? = TextFocusTracker.notesBundleID
    var focusedRole: String? { focusChecks += 1; return role }
    var role: String? = TextFocusTracker.editorRole
    var focusChecks = 0
    var textReads = 0
    var text: String? { textReads += 1; return content }
    var content: String? = "hello"
    var frame: CGRect?
    var selection = NSRange(location: 0, length: 0)
    var boundsByRange: [NSRange: CGRect] = [:]
    var boundsQueries: [NSRange] = []
    var setRanges: [NSRange] = []
    var startCount = 0
    var stopCount = 0
    var onChange: (() -> Void)?

    var textLength: Int? { content?.utf16.count }
    func selectedRange() -> NSRange? { selection }
    func setSelectedRange(_ range: NSRange) { setRanges.append(range) }
    func bounds(for range: NSRange) -> CGRect? {
        boundsQueries.append(range)
        return boundsByRange[range] ?? .zero
    }
    func startObserving(_ onChange: @escaping () -> Void) {
        startCount += 1
        self.onChange = onChange
    }
    func stopObserving() {
        stopCount += 1
        onChange = nil
    }
}

// AC1
@Test func axRectOnPrimaryScreenFlipsY() {
    let rect = appKitRect(fromAX: CGRect(x: 100, y: 50, width: 2, height: 18), primaryScreenHeight: 900)
    #expect(rect == CGRect(x: 100, y: 832, width: 2, height: 18))
}

@Test func axRectOnScreenAbovePrimary() {
    // A 1920x1080 screen above a 1440x900 primary has negative AX y.
    let rect = appKitRect(fromAX: CGRect(x: 100, y: -1000, width: 2, height: 18), primaryScreenHeight: 900)
    #expect(rect == CGRect(x: 100, y: 1882, width: 2, height: 18))
}

@Test func axRectOnScreenLeftOfPrimary() {
    // A taller screen to the left, bottom-aligned with the primary: its top is at AX y = -180.
    let rect = appKitRect(fromAX: CGRect(x: -1000, y: -180, width: 10, height: 20), primaryScreenHeight: 900)
    #expect(rect == CGRect(x: -1000, y: 1060, width: 10, height: 20))
}

// AC2
@MainActor @Test func focusedOnlyForNotesTextArea() {
    let source = FakeSource()
    let tracker = TextFocusTracker(source: source)
    #expect(tracker.isFocused)

    source.role = "AXTextField"
    #expect(!tracker.isFocused)
    #expect(tracker.state == .notFocused)

    source.role = TextFocusTracker.editorRole
    source.frontmostBundleID = "com.apple.Safari"
    #expect(!tracker.isFocused)
}

@MainActor @Test func notFocusedWithoutPermission() {
    let source = FakeSource()
    source.isTrusted = false
    let tracker = TextFocusTracker(source: source)
    #expect(!tracker.isFocused)
    #expect(tracker.caretRect() == nil)
    #expect(tracker.selectedRange() == nil)
}

// AC3
@MainActor @Test func zeroSizeCaretFallsBackToPreviousCharacter() {
    let source = FakeSource()
    source.selection = NSRange(location: 3, length: 0)
    let previous = CGRect(x: 30, y: 10, width: 8, height: 18)
    source.boundsByRange[NSRange(location: 2, length: 1)] = previous
    #expect(TextFocusTracker(source: source).caretRect() == previous)

    source.boundsByRange = [:]
    #expect(TextFocusTracker(source: source).caretRect() == nil)
}

@MainActor @Test func zeroSizeCaretAtStartFallsBackToNextCharacter() {
    let source = FakeSource()
    let next = CGRect(x: 10, y: 10, width: 8, height: 18)
    source.boundsByRange[NSRange(location: 0, length: 1)] = next
    #expect(TextFocusTracker(source: source).caretRect() == next)
}

@MainActor @Test func zeroSizeCaretInEmptyTextHasNoRect() {
    let source = FakeSource()
    source.content = ""
    #expect(TextFocusTracker(source: source).caretRect() == nil)
    #expect(source.boundsQueries.isEmpty)
}

@MainActor @Test func zeroSizeCaretAtLineStartUsesCharacterAtCaret() {
    let source = FakeSource()
    source.content = "ab\ncd"
    source.selection = NSRange(location: 3, length: 0)
    let atCaret = CGRect(x: 10, y: 30, width: 8, height: 18)
    source.boundsByRange[NSRange(location: 2, length: 1)] = CGRect(x: 20, y: 10, width: 8, height: 18)
    source.boundsByRange[NSRange(location: 3, length: 1)] = atCaret
    #expect(TextFocusTracker(source: source).caretRect() == atCaret)

    for separator in ["\r", "\u{2028}", "\u{2029}"] {
        source.content = "ab" + separator + "cd"
        #expect(TextFocusTracker(source: source).caretRect() == atCaret)
    }
}

@MainActor @Test func zeroSizeCaretOnEmptyLineUsesItsOwnLineBreak() {
    let source = FakeSource()
    source.content = "ab\n\ncd"
    source.selection = NSRange(location: 3, length: 0)
    let emptyLine = CGRect(x: 10, y: 30, width: 1, height: 18)
    source.boundsByRange[NSRange(location: 2, length: 1)] = CGRect(x: 20, y: 10, width: 1, height: 18)
    source.boundsByRange[NSRange(location: 3, length: 1)] = emptyLine
    #expect(TextFocusTracker(source: source).caretRect() == emptyLine)
}

@MainActor @Test func zeroSizeCaretAfterTrailingLineBreakHasNoRect() {
    let source = FakeSource()
    source.content = "ab\n"
    source.selection = NSRange(location: 3, length: 0)
    source.boundsByRange[NSRange(location: 2, length: 1)] = CGRect(x: 20, y: 10, width: 1, height: 18)
    #expect(TextFocusTracker(source: source).caretRect() == nil)
}

@MainActor @Test func emptyRangeRectWithHeightIsNotTrusted() {
    let source = FakeSource()
    source.selection = NSRange(location: 3, length: 0)
    source.boundsByRange[NSRange(location: 3, length: 0)] = CGRect(x: 40, y: 92, width: 0, height: 28)
    let previous = CGRect(x: 30, y: 120, width: 8, height: 28)
    source.boundsByRange[NSRange(location: 2, length: 1)] = previous
    #expect(TextFocusTracker(source: source).caretRect() == previous)
}

@MainActor @Test func selectionUsesItsOwnBounds() {
    let source = FakeSource()
    source.selection = NSRange(location: 1, length: 3)
    let selected = CGRect(x: 10, y: 5, width: 24, height: 18)
    source.boundsByRange[source.selection] = selected
    #expect(TextFocusTracker(source: source).caretRect() == selected)
}

// AC4
@MainActor @Test func settingRangeBeyondTextClamps() {
    let source = FakeSource()
    let tracker = TextFocusTracker(source: source)
    tracker.setSelectedRange(NSRange(location: 3, length: 10))
    tracker.setSelectedRange(NSRange(location: 99, length: 1))
    tracker.setSelectedRange(NSRange(location: 1, length: 2))
    #expect(source.setRanges == [
        NSRange(location: 3, length: 2),
        NSRange(location: 5, length: 0),
        NSRange(location: 1, length: 2),
    ])
}

// AC5
@MainActor @Test func observesOnlyWhileSubscribed() {
    let source = FakeSource()
    let tracker = TextFocusTracker(source: source)
    #expect(source.startCount == 0)

    var received: [TextFocusState] = []
    let first = tracker.subscribe { received.append($0) }
    let second = tracker.subscribe { _ in }
    #expect(source.startCount == 1)
    #expect(received.count == 1)

    source.onChange?()
    #expect(received.count == 2)

    tracker.unsubscribe(first)
    #expect(source.stopCount == 0)
    tracker.unsubscribe(second)
    #expect(source.stopCount == 1)
    tracker.unsubscribe(second)
    #expect(source.stopCount == 1)

    _ = tracker.subscribe { _ in }
    #expect(source.startCount == 2)
}

// AC1, AC2
@MainActor @Test func subscribersShareOneTextReadAndFocusCheckPerNotification() {
    let source = FakeSource()
    let tracker = TextFocusTracker(source: source)
    var seen: [String?] = []
    for _ in 0..<3 {
        _ = tracker.subscribe { _ in
            _ = tracker.isFocused
            seen.append(tracker.snapshot()?.text)
            _ = tracker.buffer()
        }
    }
    source.textReads = 0
    source.focusChecks = 0
    source.onChange?()
    #expect(source.textReads == 1)
    #expect(source.focusChecks == 1)
    #expect(seen.suffix(3) == ["hello", "hello", "hello"])

    source.content = "changed"
    seen = []
    source.onChange?()
    #expect(seen == ["changed", "changed", "changed"])
}

@MainActor @Test func readsOutsideANotificationAreLive() {
    let source = FakeSource()
    let tracker = TextFocusTracker(source: source)
    _ = tracker.subscribe { _ in }
    source.textReads = 0
    _ = tracker.snapshot()
    _ = tracker.snapshot()
    #expect(source.textReads == 2)
}

@MainActor @Test func polledTextLengthDropsTheNotificationsTextRead() {
    let source = FakeSource()
    let tracker = TextFocusTracker(source: source)
    var lengths: [Int?] = []
    var texts: [String?] = []
    _ = tracker.subscribe { _ in
        texts.append(tracker.snapshot()?.text)
        source.content = "edited"
        lengths.append(tracker.textLength)
        texts.append(tracker.snapshot()?.text)
    }
    #expect(lengths == [6])
    #expect(texts == ["hello", "edited"])
}

// AC3
@MainActor @Test func noBoundsQueryUnlessASubscriberNeedsTheCaretRect() {
    let source = FakeSource()
    source.selection = NSRange(location: 3, length: 0)
    let tracker = TextFocusTracker(source: source)
    _ = tracker.subscribe { _ in }
    source.onChange?()
    #expect(source.boundsQueries.isEmpty)

    var rects: [CGRect?] = []
    source.boundsByRange[NSRange(location: 2, length: 1)] = CGRect(x: 1, y: 2, width: 3, height: 4)
    _ = tracker.subscribe(needsCaretRect: true) { rects.append($0.caretRect) }
    source.boundsQueries = []
    source.onChange?()
    #expect(source.boundsQueries.count == 1)
    #expect(rects.last == CGRect(x: 1, y: 2, width: 3, height: 4))
}

private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
private let popup = CGSize(width: 360, height: 240)

@Test func popupSitsBelowAMidScreenAnchorAndAboveABottomOne() {
    #expect(popupFrame(anchor: CGRect(x: 100, y: 400, width: 10, height: 20), size: popup, visible: screen).origin == CGPoint(x: 100, y: 160))
    #expect(popupFrame(anchor: CGRect(x: 100, y: 50, width: 10, height: 20), size: popup, visible: screen).origin == CGPoint(x: 100, y: 70))
}

@Test func popupStaysInsideForAScreenHighAnchor() {
    let frame = popupFrame(anchor: CGRect(x: 100, y: 0, width: 10, height: 800), size: popup, visible: screen)
    #expect(screen.contains(frame))
}

@Test func popupStaysInsideHorizontally() {
    #expect(popupFrame(anchor: CGRect(x: -5, y: 400, width: 10, height: 20), size: popup, visible: screen).minX == 0)
    #expect(popupFrame(anchor: CGRect(x: 990, y: 400, width: 10, height: 20), size: popup, visible: screen).maxX == 1000)
}

@Test @MainActor func selectionAnchorsAtItsLastCharacter() {
    let source = FakeSource()
    source.content = "hello"
    source.selection = NSRange(location: 0, length: 5)
    let last = CGRect(x: 40, y: 10, width: 8, height: 18)
    source.boundsByRange[NSRange(location: 4, length: 1)] = last
    source.boundsByRange[NSRange(location: 0, length: 5)] = CGRect(x: 0, y: 0, width: 48, height: 18)
    #expect(TextFocusTracker(source: source).caretRect() == last)
}
