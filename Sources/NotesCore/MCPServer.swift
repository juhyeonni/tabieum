import Foundation
import SQLite3

/// A read-only MCP server (newline-delimited JSON-RPC 2.0 over stdio) over the app's own search index.
public struct MCPServer: Sendable {
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    /// Tool names live here; the owner settles the final ones later.
    enum Tool: String, CaseIterable {
        case searchNotes = "search_notes"
        case getNote = "get_note"

        var description: String {
            switch self {
            case .searchNotes: "Search the user's notes. Returns the best matches with a snippet."
            case .getNote: "Read one note as Markdown by its id."
            }
        }

        var schema: [String: Any] {
            switch self {
            case .searchNotes:
                ["type": "object", "required": ["query"], "properties": [
                    "query": ["type": "string"],
                    "k": ["type": "integer", "minimum": 1, "maximum": 50, "default": 10]]]
            case .getNote:
                ["type": "object", "required": ["id"], "properties": ["id": ["type": "string"]]]
            }
        }
    }

    private struct ToolFailure: Error { let message: String }

    let serverName: String
    let version: String
    let indexURL: URL
    let isEnabled: @Sendable () -> Bool
    let ragEnabled: @Sendable () -> Bool
    let makeEmbedder: @Sendable () -> Embedder

    public init(
        serverName: String, version: String, indexURL: URL,
        isEnabled: @escaping @Sendable () -> Bool,
        ragEnabled: @escaping @Sendable () -> Bool = { false },
        makeEmbedder: @escaping @Sendable () -> Embedder = { AppleEmbedder() }
    ) {
        self.serverName = serverName
        self.version = version
        self.indexURL = indexURL
        self.isEnabled = isEnabled
        self.ragEnabled = ragEnabled
        self.makeEmbedder = makeEmbedder
    }

    /// Serves stdin until it closes. Only protocol messages go to stdout.
    public func runStdio() {
        while let line = readLine() {
            guard let reply = handle(line) else { continue }
            print(reply)
            fflush(stdout)
        }
    }

    /// The reply to one message, or nil for a notification.
    public func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else {
            return error(nil, -32700, "Parse error")
        }
        guard let message = json as? [String: Any], let method = message["method"] as? String else {
            return error(nil, -32600, "Invalid Request")
        }
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize": return result(id, initialize(params))
        case "ping": return result(id, [:])
        case "tools/list": return result(id, ["tools": Tool.allCases.map {
            ["name": $0.rawValue, "description": $0.description, "inputSchema": $0.schema] as [String: Any]
        }])
        case "tools/call": return result(id, call(params))
        default: return error(id, -32601, "Method not found")
        }
    }

    private func initialize(_ params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String ?? ""
        return [
            "protocolVersion": Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0],
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": serverName, "version": version],
        ]
    }

    private func call(_ params: [String: Any]) -> [String: Any] {
        do {
            guard let name = params["name"] as? String, let tool = Tool(rawValue: name) else {
                throw ToolFailure(message: "Unknown tool.")
            }
            guard isEnabled() else {
                throw ToolFailure(message: "The \"AI agents (MCP)\" option is off. Turn it on in \(serverName) Settings.")
            }
            let index = try openIndex()
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let output: Any
            switch tool {
            case .searchNotes: output = try search(index, arguments)
            case .getNote: output = try getNote(index, arguments)
            }
            return content(output, isError: false)
        } catch let failure as ToolFailure {
            return content(failure.message, isError: true)
        } catch {
            return content("\(error)", isError: true)
        }
    }

    private func openIndex() throws -> SearchIndex {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            throw ToolFailure(message: "No search index yet. Open \(serverName) and let it sync your notes first.")
        }
        return try SearchIndex(url: indexURL, readOnly: true)
    }

    private func search(_ index: SearchIndex, _ arguments: [String: Any]) throws -> [[String: Any]] {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            throw ToolFailure(message: "query must be a non-empty string.")
        }
        let k = min(max((arguments["k"] as? NSNumber)?.intValue ?? 10, 1), 50)
        if ragEnabled(), try index.chunkCount() > 0 {
            return try index.hybridSearch(query, embedder: makeEmbedder(), limit: k).map {
                var hit = Self.fields($0.note)
                hit["chunk"] = $0.chunkText
                hit["heading_path"] = $0.headingPath
                return hit
            }
        }
        return try index.search(query, limit: k).map(Self.fields)
    }

    private func getNote(_ index: SearchIndex, _ arguments: [String: Any]) throws -> [String: Any] {
        guard let id = arguments["id"] as? String, let (note, markdown) = try index.note(id) else {
            throw ToolFailure(message: "No note with that id.")
        }
        var fields = Self.fields(note)
        fields["markdown"] = markdown
        fields["snippet"] = nil
        return fields
    }

    private static func fields(_ note: SearchResult) -> [String: Any] {
        ["id": note.id, "title": note.title, "folder": note.folder,
         "modified": ISO8601DateFormatter().string(from: note.modified), "snippet": note.snippet]
    }

    private func content(_ output: Any, isError: Bool) -> [String: Any] {
        let text = output as? String ?? Self.json(output)
        return ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private func result(_ id: Any, _ result: [String: Any]) -> String {
        Self.json(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func error(_ id: Any?, _ code: Int, _ message: String) -> String {
        Self.json(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private static func json(_ value: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}

extension SearchIndex {
    func note(_ id: String) throws -> (SearchResult, markdown: String)? {
        try db.rows("""
            SELECT n.id, f.title, f.folder, n.modified, f.body FROM notes n JOIN notes_fts f ON f.rowid = n.rowid WHERE n.id = ?1
            """, [.text(id)]) {
            (SearchResult(id: SQLiteConnection.text($0, 0), title: SQLiteConnection.text($0, 1),
                          folder: SQLiteConnection.text($0, 2),
                          modified: Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0, 3)), snippet: "",
                          ownerIdentifier: nil),
             SQLiteConnection.text($0, 4))
        }.first
    }
}
