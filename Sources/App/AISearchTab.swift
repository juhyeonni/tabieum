import AppKit
import NotesCore
import SwiftUI

final class EmbeddingState: ObservableObject {
    @Published var progress: EmbeddingProgress?
}

struct AISearchTab: View {
    @ObservedObject var toggles: FeatureToggles
    @ObservedObject var embedding: EmbeddingState
    let setRAG: (Bool) -> Void

    private var model: AISearchModel {
        AISearchModel(aiEnabled: toggles.aiEnabled, ragEnabled: toggles.ragEnabled,
                      mcpEnabled: toggles.mcpEnabled, progress: embedding.progress)
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
            WriteSettingsCard(toggles: toggles)
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
