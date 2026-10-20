import AppKit
import NotesCore
import SwiftUI

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = "" { didSet { run() } }
    @Published private(set) var hits: [PanelHit] = []
    /// True while the search by meaning is still running behind the word-search hits already listed.
    @Published private(set) var refining = false
    @Published var selection = 0
    private let indexURL: URL
    private let embedder: @MainActor () -> Embedder?
    private var generation = 0

    init(indexURL: URL, embedder: @escaping @MainActor () -> Embedder?) {
        self.indexURL = indexURL
        self.embedder = embedder
    }

    func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        selection = min(max(selection + delta, 0), hits.count - 1)
    }

    private func run() {
        generation += 1
        let current = generation, text = query, url = indexURL, embedder = embedder()
        guard !text.allSatisfy(\.isWhitespace) else {
            hits = []
            refining = false
            return
        }
        refining = embedder != nil
        Task.detached {
            // Word search answers at once; the search by meaning can wait for the model to load.
            let quick = (try? SearchIndex(url: url, readOnly: true).panelSearch(text, embedder: nil, limit: 50)) ?? []
            await MainActor.run {
                guard current == self.generation else { return }
                self.hits = quick
                self.selection = 0
            }
            guard let embedder else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard await MainActor.run(body: { current == self.generation }) else { return }
            let full = (try? SearchIndex(url: url, readOnly: true).panelSearch(text, embedder: embedder, limit: 50)) ?? []
            await MainActor.run {
                guard current == self.generation else { return }
                self.hits = full
                self.selection = min(self.selection, max(full.count - 1, 0))
                self.refining = false
            }
        }
    }
}

final class FloatingPanel: NSPanel {
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
    private let embedder: @MainActor () -> Embedder?
    lazy var panel: FloatingPanel = {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.onResign = { [weak self] in self?.close() }
        return panel
    }()

    init(indexURL: URL, embedder: @escaping @MainActor () -> Embedder?) {
        self.indexURL = indexURL
        self.embedder = embedder
    }

    func show() {
        warmUp()
        let model = SearchModel(indexURL: indexURL, embedder: embedder)
        panel.contentView = NSHostingView(rootView: SearchView(model: model, open: { [weak self] in self?.open($0) },
                                                               close: { [weak self] in self?.close() }))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        panel.orderOut(nil)
    }

    /// Loads the model while the panel opens, so the first search by meaning does not wait for it.
    private func warmUp() {
        guard let embedder = embedder(), let id = embedder.modelID(for: "warm"), embedder.isReady(id) else { return }
        Task.detached { _ = try? embedder.embed("warm", modelID: id, kind: .query) }
    }

    private func open(_ hit: SearchResult) {
        close()
        NSWorkspace.shared.open(NoteLink(identifier: hit.id, ownerIdentifier: hit.ownerIdentifier).url)
    }
}

struct SearchView: View {
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
                .overlay(alignment: .trailing) {
                    if model.refining { ProgressView().controlSize(.small).padding(.trailing, 14) }
                }
                .focused($focused)
                .onSubmit(openSelected)
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.hits.enumerated()), id: \.element.note.id) { index, hit in
                            row(hit, selected: index == model.selection)
                                .onTapGesture(count: 2) { open(hit.note) }
                                .onTapGesture { model.selection = index }
                        }
                    }
                }
                .onChange(of: model.selection) { _, new in
                    if model.hits.indices.contains(new) { proxy.scrollTo(model.hits[new].note.id) }
                }
            }
        }
        .frame(width: 640, height: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { focused = true }
    }

    private func openSelected() {
        guard model.hits.indices.contains(model.selection) else { return }
        open(model.hits[model.selection].note)
    }

    private func row(_ hit: PanelHit, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(hit.note.title.isEmpty ? "Untitled" : hit.note.title).bold().lineLimit(1)
                if hit.byMeaningOnly {
                    Text("Similar in meaning").font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).background(.quaternary, in: Capsule())
                }
                Spacer()
                Text("\(hit.note.folder) · \(hit.note.modified.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(hit.note.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear)
        .contentShape(Rectangle())
    }
}
