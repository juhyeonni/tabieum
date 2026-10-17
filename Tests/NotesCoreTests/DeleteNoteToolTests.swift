import Foundation
import Testing
@testable import NotesCore

private let victim = ResolvedNote(
    handle: "x-coredata://S/ICNote/p2", title: "Old plan", folder: "Agents",
    modified: Date(timeIntervalSinceReferenceDate: 100), hasAttachments: false)

private let deleteLine = #"{"action":"delete","id":"n1"}"#

private func deleting(_ change: (inout WriteSettings) -> Void = { _ in }) -> WriteSettings {
    settings { $0.allowedActions = [.create, .delete]; change(&$0) }
}

private func finding(_ note: ResolvedNote? = victim) -> FakeWriter {
    let writer = FakeWriter()
    writer.resolved = note
    return writer
}

private func result(_ reply: String) throws -> (ok: Bool, error: String) {
    let object = try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    return (object["ok"] as? Bool ?? false, object["error"] as? String ?? "")
}

@Test func refusesADeleteWhileASwitchBlocksIt() async throws {
    let fake = finding()
    let blocked = [deleting { $0.enabled = false }, settings(), deleting { $0.consent = .never },
                   deleting { $0.scope = .targetFolder; $0.targetFolder = "" }]
    for value in blocked {
        #expect(try !result(await service(value, writer: fake).handle(deleteLine, session: WriteSession())).ok)
    }
    #expect(fake.trashCalls.isEmpty)
}

@Test func aNoteOutOfScopeOrMissingIsNotDeleted() async throws {
    let fake = finding(nil)
    let reply = try result(await service(deleting { $0.consent = .always }, writer: fake).handle(deleteLine, session: WriteSession()))
    #expect(!reply.ok && reply.error.contains("No note"))
    #expect(fake.trashCalls.isEmpty)
}

@Test func theDeleteLookupGetsTheOwnersScopeAndTargetFolder() async throws {
    let fake = finding()
    let value = deleting { $0.consent = .always; $0.scope = .anyNote }
    _ = await service(value, writer: fake).handle(#"{"action":"delete","id":"abc"}"#, session: WriteSession())
    let call = try #require(fake.lookupCalls.first)
    #expect(call.id == "abc" && call.scope == .anyNote && call.target == NoteTarget(account: "iCloud", folder: "Agents"))
}

@Test func deleteConsentFollowsTheSameModes() async throws {
    let fake = finding()
    let confirmer = FakeConfirmer()
    let each = service(deleting(), writer: fake, confirmer: confirmer)
    let session = WriteSession()
    _ = await each.handle(deleteLine, session: session)
    _ = await each.handle(deleteLine, session: session)
    #expect(confirmer.timesAsked == 2 && fake.trashCalls.count == 2)
    confirmer.answer = false
    #expect(try !result(await each.handle(deleteLine, session: session)).ok)
    #expect(fake.trashCalls.count == 2)

    let onceConfirmer = FakeConfirmer()
    let once = service(deleting { $0.consent = .oncePerSession }, writer: finding(), confirmer: onceConfirmer)
    let connection = WriteSession()
    _ = await once.handle(deleteLine, session: connection)
    _ = await once.handle(deleteLine, session: connection)
    #expect(onceConfirmer.timesAsked == 1)

    let silent = FakeConfirmer()
    _ = await service(deleting { $0.consent = .always }, writer: finding(), confirmer: silent).handle(deleteLine, session: WriteSession())
    #expect(silent.timesAsked == 0)

    let mute = FakeConfirmer()
    mute.answer = nil
    let kept = finding()
    let timedOut = try result(await service(deleting(), writer: kept, confirmer: mute, timeout: .milliseconds(50))
        .handle(deleteLine, session: WriteSession()))
    #expect(!timedOut.ok && timedOut.error.contains("in time") && kept.trashCalls.isEmpty)
}

@Test func anApprovedDeleteMovesTheNoteToTheTrashOnce() async throws {
    let withFile = ResolvedNote(handle: victim.handle, title: victim.title, folder: "Agents", modified: victim.modified, hasAttachments: true)
    let fake = finding(withFile)
    let reply = try result(await service(deleting { $0.consent = .always }, writer: fake).handle(deleteLine, session: WriteSession()))
    #expect(reply.ok && fake.trashCalls == [withFile])
}

// MARK: through the MCP server and a real socket

private func mcp(_ value: WriteSettings, channel: WriteChannel?, enabled: Bool = true) -> MCPServer {
    MCPServer(serverName: "tabieum", version: "0", indexURL: URL(fileURLWithPath: "/nonexistent/index.sqlite"),
              isEnabled: { enabled }, writeSettings: { value }, writeChannel: channel)
}

private func call(_ server: MCPServer, _ arguments: String) throws -> (isError: Bool, text: String) {
    let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete_note","arguments":\#(arguments)}}"#
    let reply = try #require(server.handle(line))
    let message = try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    let outcome = try #require(message["result"] as? [String: Any])
    let text = try #require((outcome["content"] as? [[String: Any]])?.first?["text"] as? String)
    return (outcome["isError"] as? Bool ?? false, text)
}

private func listed(_ server: MCPServer) throws -> [[String: Any]] {
    let reply = try #require(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
    let message = try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    return try #require((message["result"] as? [String: Any])?["tools"] as? [[String: Any]])
}

private struct Unreachable: WriteChannel {
    func send(_ line: String) throws -> String { throw WriteChannelError.appNotRunning }
}

@Test func deleteNoteIsListedWithItsSchemaAndAnnotations() throws {
    let tool = try #require(listed(mcp(deleting(), channel: Unreachable())).first { $0["name"] as? String == "delete_note" })
    let schema = try #require(tool["inputSchema"] as? [String: Any])
    #expect(schema["required"] as? [String] == ["id"])
    let annotations = try #require(tool["annotations"] as? [String: Bool])
    #expect(annotations == ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false])
}

@Test func deleteNoteIsHiddenAndRefusedWhileAnySettingBlocksIt() throws {
    let channel = Unreachable()
    let blocked: [(MCPServer, String)] = [
        (mcp(deleting(), channel: channel, enabled: false), "AI agents"),
        (mcp(deleting { $0.enabled = false }, channel: channel), "Writing to Notes is off"),
        (mcp(settings(), channel: channel), "not allowed"),
        (mcp(deleting { $0.consent = .never }, channel: channel), "never allow"),
    ]
    for (server, reason) in blocked {
        #expect(try !listed(server).contains { $0["name"] as? String == "delete_note" })
        let reply = try call(server, #"{"id":"n1"}"#)
        #expect(reply.isError && reply.text.contains(reason))
    }
}

@Test func aDeleteWithoutAnIdSendsNothing() throws {
    let fake = finding()
    let value = deleting { $0.consent = .always }
    let live = try running(value, writer: fake)
    defer {
        live.server.stop()
        try? FileManager.default.removeItem(at: live.directory)
    }
    for arguments in ["{}", #"{"id":""}"#, #"{"id":3}"#] {
        #expect(try call(mcp(value, channel: live.client), arguments).isError)
    }
    #expect(fake.lookupCalls.isEmpty)
}

@Test func deleteThroughTheSocketSucceedsInScopeAndIsRefusedOutOfScope() throws {
    let fake = finding()
    let value = deleting { $0.consent = .always }
    let live = try running(value, writer: fake)
    defer {
        live.server.stop()
        try? FileManager.default.removeItem(at: live.directory)
    }
    let server = mcp(value, channel: live.client)
    #expect(try !call(server, #"{"id":"n1"}"#).isError)
    #expect(fake.trashCalls.count == 1)
    fake.resolved = nil
    let outside = try call(server, #"{"id":"n2"}"#)
    #expect(outside.isError && outside.text.contains("No note"))
    #expect(fake.trashCalls.count == 1)
}
