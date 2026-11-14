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
            guard let release = UpdateCheck.latest(from: data, product: name, repository: ProductInfo.main?.repository) else {
                return show("Couldn't check for updates", "GitHub sent an answer this app does not understand.")
            }
            guard UpdateCheck.isNewer(release.version, than: current) else {
                return show("You're up to date", "\(name) \(current) is the latest version.")
            }
            let kind = UpdateCheck.installKind(bundlePath: Bundle.main.bundlePath, product: name)
            let prompt = UpdatePrompt(release: release, current: current, kind: kind, product: name)
            if present(prompt, release.url) == .install { await install(release, current: current, product: name) }
        } catch {
            show("Couldn't check for updates", "Check your internet connection and try again.")
        }
    }

    private static func install(_ release: Release, current: String, product: String) async {
        guard let repository = ProductInfo.main?.repository else { return }
        let installed = Bundle.main.bundleURL
        let window = UpdateProgressWindow()
        let task = Task {
            try await UpdateStager.stage(
                release, installed: installed, runningVersion: current, product: product, repository: repository,
                progress: { fraction in Task { @MainActor in window.show(fraction < 1 ? .downloading : .verifying, fraction) } })
        }
        var cancelRequested = false
        window.onCancel = {
            cancelRequested = true
            task.cancel()
        }
        window.show(.downloading, 0)
        do {
            let staged = try await task.value
            window.show(.replacing, 0)
            try UpdateInstaller.install(
                staged, over: installed, isCancelled: { cancelRequested }, beginSwap: window.lockCancel)
            window.show(.relaunching, 0)
            try UpdateRelaunch.launch(app: installed)
            NSApp.terminate(nil)
        } catch {
            window.close()
            let failure = error as? UpdateFailure ?? .replaceFailed(error.localizedDescription)
            if failure != .cancelled { showFailure(failure, release: release, product: product) }
        }
    }

    private static func showFailure(_ failure: UpdateFailure, release: Release, product: String) {
        let prompt = UpdateFailurePrompt(failure: failure, product: product, version: release.version)
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.info
        prompt.buttons.forEach { alert.addButton(withTitle: $0.title) }
        NSApp.activate()
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if prompt.buttons[index].action == .openReleasePage { NSWorkspace.shared.open(release.url) }
    }

    private static func present(_ prompt: UpdatePrompt, _ page: URL) -> UpdatePrompt.Action {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.info
        prompt.buttons.forEach { alert.addButton(withTitle: $0.title) }
        if !prompt.notes.isEmpty { alert.accessoryView = notesView(prompt.notes) }
        NSApp.activate()
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let action = prompt.buttons[index].action
        switch action {
        case .openReleasePage: NSWorkspace.shared.open(page)
        case .copyCommand:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt.command ?? "", forType: .string)
        case .install, .later, .close: break
        }
        return action
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
