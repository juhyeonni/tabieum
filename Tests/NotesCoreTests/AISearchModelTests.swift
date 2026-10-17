import Testing
@testable import NotesCore

private func model(ai: Bool = false, rag: Bool = false, mcp: Bool = false, progress: EmbeddingProgress? = nil) -> AISearchModel {
    AISearchModel(aiEnabled: ai, ragEnabled: rag, mcpEnabled: mcp, progress: progress)
}

@Test func featureRowsAreListedInOrder() {
    #expect(model().rows.map(\.feature) == ["Search panel", "Ask my notes", "AI writing helper", "MCP tools"])
}

@Test func askNotesNeedsAIAndRAG() {
    #expect(model(ai: true, rag: true).rows[1].works)
    let noRAG = model(ai: true).rows[1]
    #expect(!noRAG.works && noRAG.note.contains("RAG") && !noRAG.note.contains("AI assistant"))
    let noAI = model(rag: true).rows[1]
    #expect(!noAI.works && noAI.note.contains("AI assistant") && !noAI.note.contains("RAG"))
    let neither = model().rows[1]
    #expect(!neither.works && neither.note.contains("AI assistant") && neither.note.contains("RAG"))
}

@Test func writingHelperAndMCPFollowTheirOwnSwitch() {
    #expect(model(ai: true).rows[2].works)
    #expect(!model().rows[2].works && model().rows[2].note.contains("AI assistant"))
    #expect(model(mcp: true).rows[3].works)
    #expect(!model().rows[3].works && model().rows[3].note.contains("MCP"))
}

@Test func mcpRowSaysHowSearchNotesSearches() {
    #expect(model(rag: true, mcp: true).rows[3].note.contains("search_notes uses keyword and semantic search"))
    #expect(model(mcp: true).rows[3].note.contains("search_notes uses keywords only"))
}

@Test func ragStatusLine() {
    #expect(model(progress: EmbeddingProgress(done: 1, total: 2, waitingForModel: false)).ragStatus == "Off")
    #expect(model(rag: true, progress: EmbeddingProgress(done: 0, total: 5, waitingForModel: true)).ragStatus == "Waiting for the model")
    #expect(model(rag: true, progress: EmbeddingProgress(done: 3, total: 8, waitingForModel: false)).ragStatus == "Embedding 3 / 8")
    #expect(model(rag: true).ragStatus == "Ready")
}

@Test func mcpSnippetHasPathAndArgument() {
    let snippet = AISearchModel.mcpSnippet(executablePath: "/Applications/NoteKit.app/Contents/MacOS/NoteKit")
    #expect(snippet.contains("\"/Applications/NoteKit.app/Contents/MacOS/NoteKit\""))
    #expect(snippet.contains("\"--mcp\""))
}
