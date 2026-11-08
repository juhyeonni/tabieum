import AppKit
import Combine
import NotesAI
import NotesCore

/// The AI panel: opened by the global shortcut or `/ai`, it streams a result and pastes it into Notes on Return.
@MainActor
final class AIAssistant {
    private let tracker: TextFocusTracker
    private let toggles: FeatureToggles
    private let feature: AIFeature
    private let indexURL: URL?
    private lazy var panel = AIPanel(
        run: { [weak self] in self?.run($0, instruction: $1, withContext: $2) },
        ask: { [weak self] in self?.ask($0) },
        accept: { [weak self] in self?.accept(below: $0) },
        allow: { [weak self] in self?.allow() },
        copy: { [weak self] in self?.copy() },
        cancel: { [weak self] in self?.cancel() })
    private var snapshot: VimBuffer?
    private var caret: CGRect = .zero
    private var action: AIAction = .prompt
    private var instruction = ""
    private var withContext = true
    private var result = ""
    private var consentHost: String?
    private var question: String?
    private var task: Task<Void, Never>?
    private var monitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    init(tracker: TextFocusTracker, toggles: FeatureToggles, feature: AIFeature, indexURL: URL?, registry: SlashCommandRegistry) {
        self.indexURL = indexURL
        self.tracker = tracker
        self.toggles = toggles
        self.feature = feature
        registry.register("AI", isVisible: { toggles.aiEnabled }) { [weak self] in
            // ponytail: fixed delay for Notes to process the deleted `/`; nothing reports when it has.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.open() }
        }
        Publishers.CombineLatest(toggles.$aiEnabled, toggles.$aiShortcut).sink { [weak self] on, key in
            MainActor.assumeIsolated { self?.register(on ? key : nil) }
        }.store(in: &cancellables)
    }

    private func register(_ key: HotKey?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard let key else {
            cancel()
            return
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            guard key.matches(keyCode: event.keyCode, flags: flags) else { return }
            MainActor.assumeIsolated { self?.open() }
        }
    }

    func open() {
        guard toggles.aiEnabled, !panel.isVisible, let buffer = tracker.buffer(),
              let rect = tracker.caretRect(), let primary = NSScreen.screens.first else { return }
        snapshot = buffer
        caret = appKitRect(fromAX: rect, primaryScreenHeight: primary.frame.height)
        panel.show(.input(hasSelection: buffer.selection.length > 0,
                          chip: aiContext(text: buffer.text, selection: buffer.selection).chip,
                          canAsk: indexURL != nil && canAskNotes(aiOn: toggles.aiEnabled, ragOn: toggles.ragEnabled)), at: caret)
    }

    private func ask(_ question: String) {
        guard let indexURL, canAskNotes(aiOn: toggles.aiEnabled, ragOn: toggles.ragEnabled) else { return }
        self.question = question
        panel.render(.streaming(""))
        task?.cancel()
        task = feature.perform { [weak self] provider in
            do {
                let found = try await Task.detached {
                    try SearchIndex(url: indexURL, readOnly: true).hybridSearch(question, embedder: ConfiguredEmbedder(), limit: askSourceCount)
                }.value
                let sources = askSources(from: found)
                guard !sources.isEmpty else {
                    self?.panel.render(.failed("No notes matched. Is the RAG index built?"))
                    return
                }
                var answer = ""
                for try await piece in provider.chat(askMessages(question: question, sources: sources)) {
                    guard !Task.isCancelled, let self else { return }
                    answer += piece
                    let shown = strippingThinkBlock(answer)
                    panel.render(.streaming(shown.drop { $0.isWhitespace }.hasPrefix("<think>") ? "Thinking…" : shown))
                }
                try Task.checkCancellation()
                let text = strippingThinkBlock(answer).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    self?.panel.render(.failed("The model returned nothing."))
                    return
                }
                let cited = citedSources(in: text, sources: sources).map { "• \($0.headingPath)" }
                self?.result = cited.isEmpty ? text : text + "\n\nSources:\n" + cited.joined(separator: "\n")
                self?.panel.render(.answer(self?.result ?? text))
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error)
            }
        }
        if task == nil { panel.render(.failed("Set a base URL and chat model in Settings.")) }
    }

    private func run(_ action: AIAction, instruction: String, withContext: Bool) {
        guard let snapshot else { return }
        self.action = action
        self.instruction = instruction
        self.withContext = withContext
        result = ""
        question = nil
        let context = withContext ? aiContext(text: snapshot.text, selection: snapshot.selection) : .none
        let selection = action == .prompt ? "" : context.text
        panel.render(.streaming(""))
        task?.cancel()
        task = feature.perform { [weak self] provider in
            do {
                for try await piece in aiResult(provider: provider, action: action, selection: selection, instruction: instruction, context: context.text) {
                    guard !Task.isCancelled, let self else { return }
                    result += piece
                    let shown = action.tagsOutput ? aiStreamingText(result) : strippingThinkBlock(result)
                    let thinking = strippingThinkBlock(result).drop { $0.isWhitespace }.hasPrefix("<think>")
                    panel.render(.streaming(thinking ? "Thinking…" : shown))
                }
                try Task.checkCancellation()
                self?.finish()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error)
            }
        }
        if task == nil { panel.render(.failed("Set a base URL and chat model in Settings.")) }
    }

    private var output: (kind: AIOutputKind, text: String) {
        let parsed = action.tagsOutput ? aiOutput(result) : (.note, strippingThinkBlock(result))
        return (parsed.kind, parsed.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var finalText: String { output.text }

    private func finish() {
        let output = output
        panel.render(output.text.isEmpty ? .failed("The model returned nothing.") : .done(output.text, output.kind))
    }

    private func fail(_ error: Error) {
        switch error {
        case AIPromptError.tooLong:
            panel.render(.failed("The selection is over \(maxAISelectionLength) characters. Select less."))
        case let AIError.consentRequired(host):
            consentHost = host
            panel.render(.consent(host))
        case let error as AIError:
            panel.render(.failed(error.reason))
        default:
            panel.render(.failed(error.localizedDescription))
        }
    }

    private func allow() {
        guard let consentHost else { return }
        HostConsent().grant(consentHost)
        self.consentHost = nil
        if let question { ask(question) } else { run(action, instruction: instruction, withContext: withContext) }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(question == nil ? finalText : result, forType: .string)
        panel.dismiss()
    }

    private func cancel() {
        task?.cancel()
        task = nil
        snapshot = nil
        consentHost = nil
        question = nil
        panel.dismiss()
    }

    private func accept(below: Bool) {
        guard !finalText.isEmpty, let snapshot, let pid = NotesControl.pid else { return }
        let text = finalText
        panel.dismiss()
        Task {
            NSRunningApplication(processIdentifier: pid)?.activate()
            for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                try? await Task.sleep(for: .milliseconds(50))
            }
            tracker.setSelectedRange(snapshot.selection)
            let decision = insertDecision(
                notesFrontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TextFocusTracker.notesBundleID,
                bodyFocused: tracker.isFocused, current: tracker.buffer(), snapshot: snapshot)
            guard decision == .write else {
                panel.render(.refused(text))
                panel.show(nil, at: caret)
                return
            }
            if below || action == .summarize {
                tracker.setSelectedRange(NSRange(location: NSMaxRange(snapshot.selection), length: 0))
                NotesControl.paste(plain: "\n" + text, to: pid)
            } else {
                NotesControl.paste(plain: text, to: pid)
            }
            self.snapshot = nil
        }
    }
}

/// A non-activating panel that takes keyboard focus while Notes stays the active app.
@MainActor
final class AIPanel: NSPanel, NSTextFieldDelegate {
    enum Phase {
        case input(hasSelection: Bool, chip: String?, canAsk: Bool)
        case streaming(String)
        case done(String, AIOutputKind)
        case answer(String)
        case failed(String)
        case consent(String)
        case refused(String)
    }

    private let field = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let result = NSTextView()
    private let resultScroll = NSScrollView()
    private let actions = NSStackView()
    private let extra = NSButton()
    private let chipLabel = NSTextField(labelWithString: "")
    private lazy var chipRow = NSStackView(views: [chipLabel, button("×", #selector(removeChip))])
    private var chipOn = false
    private var selectionOn = false
    private lazy var askButton = button("Ask my notes", #selector(askNotes))
    private var phase = Phase.input(hasSelection: false, chip: nil, canAsk: false)
    private var dismissing = false
    private let onRun: (AIAction, String, Bool) -> Void
    private let onAsk: (String) -> Void
    private let onAccept: (_ below: Bool) -> Void
    private let onAllow: () -> Void
    private let onCopy: () -> Void
    private let onCancel: () -> Void

    init(run: @escaping (AIAction, String, Bool) -> Void, ask: @escaping (String) -> Void, accept: @escaping (_ below: Bool) -> Void, allow: @escaping () -> Void,
         copy: @escaping () -> Void, cancel: @escaping () -> Void) {
        onRun = run
        onAsk = ask
        onAccept = accept
        onAllow = allow
        onCopy = copy
        onCancel = cancel
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear

        field.delegate = self
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        result.isEditable = false
        result.drawsBackground = false
        result.font = .systemFont(ofSize: NSFont.systemFontSize)
        resultScroll.documentView = result
        resultScroll.hasVerticalScroller = true
        resultScroll.drawsBackground = false
        resultScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        actions.setViews([button("Rewrite", #selector(rewrite)), button("Summarize", #selector(summarize)), askButton], in: .leading)
        extra.bezelStyle = .rounded
        extra.target = self
        extra.action = #selector(extraClicked)

        let stack = NSStackView(views: [field, chipRow, actions, status, resultScroll, extra])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        for view in [field, status, resultScroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
        ])
        contentView = background
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        if !dismissing && isVisible { onCancel() }
    }

    func dismiss() {
        dismissing = true
        orderOut(nil)
        dismissing = false
    }

    /// `caret` is in AppKit coordinates; see `popupFrame`.
    /// A nil `phase` shows the panel again as it is.
    func show(_ phase: Phase?, at caret: CGRect) {
        if let phase { render(phase) }
        if let visible = (NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main)?.visibleFrame {
            setFrameOrigin(popupFrame(anchor: caret, size: frame.size, visible: visible).origin)
        } else {
            setFrameOrigin(NSPoint(x: caret.minX, y: caret.minY - frame.height))
        }
        makeKeyAndOrderFront(nil)
        focus()
    }

    func render(_ phase: Phase) {
        self.phase = phase
        var showsField = false, showsActions = false, text: String?, message = "", extraTitle: String?
        switch phase {
        case let .input(hasSelection, chip, canAsk):
            showsField = true
            chipOn = chip != nil
            selectionOn = hasSelection
            chipLabel.stringValue = chip ?? ""
            field.stringValue = ""
            showsActions = hasSelection || canAsk
            askButton.isHidden = !canAsk
        case let .streaming(shown):
            text = shown
            message = "Writing… Esc to cancel."
        case let .done(shown, kind):
            text = shown
            message = kind == .reply
                ? "Return to copy, ⌥Return to insert below, Esc to close."
                : "Return to insert, ⌥Return to insert below, Esc to discard."
            extraTitle = "Copy"
        case let .answer(shown):
            text = shown
            message = "Return or Copy to copy the answer, Esc to close."
            extraTitle = "Copy"
        case let .failed(reason):
            message = reason + " Esc to close."
        case let .consent(host):
            message = "Send text to \(host)? Return to allow, Esc to cancel."
            extraTitle = "Allow"
        case let .refused(shown):
            text = shown
            message = "The note changed, so nothing was written."
            extraTitle = "Copy"
        }
        let selecting = selectionOn && chipOn
        if case .input = phase {
            for view in actions.views { view.isHidden = !selecting && view !== askButton }
            field.placeholderString = selecting ? "Instruction, or Rewrite / Summarize" : "Ask AI to write something"
            status.stringValue = selecting ? "Return rewrites, following the instruction if given." : "Return to write at the caret."
        }
        chipRow.isHidden = !(showsField && chipOn)
        field.isHidden = !showsField
        actions.isHidden = !showsActions
        if case .input = phase {} else { status.stringValue = message }
        resultScroll.isHidden = text == nil
        result.string = text ?? ""
        extra.isHidden = extraTitle == nil
        extra.title = extraTitle ?? ""
        if isVisible { focus() }
    }

    private func focus() {
        makeFirstResponder(field.isHidden ? nil : field)
    }

    override func keyDown(with event: NSEvent) {
        switch (event.keyCode, phase) {
        case (53, _): onCancel()
        case let (36, .done(_, kind)), let (76, .done(_, kind)):
            if event.modifierFlags.contains(.option) {
                onAccept(true)
            } else if kind == .reply {
                onCopy()
            } else {
                onAccept(false)
            }
        case (36, .answer), (76, .answer): onCopy()
        case (36, .consent), (76, .consent): onAllow()
        default: break
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): submit()
        case #selector(NSResponder.cancelOperation(_:)): onCancel()
        default: return false
        }
        return true
    }

    private func submit() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .input = phase else { return }
        if !(selectionOn && chipOn) {
            if !text.isEmpty { onRun(.prompt, text, chipOn) }
        } else {
            onRun(text.isEmpty ? .rewrite : .instruction, text, true)
        }
    }

    @objc private func removeChip() {
        let typed = field.stringValue
        render(.input(hasSelection: false, chip: nil, canAsk: !askButton.isHidden))
        field.stringValue = typed
    }

    @objc private func rewrite() { onRun(.rewrite, field.stringValue, true) }

    @objc private func askNotes() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onAsk(text) }
    }

    @objc private func summarize() { onRun(.summarize, field.stringValue, true) }

    @objc private func extraClicked() {
        if case .consent = phase { onAllow() } else { onCopy() }
    }
}
