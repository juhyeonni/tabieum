import AppKit
import NotesCore

/// An opaque stand-in for NSAlert: the alert's frame is translucent on macOS 26.
@MainActor
final class UpdatePromptWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 460, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    private(set) var buttons: [NSButton] = []
    private(set) var notesView: NSScrollView?
    private(set) var chosen = 0

    init(title: String, text: String, notes: [NotesBlock], buttonTitles: [String]) {
        window.title = title
        window.isReleasedWhenClosed = false
        buttons = buttonTitles.enumerated().map { index, title in
            let button = NSButton(title: title, target: self, action: #selector(pressed(_:)))
            button.tag = index
            return button
        }
        buttons.first?.keyEquivalent = "\r"
        buttons.last?.keyEquivalent = "\u{1b}"

        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 13)
        let body = NSTextField(wrappingLabelWithString: text)
        body.preferredMaxLayoutWidth = 340
        var column: [NSView] = [heading, body]
        if !notes.isEmpty {
            let scroll = Self.notesView(notes)
            notesView = scroll
            column.append(scroll)
        }
        let texts = NSStackView(views: column)
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 10

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let top = NSStackView(views: [icon, texts])
        top.alignment = .top
        top.spacing = 16

        let row = NSStackView(views: [NSView()] + buttons.reversed())
        let content = NSStackView(views: [top, row])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        row.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        window.contentView = content
        window.setContentSize(content.fittingSize)
    }

    func run() -> Int {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return chosen
    }

    func press(_ index: Int) {
        chosen = index
        if NSApp.modalWindow === window { NSApp.stopModal() }
    }

    @objc private func pressed(_ sender: NSButton) { press(sender.tag) }

    private static func notesView(_ blocks: [NotesBlock]) -> NSScrollView {
        let text = NSMutableAttributedString()
        for block in blocks {
            let (source, font): (String, NSFont) = switch block {
            case .heading(let line): (line, .boldSystemFont(ofSize: 13))
            case .bullet(let line): ("•  " + line, .systemFont(ofSize: 12))
            case .code(let lines): (lines, .monospacedSystemFont(ofSize: 11, weight: .regular))
            case .paragraph(let line): (line, .systemFont(ofSize: 12))
            }
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let styled = (try? AttributedString(markdown: source, options: options))
                .map(NSAttributedString.init) ?? NSAttributedString(string: source)
            let piece = NSMutableAttributedString(attributedString: styled)
            let whole = NSRange(location: 0, length: piece.length)
            piece.addAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: whole)
            text.append(piece)
            text.append(NSAttributedString(string: "\n"))
        }
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 160))
        view.isEditable = false
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(text)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 160))
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        scroll.tile()
        view.setFrameSize(NSSize(width: scroll.contentSize.width, height: view.frame.height))
        scroll.widthAnchor.constraint(equalToConstant: 340).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        return scroll
    }
}
