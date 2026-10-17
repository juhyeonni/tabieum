import AppKit
import NotesCore
import SwiftUI

final class EmbeddingState: ObservableObject {
    @Published var progress: EmbeddingProgress?
}

struct AISearchTab: View {
    @ObservedObject var toggles: FeatureToggles
    @ObservedObject var embedding: EmbeddingState
    @ObservedObject var ai: AIFeature
    let setRAG: (Bool) -> Void

    private var model: AISearchModel {
        AISearchModel(aiEnabled: toggles.aiEnabled, ragEnabled: toggles.ragEnabled,
                      mcpEnabled: toggles.mcpEnabled, progress: embedding.progress)
    }

    private var snippet: String {
        AISearchModel.mcpSnippet(executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    }

    var body: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Search index").bold()
                        Text("Always on. Built from your notes on this Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Semantic search (RAG)", isOn: Binding(get: { toggles.ragEnabled }, set: setRAG))
                        Text(model.ragStatus).font(.callout).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("AI assistant", isOn: $toggles.aiEnabled)
                        AITab(toggles: toggles, feature: ai)
                    }
                    VStack(alignment: .leading, spacing: 4) {
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 10) {
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
                .frame(width: 200)
            }
            .padding()
        }
    }
}
