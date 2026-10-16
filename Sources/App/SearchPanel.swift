import AppKit
import NotesCore
import SwiftUI

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = "" { didSet { run() } }
    @Published private(set) var hits: [SearchResult] = []
    @Published var selection = 0
    private let indexURL: URL
    private var generation = 0

    init(indexURL: URL) {
        self.indexURL = indexURL
    }

    func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        selection = min(max(selection + delta, 0), hits.count - 1)
    }

    private func run() {
        generation += 1
        let current = generation, text = query, url = indexURL
        guard !text.allSatisfy(\.isWhitespace) else {
            hits = []
            return
        }
        Task.detached {
            let found = (try? SearchIndex(url: url, readOnly: true).search(text, limit: 50)) ?? []
            await MainActor.run {
                guard current == self.generation else { return }
                self.hits = found
                self.selection = 0
            }
        }
    }
}

private final class FloatingPanel: NSPanel {
    var onResign: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResign()
    }
}

@MainActor
final class SearchPanel {
    private let indexURL: URL
    private lazy var panel: FloatingPanel = {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                                  styleMask: [.borderless], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.onResign = { [weak self] in self?.close() }
        return panel
    }()

    init(indexURL: URL) {
        self.indexURL = indexURL
    }

    func show() {
        let model = SearchModel(indexURL: indexURL)
        panel.contentView = NSHostingView(rootView: SearchView(model: model, open: { [weak self] in self?.open($0) },
                                                               close: { [weak self] in self?.close() }))
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        panel.orderOut(nil)
    }

    private func open(_ hit: SearchResult) {
        close()
        NSWorkspace.shared.open(NoteLink(identifier: hit.id, ownerIdentifier: hit.ownerIdentifier).url)
    }
}

private struct SearchView: View {
    @ObservedObject var model: SearchModel
    let open: (SearchResult) -> Void
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search notes", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title2)
                .padding(12)
                .focused($focused)
                .onSubmit(openSelected)
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
                            row(hit, selected: index == model.selection)
                                .id(index)
                                .onTapGesture(count: 2) { open(hit) }
                                .onTapGesture { model.selection = index }
                        }
                    }
                }
                .onChange(of: model.selection) { _, new in proxy.scrollTo(new) }
            }
        }
        .frame(width: 640, height: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { focused = true }
    }

    private func openSelected() {
        guard model.hits.indices.contains(model.selection) else { return }
        open(model.hits[model.selection])
    }

    private func row(_ hit: SearchResult, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(hit.title.isEmpty ? "Untitled" : hit.title).bold().lineLimit(1)
                Spacer()
                Text("\(hit.folder) · \(hit.modified.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(hit.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear)
        .contentShape(Rectangle())
    }
}
