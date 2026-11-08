import CoreGraphics
import Foundation
import NotesCore

/// Reports a focused Notes text area, so the overlays appear without Notes.
@MainActor
final class FakeTextFocusSource: TextFocusSource {
    let isTrusted = true
    let frontmostBundleID: String? = TextFocusTracker.notesBundleID
    let focusedRole: String? = TextFocusTracker.editorRole
    let text: String?
    let frame: CGRect?
    var textLength: Int? { text.map { ($0 as NSString).length } }
    private var selection: NSRange
    private let boundsFor: (NSRange) -> CGRect?

    init(
        frame: CGRect, text: String = "", selection: NSRange = NSRange(location: 0, length: 0),
        boundsFor: @escaping (NSRange) -> CGRect? = { _ in nil }
    ) {
        self.frame = frame
        self.text = text
        self.selection = selection
        self.boundsFor = boundsFor
    }

    func selectedRange() -> NSRange? { selection }
    func setSelectedRange(_ range: NSRange) { selection = range }
    func bounds(for range: NSRange) -> CGRect? { boundsFor(range) }
    func startObserving(_ onChange: @escaping () -> Void) {}
    func stopObserving() {}
}
