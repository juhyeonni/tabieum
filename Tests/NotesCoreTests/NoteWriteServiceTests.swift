import Darwin
import Foundation
import Testing
@testable import NotesCore

private final class FakeWriter: NoteWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var created: [(title: String, html: String, target: NoteTarget)] = []
    var folderExists = true
    var failure: WriteFailure?

    var calls: [(title: String, html: String, target: NoteTarget)] { lock.withLock { created } }

    func folderExists(_ target: NoteTarget) async throws -> Bool { folderExists }

    func createNote(title: String, html: String, in target: NoteTarget) async throws {
        if let failure { throw failure }
        lock.withLock { created.append((title, html, target)) }
    }
}

private final class FakeConfirmer: WriteConfirmer, @unchecked Sendable {
    private let lock = NSLock()
    private var asked = 0
    var answer: Bool? = true

    var timesAsked: Int { lock.withLock { asked } }

    func confirm(_ request: ConfirmRequest) async -> Bool {
        lock.withLock { asked += 1 }
        guard let answer else {
            try? await Task.sleep(for: .seconds(30))
            return false
        }
        return answer
    }
}

private func settings(_ change: (inout WriteSettings) -> Void = { _ in }) -> WriteSettings {
    var value = WriteSettings()
    value.enabled = true
    value.targetAccount = "iCloud"
    value.targetFolder = "Agents"
    change(&value)
    return value
}

private func service(
    _ value: WriteSettings, writer: FakeWriter = FakeWriter(), confirmer: FakeConfirmer = FakeConfirmer(),
    timeout: Duration = .seconds(60)
) -> NoteWriteService {
    NoteWriteService(settings: { value }, writer: writer, confirmer: confirmer, productName: "tabieum", timeout: timeout)
}

private let createLine = #"{"action":"create","title":"Plan","html":"<div>Ship it</div>"}"#

private func parse(_ reply: String) throws -> (ok: Bool, error: String) {
    let object = try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    return (object["ok"] as? Bool ?? false, object["error"] as? String ?? "")
}

private func freshSuite() -> UserDefaults {
    let name = "test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Test func writeSettingsDefaultToOffAndPersist() {
    let defaults = freshSuite()
    let toggles = FeatureToggles(defaults: defaults)
    #expect(toggles.write == WriteSettings())
    #expect(!toggles.write.enabled && !toggles.write.marker)
    #expect(toggles.write.allowedActions == [.create])
    #expect(toggles.write.scope == .targetFolder && toggles.write.consent == .eachTime)
    toggles.write.enabled = true
    toggles.write.allowedActions = [.create, .delete]
    toggles.write.scope = .mcpCreated
    toggles.write.targetAccount = "iCloud"
    toggles.write.targetFolder = "Agents"
    toggles.write.consent = .oncePerSession
    toggles.write.marker = true
    #expect(FeatureToggles(defaults: defaults).write == toggles.write)
}

@Test func refusesWhileTheMasterSwitchIsOff() async throws {
    let writer = FakeWriter()
    let reply = try parse(await service(settings { $0.enabled = false }, writer: writer).handle(createLine, session: WriteSession()))
    #expect(!reply.ok && reply.error.contains("off"))
    #expect(writer.calls.isEmpty)
}

@Test func refusesWhenCreateIsNotAllowedOrConsentIsNever() async throws {
    let writer = FakeWriter()
    let notAllowed = try parse(await service(settings { $0.allowedActions = [] }, writer: writer).handle(createLine, session: WriteSession()))
    let never = try parse(await service(settings { $0.consent = .never }, writer: writer).handle(createLine, session: WriteSession()))
    #expect(!notAllowed.ok && !never.ok)
    #expect(writer.calls.isEmpty)
}

@Test func refusesWithoutAUsableTargetFolder() async throws {
    let writer = FakeWriter()
    let confirmer = FakeConfirmer()
    let none = try parse(await service(settings { $0.targetFolder = "" }, writer: writer, confirmer: confirmer)
        .handle(createLine, session: WriteSession()))
    #expect(!none.ok && none.error.contains("No target folder"))
    writer.folderExists = false
    let gone = try parse(await service(settings(), writer: writer, confirmer: confirmer).handle(createLine, session: WriteSession()))
    #expect(!gone.ok && gone.error.contains("does not exist"))
    #expect(writer.calls.isEmpty && confirmer.timesAsked == 0)
}

@Test func eachTimeAsksForEveryCreateAndHonorsARefusal() async throws {
    let writer = FakeWriter()
    let confirmer = FakeConfirmer()
    let target = service(settings(), writer: writer, confirmer: confirmer)
    let session = WriteSession()
    let approved = try parse(await target.handle(createLine, session: session))
    _ = try parse(await target.handle(createLine, session: session))
    #expect(approved.ok && confirmer.timesAsked == 2 && writer.calls.count == 2)
    #expect(writer.calls.first?.title == "Plan" && writer.calls.first?.html == "<div>Ship it</div>")
    #expect(writer.calls.first?.target == NoteTarget(account: "iCloud", folder: "Agents"))
    confirmer.answer = false
    let declined = try parse(await target.handle(createLine, session: session))
    #expect(!declined.ok && declined.error.contains("declined") && writer.calls.count == 2)
}

@Test func oncePerSessionAsksOnlyOnTheFirstCreateOfAConnection() async throws {
    let writer = FakeWriter()
    let confirmer = FakeConfirmer()
    let target = service(settings { $0.consent = .oncePerSession }, writer: writer, confirmer: confirmer)
    let first = WriteSession()
    _ = await target.handle(createLine, session: first)
    _ = await target.handle(createLine, session: first)
    #expect(confirmer.timesAsked == 1 && writer.calls.count == 2)
    _ = await target.handle(createLine, session: WriteSession())
    #expect(confirmer.timesAsked == 2)
}

@Test func alwaysAllowNeverAsks() async throws {
    let writer = FakeWriter()
    let confirmer = FakeConfirmer()
    let reply = try parse(await service(settings { $0.consent = .always }, writer: writer, confirmer: confirmer)
        .handle(createLine, session: WriteSession()))
    #expect(reply.ok && confirmer.timesAsked == 0 && writer.calls.count == 1)
}

@Test func anUnansweredConfirmationIsRefusedAsATimeout() async throws {
    let writer = FakeWriter()
    let confirmer = FakeConfirmer()
    confirmer.answer = nil
    let reply = try parse(await service(settings(), writer: writer, confirmer: confirmer, timeout: .milliseconds(50))
        .handle(createLine, session: WriteSession()))
    #expect(!reply.ok && reply.error.contains("in time"))
    #expect(writer.calls.isEmpty)
}

@Test func theMarkerEndsTheBodyOnlyWhenOn() async throws {
    let on = FakeWriter()
    let off = FakeWriter()
    _ = await service(settings { $0.consent = .always; $0.marker = true }, writer: on).handle(createLine, session: WriteSession())
    _ = await service(settings { $0.consent = .always }, writer: off).handle(createLine, session: WriteSession())
    #expect(on.calls.first?.html.hasSuffix("Created by an AI agent through tabieum.</div>") == true)
    #expect(off.calls.first?.html == "<div>Ship it</div>")
}

@Test func deniedAutomationTellsTheOwnerToAllowIt() async throws {
    let writer = FakeWriter()
    writer.failure = .automationDenied
    let reply = try parse(await service(settings { $0.consent = .always }, writer: writer).handle(createLine, session: WriteSession()))
    #expect(!reply.ok && reply.error.contains("Automation"))
}

@Test func malformedRequestsGetAnErrorReply() async throws {
    let target = service(settings())
    for line in ["not json", #"{"action":"nope"}"#, #"{"action":"create","title":""}"#, #"{"action":"delete","id":"x"}"#] {
        #expect(try !parse(await target.handle(line, session: WriteSession())).ok)
    }
}

// MARK: socket

private func shortSocketURL() -> URL {
    URL(fileURLWithPath: "/tmp/tb-\(UUID().uuidString.prefix(8))/write.sock")
}

private final class SocketClient {
    private let descriptor: Int32

    init(path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) } }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(connected == 0)
        var limit = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close(descriptor) }

    func send(_ line: String) -> String {
        let bytes = Array((line + "\n").utf8)
        write(descriptor, bytes, bytes.count)
        var reply: [UInt8] = []
        var byte: UInt8 = 0
        while read(descriptor, &byte, 1) == 1, byte != 10 { reply.append(byte) }
        return String(decoding: reply, as: UTF8.self)
    }
}

@Test func socketAnswersEveryLineAndSurvivesAMalformedOne() async throws {
    let url = shortSocketURL()
    let server = WriteSocketServer(path: url, service: service(settings { $0.consent = .always }))
    try server.start()
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    let client = try SocketClient(path: url.path)
    #expect(try !parse(client.send("garbage")).ok)
    #expect(try parse(client.send(createLine)).ok)
}

@Test func socketIsPrivateAndReplacesAStaleFile() throws {
    let url = shortSocketURL()
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("stale".utf8).write(to: url)
    let server = WriteSocketServer(path: url, service: service(settings()))
    try server.start()
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    func mode(_ path: String) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int ?? -1) & 0o777
    }
    #expect(try mode(url.path) == 0o600)
    #expect(try mode(directory.path) == 0o700)
}
