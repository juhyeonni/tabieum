import AppKit
import NotesCore

/// A window with a text view in place of Notes, so the overlays have something to sit on.
@MainActor
final class StandInEditor {
    static let text = """
        Weekly meeting
        Agenda for Friday: budget, hiring and the new office.
        Ask about the meeting room key.
        Books to read before the next meeting.
        """

    let window: NSWindow
    private let scrollView = NSTextView.scrollableTextView()
    private var textView: NSTextView { scrollView.documentView as! NSTextView }

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 160, y: 240, width: 640, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Editor"
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        textView.string = Self.text
        textView.font = .systemFont(ofSize: 16)
        Capture.lower(window)
        Capture.wait()
    }

    /// In AX coordinates.
    var frame: CGRect { axRect(scrollView.convert(scrollView.bounds, to: nil)) }

    /// In AX coordinates.
    func bounds(for range: NSRange) -> CGRect? {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return axRect(textView.convert(rect, to: nil))
    }

    func source(selection: NSRange) -> FakeTextFocusSource {
        FakeTextFocusSource(frame: frame, text: Self.text, selection: selection, boundsFor: { [self] in bounds(for: $0) })
    }

    private func axRect(_ rectInWindow: CGRect) -> CGRect {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        return appKitRect(fromAX: window.convertToScreen(rectInWindow), primaryScreenHeight: primary)
    }
}
