import Foundation
import Testing
@testable import NotesCore

private final class CarEmbedder: Embedder, @unchecked Sendable {
    func modelID(for text: String) -> String? { "stub" }
    func isReady(_ modelID: String) -> Bool { true }
    func embed(_ text: String, modelID: String) throws -> [Float] {
        text.contains("car") || text.contains("automobile") ? [1, 0] : [0, 1]
    }
}

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite")
}

private func fixtureIndex(vectors: Bool = false) throws -> URL {
    let url = tempURL()
    let index = try SearchIndex(url: url)
    let modified = Date(timeIntervalSinceReferenceDate: 100)
    try index.upsert((1...60).map {
        IndexedNote(id: "n\($0)", title: "Apple note \($0)", folder: "Work", modified: modified, body: "apple body \($0)", owner: "")
    } + [IndexedNote(id: "car", title: "Garage", folder: "Home", modified: modified, body: "my automobile", owner: "")])
    if vectors {
        let chunk = Chunk(noteID: "car", path: "Garage", position: 0, modified: modified, text: "my automobile")
        try index.replaceChunks(noteID: "car", with: [StoredChunk(chunk: chunk, model: "stub", vector: [1, 0])])
    }
    return url
}

private func server(_ url: URL, enabled: Bool = true, rag: Bool = false) -> MCPServer {
    MCPServer(serverName: "NoteKit", version: "0", indexURL: url, isEnabled: { enabled }, ragEnabled: { rag },
              makeEmbedder: { CarEmbedder() })
}

private func reply(_ server: MCPServer, _ line: String) throws -> [String: Any] {
    let text = try #require(server.handle(line))
    return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func callTool(_ server: MCPServer, _ name: String, _ arguments: String) throws -> (isError: Bool, text: String) {
    let message = try reply(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#)
    let result = try #require(message["result"] as? [String: Any])
    let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
    return (result["isError"] as? Bool ?? false, text)
}

private func hits(_ text: String) throws -> [[String: Any]] {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
}

private func errorCode(_ message: [String: Any]) -> Int? {
    (message["error"] as? [String: Any])?["code"] as? Int
}

@Suite struct MCPServerTests {
    @Test func initializeAnswersWithSupportedVersion() throws {
        let s = server(tempURL())
        for (asked, got) in [("2025-11-25", "2025-11-25"), ("2025-06-18", "2025-06-18"), ("1999-01-01", "2025-11-25")] {
            let message = try reply(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(asked)"}}"#)
            let result = try #require(message["result"] as? [String: Any])
            #expect(result["protocolVersion"] as? String == got)
            #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
            #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "NoteKit")
        }
    }

    @Test func toolsListHasInputSchemas() throws {
        let message = try reply(server(tempURL()), #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let tools = try #require((message["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["search_notes", "get_note"])
        #expect(tools.allSatisfy { $0["inputSchema"] != nil })
    }

    @Test func searchReturnsFieldsAndClampsK() throws {
        let s = server(try fixtureIndex())
        let few = try callTool(s, "search_notes", #"{"query":"apple","k":3}"#)
        let rows = try hits(few.text)
        #expect(!few.isError && rows.count == 3)
        #expect(Set(rows[0].keys) == ["id", "title", "folder", "modified", "snippet"])
        #expect(rows[0]["modified"] as? String == "2001-01-01T00:01:40Z")
        #expect(try hits(callTool(s, "search_notes", #"{"query":"apple","k":500}"#).text).count == 50)
        #expect(try hits(callTool(s, "search_notes", #"{"query":"apple"}"#).text).count == 10)
    }

    @Test func ragOnWithVectorsUsesHybrid() throws {
        let url = try fixtureIndex(vectors: true)
        let query = #"{"query":"car"}"#
        #expect(try hits(callTool(server(url, rag: false), "search_notes", query).text).isEmpty)
        let on = try hits(callTool(server(url, rag: true), "search_notes", query).text)
        #expect(on.first?["id"] as? String == "car")
        #expect(on.first?["heading_path"] as? String == "Garage")
        #expect(on.first?["chunk"] as? String == "my automobile")
    }

    @Test func getNoteReturnsMarkdownOrError() throws {
        let s = server(try fixtureIndex())
        let found = try callTool(s, "get_note", #"{"id":"car"}"#)
        let note = try #require(JSONSerialization.jsonObject(with: Data(found.text.utf8)) as? [String: Any])
        #expect(!found.isError && note["markdown"] as? String == "my automobile" && note["title"] as? String == "Garage")
        #expect(try callTool(s, "get_note", #"{"id":"nope"}"#).isError)
    }

    @Test func protocolErrorsAndNotifications() throws {
        let s = server(tempURL())
        #expect(errorCode(try reply(s, #"{"jsonrpc":"2.0","id":1,"method":"server/discover"}"#)) == -32601)
        #expect(errorCode(try reply(s, "{nope")) == -32700)
        #expect(s.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(try reply(s, #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)["id"] as? Int == 7)
    }

    @Test func missingIndexAndOptionOffReturnToolErrors() throws {
        let missing = try callTool(server(tempURL()), "search_notes", #"{"query":"a"}"#)
        #expect(missing.isError && missing.text.contains("sync"))
        let off = try callTool(server(try fixtureIndex(), enabled: false), "search_notes", #"{"query":"apple"}"#)
        #expect(off.isError && off.text.contains("AI agents (MCP)"))
    }

    @Test func readOnlyConnectionRejectsWrites() throws {
        let index = try SearchIndex(url: try fixtureIndex(), readOnly: true)
        #expect(throws: SQLiteError.self) { try index.db.run("DELETE FROM notes") }
    }
}
