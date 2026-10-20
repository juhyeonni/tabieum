import CoreGraphics
import Foundation
import NotesCore

/// Reports a focused Notes text area, so the overlays appear without Notes.
@MainActor
final class FakeTextFocusSource: TextFocusSource {
    let isTrusted = true
    let frontmostBundleID: String? = TextFocusTracker.notesBundleID
    let focusedRole: String? = TextFocusTracker.editorRole
    var text: String? = ""
    var textLength: Int? { text.map { ($0 as NSString).length } }
    var frame: CGRect?
    private var selection = NSRange(location: 0, length: 0)

    init(frame: CGRect) {
        self.frame = frame
    }

    func selectedRange() -> NSRange? { selection }
    func setSelectedRange(_ range: NSRange) { selection = range }
    func bounds(for range: NSRange) -> CGRect? { nil }
    func startObserving(_ onChange: @escaping () -> Void) {}
    func stopObserving() {}
}
