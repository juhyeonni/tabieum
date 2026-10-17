import Foundation

public struct AISearchModel: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let feature: String
        public let works: Bool
        public let note: String
    }

    public var aiEnabled: Bool
    public var ragEnabled: Bool
    public var mcpEnabled: Bool
    public var progress: EmbeddingProgress?

    public init(aiEnabled: Bool, ragEnabled: Bool, mcpEnabled: Bool, progress: EmbeddingProgress? = nil) {
        self.aiEnabled = aiEnabled
        self.ragEnabled = ragEnabled
        self.mcpEnabled = mcpEnabled
        self.progress = progress
    }

    public var rows: [Row] {
        [
            Row(feature: "Search panel", works: true,
                note: ragEnabled ? "Keyword and semantic search." : "Keyword search."),
            askNotes,
            Row(feature: "AI writing helper", works: aiEnabled,
                note: aiEnabled ? "Ready." : "Turn on AI assistant."),
            Row(feature: "MCP tools", works: mcpEnabled,
                note: (mcpEnabled ? "" : "Turn on AI agents (MCP). ")
                    + "search_notes uses " + (ragEnabled ? "keyword and semantic search." : "keywords only.")),
        ]
    }

    private var askNotes: Row {
        let missing = (aiEnabled ? [] : ["AI assistant"]) + (ragEnabled ? [] : ["semantic search (RAG)"])
        guard !missing.isEmpty else { return Row(feature: "Ask my notes", works: true, note: "Ready.") }
        return Row(feature: "Ask my notes", works: false, note: "Turn on " + missing.joined(separator: " and ") + ".")
    }

    public var ragStatus: String {
        guard ragEnabled else { return "Off" }
        guard let progress else { return "Ready" }
        return progress.waitingForModel ? "Waiting for the model" : "Embedding \(progress.done) / \(progress.total)"
    }

    public static func mcpSnippet(executablePath: String) -> String {
        let config: [String: Any] = ["mcpServers": ["tabieum": ["command": executablePath, "args": ["--mcp"]]]]
        let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
