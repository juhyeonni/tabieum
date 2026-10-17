import AppKit
import NotesCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private let status = PermissionStatus()
    private let toggles = FeatureToggles()
    private lazy var ai = AIFeature(toggles: toggles, factory: AISettings.makeProvider)
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let tracker = TextFocusTracker(source: AXTextFocusSource())
    private lazy var caretOverlay = CaretOverlay(tracker: tracker)
    private var markdownShortcuts: MarkdownShortcuts?
    private var vim: VimController?
    private var slashCommands: SlashCommands?
    private var indexService: IndexService?
    private let embeddingItem = NSMenuItem()
    private let embedding = EmbeddingState()
    private let modelInstall = ModelInstall()
    private var backlinksPanel: BacklinksPanel?
    private var searchPanel: SearchPanel?
    private var writeServer: WriteSocketServer?
    private let panelEmbedder = ConfiguredEmbedder(e5: E5Embedder(store: E5Embedder.standardStore(), idleSeconds: 300))
    private lazy var searchShortcut = ShortcutController(
        toggles: toggles, title: "Search shortcut", id: 1, keyPath: \.searchShortcut) { [weak self] in self?.searchPanel?.show() }
    private lazy var copyMarkdownShortcut = ShortcutController(
        toggles: toggles, title: "Copy as Markdown shortcut", id: 2, keyPath: \.copyMarkdownShortcut) { CopyNoteAction.markdown() }
    private lazy var copyLinkShortcut = ShortcutController(
        toggles: toggles, title: "Copy Deeplink shortcut", id: 3, keyPath: \.copyLinkShortcut) { CopyNoteAction.link() }
    private var aiAssistant: AIAssistant?
    private var actionButton: ActionButton?

    /// An accessory app has no menu bar, so the standard editing shortcuts need an Edit menu to reach a text field.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        let name = ProductInfo.main?.name ?? ProcessInfo.processInfo.processName
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: name)
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        let overlayItem = menu.addItem(withTitle: "Show Caret Overlay", action: #selector(toggleCaretOverlay(_:)), keyEquivalent: "")
        overlayItem.target = self
        menu.addItem(withTitle: "Show Vim Latency", action: #selector(toggleVimLatency(_:)), keyEquivalent: "").target = self
        embeddingItem.isEnabled = false
        embeddingItem.isHidden = true
        menu.addItem(embeddingItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        ai.config = AISettings.savedConfig()
        markdownShortcuts = MarkdownShortcuts(tracker: tracker, toggles: toggles)
        vim = VimController(tracker: tracker, toggles: toggles)
        let slash = SlashCommands(tracker: tracker, toggles: toggles)
        slashCommands = slash
        aiAssistant = AIAssistant(
            tracker: tracker, toggles: toggles, feature: ai,
            indexURL: ProductInfo.main.map { SearchIndex.defaultURL(bundleIdentifier: $0.bundleIdentifier) }, registry: slash.registry)
        actionButton = ActionButton(tracker: tracker, toggles: toggles) { [weak self] item in
            switch item {
            case .copyMarkdown: CopyNoteAction.markdown()
            case .copyDeeplink: CopyNoteAction.link()
            case .backlinks: if self?.backlinksPanel?.isVisible == false { self?.backlinksPanel?.toggle() }
            case .askNotes: self?.aiAssistant?.open()
            case .settings: self?.showSettings()
            }
        }
        vim?.claimsKey = { [weak self] in self?.slashCommands?.claims(keyCode: $0) ?? false }
        if let bundleIdentifier = ProductInfo.main?.bundleIdentifier {
            let indexURL = SearchIndex.defaultURL(bundleIdentifier: bundleIdentifier)
            let service = IndexService(
                indexURL: indexURL,
                ragEnabled: { UserDefaults.standard.bool(forKey: "ragEnabled") },
                onProgress: { progress in Task { @MainActor in self.showEmbedding(progress) } })
            service.start()
            indexService = service
            if toggles.embeddingModel == .e5Small { installModel() }
            searchPanel = SearchPanel(indexURL: SearchIndex.defaultURL(bundleIdentifier: bundleIdentifier)) { [weak self] in
                guard let self, toggles.ragEnabled, toggles.semanticPanelSearch else { return nil }
                return panelEmbedder
            }
            backlinksPanel = BacklinksPanel(indexURL: indexURL)
            startWriteServer(bundleIdentifier: bundleIdentifier)
        }
        _ = (searchShortcut, copyMarkdownShortcut, copyLinkShortcut)

        Task {
            await status.refresh()
            if !status.allGranted { showOnboarding() }
        }
    }

    private func startWriteServer(bundleIdentifier: String) {
        let service = NoteWriteService(
            settings: { WriteSettings(defaults: .standard) }, writer: AppleScriptNotesWriter(), confirmer: AlertConfirmer(),
            productName: ProductInfo.main?.name ?? "NoteKit")
        let server = WriteSocketServer(path: NoteWriteService.socketURL(bundleIdentifier: bundleIdentifier), service: service)
        do {
            try server.start()
            writeServer = server
        } catch {
            NSLog("Could not start the write socket: \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        writeServer?.stop()
    }

    @objc private func showSettings() {
        let created = settingsWindow == nil
        let window = settingsWindow ?? makeWindow(title: "Settings", view: SettingsView(
            status: status, toggles: toggles, ai: ai, embedding: embedding, install: modelInstall,
            shortcuts: [searchShortcut, copyMarkdownShortcut, copyLinkShortcut],
            showOnboarding: { [weak self] in self?.showOnboarding() }, setRAG: { [weak self] in self?.setRAG($0) },
            chooseModel: { [weak self] in self?.chooseModel($0) }, retryInstall: { [weak self] in self?.installModel() }))
        window.styleMask.insert(.resizable)
        if created {
            window.setContentSize(NSSize(width: 800, height: 700))
            window.center()
        }
        settingsWindow = window
        show(window)
    }

    private func showEmbedding(_ progress: EmbeddingProgress?) {
        embedding.progress = progress
        guard let progress else {
            embeddingItem.isHidden = true
            return
        }
        embeddingItem.title = progress.waitingForModel ? "Embedding: waiting for model" : "Embedding \(progress.done) / \(progress.total)"
        embeddingItem.isHidden = false
    }

    private func setRAG(_ on: Bool) {
        guard on else {
            toggles.ragEnabled = false
            indexService?.requestSync()
            return
        }
        if toggles.embeddingModel == .e5Small {
            toggles.ragEnabled = true
            installModel()
            indexService?.requestSync()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Download Apple's embedding model?"
        alert.informativeText = "RAG search needs Apple's on-device embedding model. macOS downloads it once. Your notes never leave this Mac."
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        toggles.ragEnabled = true
        indexService?.requestSync()
        Task {
            await AppleEmbedder.requestAssets()
            indexService?.requestSync()
        }
    }

    private func chooseModel(_ model: EmbeddingModel) {
        guard model == .e5Small else {
            toggles.embeddingModel = .apple
            indexService?.requestSync()
            Task {
                await AppleEmbedder.requestAssets()
                indexService?.requestSync()
            }
            return
        }
        guard E5Embedder.standardStore().isInstalled(.e5Small) || confirmModelDownload() else { return }
        toggles.embeddingModel = .e5Small
        installModel()
        indexService?.requestSync()
    }

    private func confirmModelDownload() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Download the tabieum-e5-small-coreml model?"
        alert.informativeText = "A Core ML conversion of multilingual-e5-small. It is "
            + "\(ByteCountFormatter.string(fromByteCount: ModelSource.e5Small.downloadSize, countStyle: .file)) "
            + "and downloaded once from huggingface.co. Only the model is downloaded; your notes never leave this Mac."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func installModel() {
        modelInstall.startIfNeeded { [weak self] in self?.indexService?.requestSync() }
    }

    private func showOnboarding() {
        let window = onboardingWindow ?? makeWindow(title: "Permissions", view: OnboardingView(
            status: status, later: { [weak self] in self?.onboardingWindow?.close() }))
        onboardingWindow = window
        show(window)
    }

    private func makeWindow(title: String, view: some View) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask.remove(.resizable)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func show(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        status.setPolling(true)
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let anyVisible = [onboardingWindow, settingsWindow].contains { $0 != nil && $0 !== closing && $0!.isVisible }
        status.setPolling(anyVisible)
    }

    @objc private func checkForUpdates() {
        Task { await UpdateAction.run() }
    }

    @objc private func toggleVimLatency(_ sender: NSMenuItem) {
        guard let vim else { return }
        vim.showsLatency.toggle()
        sender.state = vim.showsLatency ? .on : .off
    }

    @objc private func toggleCaretOverlay(_ sender: NSMenuItem) {
        caretOverlay.toggle()
        sender.state = caretOverlay.isOn ? .on : .off
    }
}

if CommandLine.arguments.contains("--mcp") {
    let info = ProductInfo.main
    MCPServer(
        serverName: info?.name ?? "tabieum",
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        indexURL: SearchIndex.defaultURL(bundleIdentifier: info?.bundleIdentifier ?? "dev.juhyeonni.tabieum"),
        isEnabled: { UserDefaults.standard.bool(forKey: "mcpEnabled") },
        ragEnabled: { UserDefaults.standard.bool(forKey: "ragEnabled") }
    ).runStdio()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
