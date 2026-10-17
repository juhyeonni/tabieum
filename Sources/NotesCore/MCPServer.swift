import Foundation
import SQLite3

/// An MCP server (newline-delimited JSON-RPC 2.0 over stdio) over the app's own search index. It reads on its own;
/// the one write tool hands its request to the running app, which applies the owner's settings and consent.
public struct MCPServer: Sendable {
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    /// Tool names live here; the owner settles the final ones later.
    enum Tool: String, CaseIterable {
        case searchNotes = "search_notes"
        case getNote = "get_note"
        case listBacklinks = "list_backlinks"
        case createNote = "create_note"
        case updateNote = "update_note"
        case deleteNote = "delete_note"

        var description: String {
            switch self {
            case .searchNotes: "Search the user's notes. Returns the best matches with a snippet."
            case .getNote: "Read one note as Markdown by its id."
            case .listBacklinks: "List the notes that link to one note, by its id."
            case .createNote: "Create a note from a Markdown body. Notes uses the first line as the note's title, so start the body with a heading. It goes into the folder the owner chose and may need the owner's approval in the app."
            case .deleteNote: "Move a note to Recently Deleted, where the owner can restore it. It may need the owner's approval in the app."
            case .updateNote: "Replace the whole body of an existing note with Markdown. Read the note with get_note first and pass its modified value as expected_modified; the edit is refused if the note changed since. It may need the owner's approval in the app."
            }
        }

        var schema: [String: Any] {
            switch self {
            case .searchNotes:
                ["type": "object", "required": ["query"], "properties": [
                    "query": ["type": "string"],
                    "k": ["type": "integer", "minimum": 1, "maximum": 50, "default": 10]]]
            case .getNote, .listBacklinks, .deleteNote:
                ["type": "object", "required": ["id"], "properties": ["id": ["type": "string"]]]
            case .createNote:
                ["type": "object", "required": ["body"], "properties": [
                    "title": ["type": "string", "description": "Optional. Put in front of the body as a heading; leave it out when the body starts with its own title."],
                    "body": ["type": "string", "description": "Markdown: headings, lists, bold, italic and inline code."]]]
            case .updateNote:
                ["type": "object", "required": ["id", "body", "expected_modified"], "properties": [
                    "id": ["type": "string"],
                    "body": ["type": "string", "description": "The new whole body as Markdown. Its first line becomes the note's title."],
                    "expected_modified": ["type": "string", "description": "The modified value get_note returned for this note."]]]
            }
        }

        var annotations: [String: Any]? {
            switch self {
            case .createNote: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false]
            case .updateNote, .deleteNote: ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false]
            default: nil
            }
        }

        /// The write action a tool performs, nil for the read tools.
        var writeAction: WriteAction? {
            switch self {
            case .createNote: .create
            case .updateNote: .edit
            case .deleteNote: .delete
            default: nil
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
    let writeSettings: @Sendable () -> WriteSettings
    let writeChannel: WriteChannel?

    public init(
        serverName: String, version: String, indexURL: URL,
        isEnabled: @escaping @Sendable () -> Bool,
        ragEnabled: @escaping @Sendable () -> Bool = { false },
        makeEmbedder: @escaping @Sendable () -> Embedder = { ConfiguredEmbedder() },
        writeSettings: @escaping @Sendable () -> WriteSettings = { WriteSettings() },
        writeChannel: WriteChannel? = nil
    ) {
        self.serverName = serverName
        self.version = version
        self.indexURL = indexURL
        self.isEnabled = isEnabled
        self.ragEnabled = ragEnabled
        self.makeEmbedder = makeEmbedder
        self.writeSettings = writeSettings
        self.writeChannel = writeChannel
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
        case "tools/list": return result(id, ["tools": Tool.allCases.filter { refusal(for: $0) == nil }.map { tool in
            var entry: [String: Any] = ["name": tool.rawValue, "description": tool.description, "inputSchema": tool.schema]
            entry["annotations"] = tool.annotations
            return entry
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
            if let refusal = refusal(for: tool) { throw ToolFailure(message: refusal) }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let output: Any
            switch tool {
            case .searchNotes: output = try search(openIndex(), arguments)
            case .getNote: output = try getNote(openIndex(), arguments)
            case .listBacklinks: output = try listBacklinks(openIndex(), arguments)
            case .createNote: output = try createNote(arguments)
            case .updateNote: output = try updateNote(arguments)
            case .deleteNote: output = try deleteNote(arguments)
            }
            return content(output, isError: false)
        } catch let failure as ToolFailure {
            return content(failure.message, isError: true)
        } catch {
            return content("\(error)", isError: true)
        }
    }

    /// Why a tool is unavailable, or nil. The read tools are always listed.
    private func refusal(for tool: Tool) -> String? {
        guard let action = tool.writeAction else { return nil }
        guard isEnabled() else { return "The \"AI agents (MCP)\" option is off. Turn it on in \(serverName) Settings." }
        let settings = writeSettings()
        guard settings.enabled else { return "Writing to Notes is off. Turn it on in \(serverName) Settings." }
        guard settings.allowedActions.contains(action) else { return "\(action.rawValue.capitalized) is not allowed in \(serverName) Settings." }
        guard settings.consent != .never else { return "Writing to Notes is set to never allow in \(serverName) Settings." }
        guard writeChannel != nil else { return "This server cannot reach \(serverName)." }
        return nil
    }

    private func createNote(_ arguments: [String: Any]) throws -> String {
        var title: String?
        if let given = arguments["title"] {
            guard let text = given as? String else { throw ToolFailure(message: "title must be a string.") }
            title = text.isEmpty ? nil : text
        }
        guard let body = arguments["body"] as? String else { throw ToolFailure(message: "body must be a string.") }
        guard title != nil || !body.allSatisfy(\.isWhitespace) else {
            throw ToolFailure(message: "body must not be empty when there is no title.")
        }
        var request: [String: Any] = ["action": "create", "html": NoteHTML.html(fromMarkdown: body)]
        request["title"] = title
        return try askApp(request, success: "Created the note in the target folder.")
    }

    private func updateNote(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments["id"] as? String, !id.isEmpty else { throw ToolFailure(message: "id must be a non-empty string.") }
        guard let body = arguments["body"] as? String else { throw ToolFailure(message: "body must be a string.") }
        guard let expected = arguments["expected_modified"] as? String, ISO8601DateFormatter().date(from: expected) != nil else {
            throw ToolFailure(message: "expected_modified must be the ISO 8601 modified value get_note returned.")
        }
        return try askApp(["action": "edit", "id": id, "html": NoteHTML.html(fromMarkdown: body), "expected_modified": expected],
                          success: "Replaced the body of the note.")
    }

    private func deleteNote(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments["id"] as? String, !id.isEmpty else { throw ToolFailure(message: "id must be a non-empty string.") }
        return try askApp(["action": "delete", "id": id], success: "Moved the note to Recently Deleted.")
    }

    /// Sends one request to the running app and turns its reply into the tool's result or error.
    private func askApp(_ request: [String: Any], success: String) throws -> String {
        guard let writeChannel else { throw ToolFailure(message: "This server cannot reach \(serverName).") }
        let reply: String
        do {
            reply = try writeChannel.send(Self.json(request))
        } catch WriteChannelError.noAnswer {
            throw ToolFailure(message: "\(serverName) did not answer in time. The change may not have been made.")
        } catch {
            throw ToolFailure(message: "\(serverName) is not running. Open it, then try again.")
        }
        guard let data = reply.data(using: .utf8), let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolFailure(message: "\(serverName) sent an answer that could not be read.")
        }
        guard answer["ok"] as? Bool == true else {
            throw ToolFailure(message: answer["error"] as? String ?? "\(serverName) refused the request.")
        }
        return success
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

    private func listBacklinks(_ index: SearchIndex, _ arguments: [String: Any]) throws -> [[String: Any]] {
        guard let id = arguments["id"] as? String, try index.note(id) != nil else {
            throw ToolFailure(message: "No note with that id.")
        }
        return try index.backlinks(to: id).map { ["id": $0.id, "title": $0.title, "folder": $0.folder] }
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
