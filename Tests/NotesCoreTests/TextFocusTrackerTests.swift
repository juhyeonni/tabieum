import CoreGraphics
import Foundation
import Testing
@testable import NotesCore

@MainActor
final class FakeSource: TextFocusSource {
    var isTrusted = true
    var frontmostBundleID: String? = TextFocusTracker.notesBundleID
    var focusedRole: String? = TextFocusTracker.editorRole
    var text: String? = "hello"
    var selection = NSRange(location: 0, length: 0)
    var boundsByRange: [NSRange: CGRect] = [:]
    var boundsQueries: [NSRange] = []
    var setRanges: [NSRange] = []
    var startCount = 0
    var stopCount = 0
    var onChange: (() -> Void)?

    var textLength: Int? { text?.utf16.count }
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

    source.focusedRole = "AXTextField"
    #expect(!tracker.isFocused)
    #expect(tracker.state == .notFocused)

    source.focusedRole = TextFocusTracker.editorRole
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
    source.text = ""
    #expect(TextFocusTracker(source: source).caretRect() == nil)
    #expect(source.boundsQueries == [NSRange(location: 0, length: 0)])
}

@MainActor @Test func nonZeroCaretAndSelectionUseTheirOwnBounds() {
    let source = FakeSource()
    let caret = CGRect(x: 5, y: 5, width: 0, height: 18)
    source.boundsByRange[NSRange(location: 0, length: 0)] = caret
    #expect(TextFocusTracker(source: source).caretRect() == caret)

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
