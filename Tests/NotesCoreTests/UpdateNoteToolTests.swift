import Foundation
import Testing
@testable import NotesCore

private let readAt = Date(timeIntervalSinceReferenceDate: 100)
private let stamp = ISO8601DateFormatter().string(from: readAt)

private func note(modified: Date = readAt, attachments: Bool = false) -> ResolvedNote {
    ResolvedNote(handle: "x-coredata://S/ICNote/p1", title: "Plan", folder: "Agents", modified: modified, hasAttachments: attachments)
}

private func editLine(id: String = "n1", html: String = "<div>new</div>", expected: String = stamp) -> String {
    #"{"action":"edit","id":"\#(id)","html":"\#(html)","expected_modified":"\#(expected)"}"#
}

private func parse(_ reply: String) throws -> (ok: Bool, error: String) {
    let object = try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    return (object["ok"] as? Bool ?? false, object["error"] as? String ?? "")
}

private func editing(_ change: (inout WriteSettings) -> Void = { _ in }) -> WriteSettings {
    settings { $0.allowedActions = [.create, .edit]; change(&$0) }
}

private func writer(_ found: ResolvedNote? = note()) -> FakeWriter {
    let writer = FakeWriter()
    writer.resolved = found
    return writer
}

@Test func refusesAnEditWhileASwitchBlocksIt() async throws {
    let fake = writer()
    let blocked = [editing { $0.enabled = false }, settings(), editing { $0.consent = .never },
                   editing { $0.scope = .targetFolder; $0.targetFolder = "" }]
    for value in blocked {
        #expect(try !parse(await service(value, writer: fake).handle(editLine(), session: WriteSession())).ok)
    }
    #expect(fake.editCalls.isEmpty)
}

@Test func aNoteOutOfScopeOrMissingIsRefusedWithoutAWrite() async throws {
    let fake = writer(nil)
    let reply = try parse(await service(editing { $0.consent = .always }, writer: fake).handle(editLine(), session: WriteSession()))
    #expect(!reply.ok && reply.error.contains("No note"))
    #expect(fake.editCalls.isEmpty)
}

@Test func theLookupGetsTheOwnersScopeAndTargetFolder() async throws {
    let fake = writer()
    let value = editing { $0.consent = .always; $0.scope = .mcpCreated }
    _ = await service(value, writer: fake).handle(editLine(id: "abc"), session: WriteSession())
    let call = try #require(fake.lookupCalls.first)
    #expect(call.id == "abc" && call.scope == .mcpCreated && call.target == NoteTarget(account: "iCloud", folder: "Agents"))
}

@Test func aNoteWithAttachmentsIsRefused() async throws {
    let fake = writer(note(attachments: true))
    let reply = try parse(await service(editing { $0.consent = .always }, writer: fake).handle(editLine(), session: WriteSession()))
    #expect(!reply.ok && reply.error.contains("attachments"))
    #expect(fake.editCalls.isEmpty)
}

@Test func aNoteChangedSinceTheReadIsRefusedUnlessWithinTheTolerance() async throws {
    let value = editing { $0.consent = .always }
    let stale = writer(note(modified: readAt.addingTimeInterval(5)))
    let refused = try parse(await service(value, writer: stale).handle(editLine(), session: WriteSession()))
    #expect(!refused.ok && refused.error.contains("Read it again") && stale.editCalls.isEmpty)
    let close = writer(note(modified: readAt.addingTimeInterval(1)))
    #expect(try parse(await service(value, writer: close).handle(editLine(), session: WriteSession())).ok)
    #expect(close.editCalls.count == 1)
}

@Test func editConsentFollowsTheSameModesAsCreate() async throws {
    let fake = writer()
    let confirmer = FakeConfirmer()
    let each = service(editing(), writer: fake, confirmer: confirmer)
    let session = WriteSession()
    _ = await each.handle(editLine(), session: session)
    _ = await each.handle(editLine(), session: session)
    #expect(confirmer.timesAsked == 2 && fake.editCalls.count == 2)
    confirmer.answer = false
    let declined = try parse(await each.handle(editLine(), session: session))
    #expect(!declined.ok && fake.editCalls.count == 2)

    let onceConfirmer = FakeConfirmer()
    let once = service(editing { $0.consent = .oncePerSession }, writer: writer(), confirmer: onceConfirmer)
    let connection = WriteSession()
    _ = await once.handle(editLine(), session: connection)
    _ = await once.handle(editLine(), session: connection)
    #expect(onceConfirmer.timesAsked == 1)

    let silent = FakeConfirmer()
    _ = await service(editing { $0.consent = .always }, writer: writer(), confirmer: silent).handle(editLine(), session: WriteSession())
    #expect(silent.timesAsked == 0)

    let mute = FakeConfirmer()
    mute.answer = nil
    let late = writer()
    let timedOut = try parse(await service(editing(), writer: late, confirmer: mute, timeout: .milliseconds(50))
        .handle(editLine(), session: WriteSession()))
    #expect(!timedOut.ok && timedOut.error.contains("in time") && late.editCalls.isEmpty)
}

@Test func anApprovedEditReplacesTheBodyOnce() async throws {
    let fake = writer()
    let reply = try parse(await service(editing { $0.consent = .always }, writer: fake).handle(editLine(), session: WriteSession()))
    #expect(reply.ok)
    #expect(fake.editCalls.count == 1 && fake.editCalls.first?.html == "<div>new</div>" && fake.editCalls.first?.note == note())
}

@Test func createdNotesAreRememberedAcrossInstances() {
    let name = "test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    CreatedNoteLog(defaults: defaults).record("x-coredata://S/ICNote/p7")
    #expect(CreatedNoteLog(defaults: defaults).contains("x-coredata://S/ICNote/p7"))
    #expect(!CreatedNoteLog(defaults: defaults).contains("x-coredata://S/ICNote/p8"))
}

// MARK: through the MCP server and a real socket

private func mcp(_ value: WriteSettings, channel: WriteChannel?, enabled: Bool = true) -> MCPServer {
    MCPServer(serverName: "tabieum", version: "0", indexURL: URL(fileURLWithPath: "/nonexistent/index.sqlite"),
              isEnabled: { enabled }, writeSettings: { value }, writeChannel: channel)
}

private func call(_ server: MCPServer, _ arguments: String) throws -> (isError: Bool, text: String) {
    let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_note","arguments":\#(arguments)}}"#
    let reply = try #require(server.handle(line))
    let message = try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    let result = try #require(message["result"] as? [String: Any])
    let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
    return (result["isError"] as? Bool ?? false, text)
}

private func listed(_ server: MCPServer) throws -> [[String: Any]] {
    let reply = try #require(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
    let message = try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    return try #require((message["result"] as? [String: Any])?["tools"] as? [[String: Any]])
}

private struct Unreachable: WriteChannel {
    func send(_ line: String) throws -> String { throw WriteChannelError.appNotRunning }
}

@Test func updateNoteIsListedWithItsSchemaAndAnnotations() throws {
    let tool = try #require(listed(mcp(editing(), channel: Unreachable())).first { $0["name"] as? String == "update_note" })
    let schema = try #require(tool["inputSchema"] as? [String: Any])
    #expect(Set(schema["required"] as? [String] ?? []) == ["id", "body", "expected_modified"])
    let annotations = try #require(tool["annotations"] as? [String: Bool])
    #expect(annotations == ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false])
}

@Test func updateNoteIsHiddenAndRefusedWhileAnySettingBlocksIt() throws {
    let channel = Unreachable()
    let blocked: [(MCPServer, String)] = [
        (mcp(editing(), channel: channel, enabled: false), "AI agents"),
        (mcp(editing { $0.enabled = false }, channel: channel), "Writing to Notes is off"),
        (mcp(settings(), channel: channel), "not allowed"),
        (mcp(editing { $0.consent = .never }, channel: channel), "never allow"),
    ]
    for (server, reason) in blocked {
        #expect(try !listed(server).contains { $0["name"] as? String == "update_note" })
        let reply = try call(server, #"{"id":"n1","body":"b","expected_modified":"\#(stamp)"}"#)
        #expect(reply.isError && reply.text.contains(reason))
    }
}

@Test func badUpdateArgumentsSendNothing() throws {
    let fake = writer()
    let value = editing { $0.consent = .always }
    let live = try running(value, writer: fake)
    defer {
        live.server.stop()
        try? FileManager.default.removeItem(at: live.directory)
    }
    let server = mcp(value, channel: live.client)
    for arguments in [#"{"body":"b","expected_modified":"\#(stamp)"}"#, #"{"id":"","body":"b","expected_modified":"\#(stamp)"}"#,
                      #"{"id":"n1","expected_modified":"\#(stamp)"}"#, #"{"id":"n1","body":"b"}"#,
                      #"{"id":"n1","body":"b","expected_modified":"yesterday"}"#, "{}"] {
        #expect(try call(server, arguments).isError)
    }
    #expect(fake.lookupCalls.isEmpty)
}

@Test func anUpdateSucceedsThenIsRefusedOnceTheNoteHasChanged() throws {
    let fake = writer()
    let value = editing { $0.consent = .always }
    let live = try running(value, writer: fake)
    defer {
        live.server.stop()
        try? FileManager.default.removeItem(at: live.directory)
    }
    let server = mcp(value, channel: live.client)
    let arguments = ##"{"id":"n1","body":"# New","expected_modified":"\##(stamp)"}"##
    #expect(try !call(server, arguments).isError)
    #expect(fake.editCalls.first?.html == "<h1>New</h1>")
    fake.resolved = note(modified: readAt.addingTimeInterval(60))
    let stale = try call(server, arguments)
    #expect(stale.isError && stale.text.contains("Read it again"))
    #expect(fake.editCalls.count == 1)
}
