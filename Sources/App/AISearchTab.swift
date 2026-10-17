import AppKit
import NotesCore
import SwiftUI

final class EmbeddingState: ObservableObject {
    @Published var progress: EmbeddingProgress?
}

@MainActor
final class ModelInstall: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case failed(String)
    }

    @Published private(set) var state = State.idle
    private var task: Task<Void, Never>?

    var isInstalled: Bool { E5Embedder.standardStore().isInstalled(.e5Small) }

    func startIfNeeded(then done: @escaping @MainActor () -> Void) {
        guard task == nil, !isInstalled else { return }
        state = .downloading(0)
        task = Task { [weak self] in
            do {
                try await ModelInstaller.install(.e5Small, into: E5Embedder.standardStore()) { fraction in
                    Task { @MainActor in self?.state = .downloading(fraction) }
                }
                self?.state = .idle
                done()
            } catch {
                self?.state = .failed("\(error)")
            }
            self?.task = nil
        }
    }
}

struct AISearchTab: View {
    @ObservedObject var toggles: FeatureToggles
    @ObservedObject var embedding: EmbeddingState
    @ObservedObject var install: ModelInstall
    let setRAG: (Bool) -> Void
    let chooseModel: (EmbeddingModel) -> Void
    let retryInstall: () -> Void

    private var model: AISearchModel {
        AISearchModel(aiEnabled: toggles.aiEnabled, ragEnabled: toggles.ragEnabled,
                      mcpEnabled: toggles.mcpEnabled, progress: embedding.progress)
    }

    private static let downloadSize = ByteCountFormatter.string(fromByteCount: ModelSource.e5Small.downloadSize, countStyle: .file)

    @ViewBuilder private var modelStatus: some View {
        if toggles.embeddingModel == .e5Small {
            switch install.state {
            case .downloading(let fraction):
                ProgressView(value: fraction) { Text("Downloading the model…").font(.callout) }
            case .failed(let message):
                Text("Download failed: \(message)").font(.callout).foregroundStyle(.red)
                Button("Try Again", action: retryInstall)
            case .idle:
                Text(install.isInstalled ? "Installed. Runs on this Mac's Neural Engine; unloads after a minute without use."
                                         : "Not installed yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var snippet: String {
        AISearchModel.mcpSnippet(executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    }

    var body: some View {
        SettingsPage {
            Card {
                Text("Search index").bold()
                Text("Always on. Built from your notes on this Mac.").font(.callout).foregroundStyle(.secondary)
            }
            Card {
                Toggle("Semantic search (RAG)", isOn: Binding(get: { toggles.ragEnabled }, set: setRAG))
                Text(model.ragStatus).font(.callout).foregroundStyle(.secondary)
                Picker("Embedding model", selection: Binding(get: { toggles.embeddingModel }, set: chooseModel)) {
                    Text("Apple (built in)").tag(EmbeddingModel.apple)
                    Text("tabieum-e5-small-coreml (\(Self.downloadSize) download)").tag(EmbeddingModel.e5Small)
                }
                modelStatus
            }
            Card {
                Toggle("AI agents (MCP)", isOn: $toggles.mcpEnabled)
                ScrollView(.horizontal) {
                    Text(snippet).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.bottom, 8)
                }
                Button("Copy config") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                }
            }
            Card {
                Text("What works with the current switches").bold()
                ForEach(model.rows, id: \.feature) { row in
                    HStack(alignment: .top) {
                        Image(systemName: row.works ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(row.works ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(row.feature)
                            Text(row.note).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
