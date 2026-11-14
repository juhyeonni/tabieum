import Darwin
import Foundation
import Testing
@testable import NotesCore

// The attack this file guards against: another process of the same user turns writing on with `defaults write`,
// reads note ids from the index and sends requests to write.sock without the owner being asked.

/// Runs /usr/bin/nc, a process that is not this app, as the socket client; sends one line and returns what came back.
private func foreignClient(socket: URL, line: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    process.arguments = ["-U", "-w", "2", socket.path]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    input.fileHandleForWriting.write(Data((line + "\n").utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// What `defaults write dev.juhyeonni.tabieum write.enabled -bool true` and friends leave behind.
/// Returns the suite name; a UserDefaults is not Sendable, so each read opens the suite again, as `.standard` would.
private func tamperedDefaults() -> String {
    let name = "test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    defaults.set(true, forKey: "write.enabled")
    defaults.set(["create", "edit", "delete"], forKey: "write.actions")
    defaults.set("always", forKey: "write.consent")
    defaults.set("anyNote", forKey: "write.scope")
    return name
}

private final class MemoryGrantStore: WriteGrantStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func load() -> String? { lock.withLock { stored } }
    func save(_ grant: String) { lock.withLock { stored = grant } }
}

private let attackedNote = ResolvedNote(
    handle: "h", title: "Diary", folder: "Personal", modified: Date(timeIntervalSince1970: 1_800_000_000), hasAttachments: false)

private let everything = settings { $0.allowedActions = [.create, .edit, .delete]; $0.scope = .anyNote; $0.consent = .always }

private func parse(_ reply: String) throws -> (ok: Bool, error: String) {
    let object = try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    return (object["ok"] as? Bool ?? false, object["error"] as? String ?? "")
}

private func serving(_ service: NoteWriteService) throws -> (server: WriteSocketServer, url: URL) {
    let url = shortSocketURL()
    let server = WriteSocketServer(path: url, service: service)
    try server.start()
    return (server, url)
}

// MARK: peer check

@Test func aForeignClientCannotDeleteEvenWhenTheSettingsAllowEverything() async throws {
    let writer = FakeWriter()
    writer.resolved = attackedNote
    let confirmer = FakeConfirmer()
    let live = try serving(service(everything, writer: writer, confirmer: confirmer))
    defer {
        live.server.stop()
        try? FileManager.default.removeItem(at: live.url.deletingLastPathComponent())
    }
    let reply = try parse(foreignClient(socket: live.url, line: #"{"action":"delete","id":"x-coredata://N-1"}"#))
    #expect(!reply.ok && reply.error.contains("Only this app's own --mcp process"))
    #expect(writer.trashCalls.isEmpty && writer.lookupCalls.isEmpty && confirmer.timesAsked == 0)
}

@Test func aForeignClientCannotEditWithRawHTML() async throws {
    let writer = FakeWriter()
    writer.resolved = attackedNote
    let live = try serving(service(everything, writer: writer))
    defer {
        live.server.stop()
        try? FileManager.default.removeItem(at: live.url.deletingLastPathComponent())
    }
    let line = #"{"action":"edit","id":"x-coredata://N-1","html":"<a href=\"https://evil.example\">click</a>","expected_modified":"2027-01-15T08:00:00Z"}"#
    #expect(try !parse(foreignClient(socket: live.url, line: line)).ok)
    #expect(writer.editCalls.isEmpty)
}

@Test func thisProcessPassesThePeerCheck() throws {
    var pair: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer { pair.forEach { close($0) } }
    #expect(WritePeer.runsSameCode(descriptor: pair[0]))
    #expect(!WritePeer.runsSameCode(descriptor: -1))
}

// MARK: settings changed outside the app

@Test func aDefaultsWriteAloneDoesNotTurnWritingOn() async throws {
    let suite = tamperedDefaults()
    let writer = FakeWriter()
    writer.resolved = attackedNote
    let confirmer = FakeConfirmer()
    let grants = MemoryGrantStore()
    let target = NoteWriteService(
        settings: { WriteSettings.approved(defaults: UserDefaults(suiteName: suite)!, grants: grants) },
        writer: writer, confirmer: confirmer, productName: "Tabieum")
    // Even a request from a client that passes the peer check is refused: these are not settings the app approved.
    let reply = try parse(await target.handle(#"{"action":"delete","id":"x-coredata://N-1"}"#, session: WriteSession()))
    #expect(!reply.ok && reply.error.contains("off"))
    #expect(writer.trashCalls.isEmpty && confirmer.timesAsked == 0)
}

@Test func onlyTheGrantFieldsFallBackWhenTheyDifferFromTheSavedGrant() {
    var wide = everything
    wide.marker = true
    #expect(wide.approved(by: wide.grant) == wide)
    let fallback = wide.approved(by: nil)
    #expect(!fallback.enabled && fallback.allowedActions == [.create] && fallback.scope == .targetFolder && fallback.consent == .eachTime)
    #expect(fallback.targetFolder == "Agents" && fallback.marker)
    var narrower = wide
    narrower.consent = .eachTime
    #expect(!wide.approved(by: narrower.grant).enabled)
    #expect(WriteSettings().approved(by: nil) == WriteSettings())
}

@Test func settingsChangedInTheAppAreHonoredAndOutsideChangesAreReset() throws {
    let name = "test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    let grants = MemoryGrantStore()
    let toggles = FeatureToggles(defaults: defaults, writeGrants: grants)
    #expect(!toggles.writeChangedOutside)
    toggles.write.enabled = true
    toggles.write.consent = .always
    toggles.write.scope = .anyNote
    #expect(grants.load() == toggles.write.grant)
    #expect(WriteSettings.approved(defaults: defaults, grants: grants) == toggles.write)
    let reloaded = FeatureToggles(defaults: defaults, writeGrants: grants)
    #expect(reloaded.write == toggles.write && !reloaded.writeChangedOutside)

    defaults.set(["create", "edit", "delete"], forKey: "write.actions")
    let tampered = FeatureToggles(defaults: defaults, writeGrants: grants)
    #expect(tampered.writeChangedOutside)
    #expect(!tampered.write.enabled && tampered.write.consent == .eachTime && tampered.write.scope == .targetFolder)
    #expect(!WriteSettings.approved(defaults: defaults, grants: grants).enabled)
    tampered.write.enabled = true
    #expect(!tampered.writeChangedOutside)
}

// MARK: raw html

@Test func theSocketRefusesHTMLAndEscapesMarkupInABody() async throws {
    let writer = FakeWriter()
    writer.resolved = attackedNote
    let target = service(everything, writer: writer)
    let html = try parse(await target.handle(#"{"action":"create","title":"T","html":"<b>x</b>"}"#, session: WriteSession()))
    #expect(!html.ok && html.error.contains("html is not accepted"))
    let edit = #"{"action":"edit","id":"n1","html":"<b>x</b>","body":"x","expected_modified":"2027-01-15T08:00:00Z"}"#
    #expect(try !parse(await target.handle(edit, session: WriteSession())).ok)
    #expect(writer.calls.isEmpty && writer.editCalls.isEmpty)
    let markup = #"{"action":"create","body":"<a href=\"https://evil.example\">click</a>"}"#
    #expect(try parse(await target.handle(markup, session: WriteSession())).ok)
    #expect(writer.calls.first?.html == "<div>&lt;a href=\"https://evil.example\"&gt;click&lt;/a&gt;</div>")
}

// MARK: accept loop

private final class FlakyAccept: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [Int32]
    private var count = 0

    init(failures: [Int32]) { self.failures = failures }

    var calls: Int { lock.withLock { count } }

    func accept(_ descriptor: Int32) -> Int32 {
        let failure: Int32? = lock.withLock {
            count += 1
            return failures.isEmpty ? nil : failures.removeFirst()
        }
        if let failure {
            errno = failure
            return -1
        }
        return Darwin.accept(descriptor, nil, nil)
    }
}

@Test func theAcceptLoopSurvivesTransientFailuresAndEndsWhenStopped() async throws {
    let flaky = FlakyAccept(failures: [EINTR, ECONNABORTED, EMFILE, ENFILE])
    let url = shortSocketURL()
    let server = WriteSocketServer(
        path: url, service: service(settings { $0.consent = .always }), peerCheck: .sameCode,
        acceptConnection: { flaky.accept($0) }, retryDelay: 0.01)
    try server.start()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let client = WriteSocketClient(path: url, timeoutSeconds: 5)
    #expect(try parse(client.send(createLine)).ok)
    #expect(flaky.calls >= 5)

    server.stop()
    try await Task.sleep(for: .milliseconds(200))
    let afterStop = flaky.calls
    try await Task.sleep(for: .milliseconds(200))
    #expect(flaky.calls == afterStop)
}
