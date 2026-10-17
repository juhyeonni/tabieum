import Foundation
import Testing
@testable import NotesCore

private func mcp(_ value: WriteSettings, channel: WriteChannel?, enabled: Bool = true) -> MCPServer {
    MCPServer(serverName: "tabieum", version: "0", indexURL: URL(fileURLWithPath: "/nonexistent/index.sqlite"),
              isEnabled: { enabled }, writeSettings: { value }, writeChannel: channel)
}

private func call(_ server: MCPServer, _ arguments: String) throws -> (isError: Bool, text: String) {
    let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_note","arguments":\#(arguments)}}"#
    let reply = try #require(server.handle(line))
    let message = try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    let result = try #require(message["result"] as? [String: Any])
    let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
    return (result["isError"] as? Bool ?? false, text)
}

private func tools(_ server: MCPServer) throws -> [[String: Any]] {
    let reply = try #require(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
    let message = try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    return try #require((message["result"] as? [String: Any])?["tools"] as? [[String: Any]])
}

private struct NoChannel: WriteChannel {
    let error: WriteChannelError
    func send(_ line: String) throws -> String { throw error }
}

func running(_ value: WriteSettings, writer: FakeWriter = FakeWriter(), confirmer: FakeConfirmer = FakeConfirmer())
    throws -> (server: WriteSocketServer, client: WriteSocketClient, directory: URL) {
    let url = shortSocketURL()
    let server = WriteSocketServer(path: url, service: service(value, writer: writer, confirmer: confirmer))
    try server.start()
    return (server, WriteSocketClient(path: url, timeoutSeconds: 5), url.deletingLastPathComponent())
}

@Test func createNoteIsListedWithItsSchemaAndAnnotations() throws {
    let listed = try tools(mcp(settings(), channel: NoChannel(error: .appNotRunning)))
    let tool = try #require(listed.first { $0["name"] as? String == "create_note" })
    let schema = try #require(tool["inputSchema"] as? [String: Any])
    #expect(Set(schema["required"] as? [String] ?? []) == ["title", "body"])
    let annotations = try #require(tool["annotations"] as? [String: Bool])
    #expect(annotations == ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false])
    #expect(listed.compactMap { $0["name"] as? String }.prefix(3) == ["search_notes", "get_note", "list_backlinks"])
}

@Test func createNoteIsHiddenAndRefusedWhileAnySettingBlocksIt() throws {
    let channel = NoChannel(error: .appNotRunning)
    let blocked: [(MCPServer, String)] = [
        (mcp(settings(), channel: channel, enabled: false), "AI agents"),
        (mcp(settings { $0.enabled = false }, channel: channel), "Writing to Notes is off"),
        (mcp(settings { $0.allowedActions = [] }, channel: channel), "not allowed"),
        (mcp(settings { $0.consent = .never }, channel: channel), "never allow"),
    ]
    for (server, reason) in blocked {
        #expect(try !tools(server).contains { $0["name"] as? String == "create_note" })
        let reply = try call(server, #"{"title":"T","body":"b"}"#)
        #expect(reply.isError && reply.text.contains(reason))
    }
}

@Test func markdownBecomesNoteHTML() {
    #expect(NoteHTML.html(fromMarkdown: "# Plan\n\nShip **it** now") == "<h1>Plan</h1><div>Ship <b>it</b> now</div>")
    #expect(NoteHTML.html(fromMarkdown: "## Two\n### Three") == "<h2>Two</h2><h3>Three</h3>")
    #expect(NoteHTML.html(fromMarkdown: "- a\n- b\n\n1. x\n2. y") == "<ul><li>a</li><li>b</li></ul><ol><li>x</li><li>y</li></ol>")
    #expect(NoteHTML.html(fromMarkdown: "*soft* and _also_ `code`") == "<div><i>soft</i> and <i>also</i> <tt>code</tt></div>")
    #expect(NoteHTML.html(fromMarkdown: "line one\nline two") == "<div>line one<br>line two</div>")
    #expect(NoteHTML.html(fromMarkdown: "snake_case_name stays") == "<div>snake_case_name stays</div>")
}

@Test func rawHTMLIsNeverPassedThrough() {
    #expect(NoteHTML.html(fromMarkdown: "<script>alert(1)</script> & more") == "<div>&lt;script&gt;alert(1)&lt;/script&gt; &amp; more</div>")
    #expect(NoteHTML.html(fromMarkdown: "`<b>x</b>` **<i>y</i>**") == "<div><tt>&lt;b&gt;x&lt;/b&gt;</tt> <b>&lt;i&gt;y&lt;/i&gt;</b></div>")
}

@Test func aCreateReachesTheWriterAndSucceeds() throws {
    let writer = FakeWriter()
    let live = try running(settings { $0.consent = .always }, writer: writer)
    defer {
        live.server.stop()
        try? FileManager.default.removeItem(at: live.directory)
    }
    let reply = try call(mcp(settings { $0.consent = .always }, channel: live.client), ##"{"title":"Plan","body":"# Hi\n\n- one"}"##)
    #expect(!reply.isError)
    #expect(writer.calls.count == 1 && writer.calls.first?.title == "Plan")
    #expect(writer.calls.first?.html == "<h1>Hi</h1><ul><li>one</li></ul>")
}

@Test func theAppsRefusalIsTheToolError() throws {
    let writer = FakeWriter()
    let confirmer = FakeConfirmer()
    confirmer.answer = false
    let live = try running(settings(), writer: writer, confirmer: confirmer)
    defer {
        live.server.stop()
        try? FileManager.default.removeItem(at: live.directory)
    }
    let reply = try call(mcp(settings(), channel: live.client), #"{"title":"Plan","body":"b"}"#)
    #expect(reply.isError && reply.text.contains("declined"))
    #expect(writer.calls.isEmpty)
}

@Test func anAppThatIsNotRunningIsAToolError() throws {
    let client = WriteSocketClient(path: URL(fileURLWithPath: "/tmp/tb-none/write.sock"), timeoutSeconds: 1)
    let reply = try call(mcp(settings(), channel: client), #"{"title":"Plan","body":"b"}"#)
    #expect(reply.isError && reply.text.contains("not running"))
}

@Test func oneServerKeepsOneSessionSoOncePerSessionAsksOnce() throws {
    let confirmer = FakeConfirmer()
    let value = settings { $0.consent = .oncePerSession }
    let live = try running(value, confirmer: confirmer)
    defer {
        live.server.stop()
        try? FileManager.default.removeItem(at: live.directory)
    }
    let server = mcp(value, channel: live.client)
    #expect(try !call(server, #"{"title":"A","body":"b"}"#).isError)
    #expect(try !call(server, #"{"title":"B","body":"b"}"#).isError)
    #expect(confirmer.timesAsked == 1)
}

@Test func badArgumentsSendNothing() throws {
    let writer = FakeWriter()
    let live = try running(settings { $0.consent = .always }, writer: writer)
    defer {
        live.server.stop()
        try? FileManager.default.removeItem(at: live.directory)
    }
    let server = mcp(settings { $0.consent = .always }, channel: live.client)
    for arguments in [#"{"body":"b"}"#, #"{"title":"","body":"b"}"#, #"{"title":"T"}"#, #"{"title":"T","body":3}"#, "{}"] {
        #expect(try call(server, arguments).isError)
    }
    #expect(writer.calls.isEmpty)
}
