import AppKit
import NotesCore

/// "Check for Updates…": one request to GitHub when the person clicks, then a window. It never runs on its own.
@MainActor
enum UpdateAction {
    static func run() async {
        let current = ProductInfo.main?.version ?? "0"
        let name = ProductInfo.main?.name ?? "This app"
        guard let url = ProductInfo.main?.repository.flatMap(UpdateCheck.endpoint(repository:)) else {
            return show("Couldn't check for updates", "The release location is not set in this build.")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                return show("No release yet", "\(name) \(current) is the only version so far.")
            }
            guard let release = UpdateCheck.latest(from: data, product: name) else {
                return show("Couldn't check for updates", "GitHub sent an answer this app does not understand.")
            }
            guard UpdateCheck.isNewer(release.version, than: current) else {
                return show("You're up to date", "\(name) \(current) is the latest version.")
            }
            let kind = UpdateCheck.installKind(bundlePath: Bundle.main.bundlePath, product: name)
            present(UpdatePrompt(release: release, current: current, kind: kind, product: name), release.url)
        } catch {
            show("Couldn't check for updates", "Check your internet connection and try again.")
        }
    }

    private static func present(_ prompt: UpdatePrompt, _ page: URL) {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.info
        prompt.buttons.forEach { alert.addButton(withTitle: $0.title) }
        if !prompt.notes.isEmpty { alert.accessoryView = notesView(prompt.notes) }
        NSApp.activate()
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        switch prompt.buttons[index].action {
        case .openReleasePage: NSWorkspace.shared.open(page)
        case .copyCommand:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt.command ?? "", forType: .string)
        case .later: break
        }
    }

    private static func notesView(_ blocks: [NotesBlock]) -> NSView {
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
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 160))
        view.isEditable = false
        view.drawsBackground = false
        view.textStorage?.setAttributedString(text)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 160))
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        return scroll
    }

    private static func show(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }
}
