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
    /// True while the name field for saving the current query is open.
    @Published var naming = false
    @Published var name = ""
    private let toggles: FeatureToggles
    private let indexURL: URL
    private let embedder: @MainActor () -> Embedder?
    private var generation = 0

    init(toggles: FeatureToggles, indexURL: URL, embedder: @escaping @MainActor () -> Embedder?) {
        self.toggles = toggles
        self.indexURL = indexURL
        self.embedder = embedder
    }

    /// The saved searches, shown while the field is empty.
    var saved: [SavedSearch] { query.isEmpty ? toggles.savedSearches : [] }

    func move(_ delta: Int) {
        let count = saved.isEmpty ? hits.count : saved.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    /// Runs the selected saved search by putting its query in the field.
    func runSaved() {
        guard saved.indices.contains(selection) else { return }
        query = saved[selection].query
    }

    func deleteSaved() {
        guard saved.indices.contains(selection) else { return }
        toggles.savedSearches.remove(at: selection)
        selection = min(selection, max(toggles.savedSearches.count - 1, 0))
        objectWillChange.send()
    }

    func startNaming() {
        guard !query.allSatisfy(\.isWhitespace) else { return }
        name = ""
        naming = true
    }

    func saveNamed() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        naming = false
        guard !trimmed.isEmpty else { return }
        toggles.savedSearches.save(SavedSearch(name: trimmed, query: query))
    }

    private func run() {
        generation += 1
        naming = false
        let current = generation, text = query, url = indexURL, embedder = embedder()
        guard !text.allSatisfy(\.isWhitespace) else {
            hits = []
            selection = 0
            refining = false
            return
        }
        refining = embedder != nil
        Task.detached {
            // Word search answers at once; the search by meaning can wait for the model to load.
            let quick = (try? SearchIndex(url: url, readOnly: true).conditionalPanelSearch(text, embedder: nil)) ?? []
            await MainActor.run {
                guard current == self.generation else { return }
                self.hits = quick
                self.selection = 0
            }
            guard let embedder else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard await MainActor.run(body: { current == self.generation }) else { return }
            let full = (try? SearchIndex(url: url, readOnly: true).conditionalPanelSearch(text, embedder: embedder)) ?? []
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
    private let toggles: FeatureToggles
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

    init(toggles: FeatureToggles, indexURL: URL, embedder: @escaping @MainActor () -> Embedder?) {
        self.toggles = toggles
        self.indexURL = indexURL
        self.embedder = embedder
    }

    func show() {
        warmUp()
        let model = SearchModel(toggles: toggles, indexURL: indexURL, embedder: embedder)
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
    @FocusState private var nameFocused: Bool

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
                .onSubmit(submit)
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
            if model.naming {
                TextField("Name this search, then press Return", text: $model.name)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .focused($nameFocused)
                    .onSubmit { model.saveNamed(); focused = true }
                    .onKeyPress(.escape) { model.naming = false; focused = true; return .handled }
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.saved.enumerated()), id: \.element.name) { index, search in
                            savedRow(search, selected: index == model.selection)
                                .onTapGesture(count: 2) { model.selection = index; model.runSaved() }
                                .onTapGesture { model.selection = index }
                        }
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
        .background {
            Button("") { model.startNaming() }.keyboardShortcut("s", modifiers: .command)
            Button("") { model.deleteSaved() }.keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.saved.isEmpty)
        }
        .onChange(of: model.naming) { _, naming in if naming { nameFocused = true } }
        .frame(width: 640, height: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { focused = true }
    }

    private func submit() {
        guard model.saved.isEmpty else { return model.runSaved() }
        openSelected()
    }

    private func openSelected() {
        guard model.hits.indices.contains(model.selection) else { return }
        open(model.hits[model.selection].note)
    }

    private func savedRow(_ search: SavedSearch, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(search.name).bold().lineLimit(1)
            Text(search.query).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear)
        .contentShape(Rectangle())
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
