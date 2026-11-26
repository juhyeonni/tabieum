import AppKit
import NotesCore
import SwiftUI

@MainActor
final class AppendPanel {
    private let toggles: FeatureToggles
    lazy var panel: FloatingPanel = {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 72),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.onResign = { [weak self] in self?.close() }
        return panel
    }()

    init(toggles: FeatureToggles) {
        self.toggles = toggles
    }

    private var model: AppendModel?

    /// The append shortcut: a second press while the panel is open opens the Inbox note.
    func press() {
        guard panel.isVisible, let model else { return show() }
        Task {
            guard await model.open() else { return }
            close()
        }
    }

    func show(text: String = "") {
        let model = AppendModel(text: text, title: toggles.inboxTitle, openShortcut: toggles.appendShortcut.display,
                                writer: AppleScriptNotesWriter())
        self.model = model
        panel.contentView = NSHostingView(rootView: AppendView(model: model, close: { [weak self] in self?.close() }))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        panel.orderOut(nil)
    }
}

struct AppendView: View {
    @ObservedObject var model: AppendModel
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Add a line", text: $model.text)
                .textFieldStyle(.plain)
                .font(.title2)
                .padding(12)
                .focused($focused)
                .onSubmit(submit)
                .onKeyPress(.escape) { close(); return .handled }
            Text(model.error ?? model.caption)
                .font(.caption).foregroundStyle(model.error == nil ? Color.secondary : Color.red)
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .frame(width: 640, height: 72, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { focused = true }
    }

    private func submit() {
        Task {
            guard await model.submit() else { return }
            close()
            Toast.show("Added to \(model.title)")
        }
    }
}
