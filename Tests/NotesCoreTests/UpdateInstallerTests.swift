import Foundation
import Testing
@testable import NotesCore

private func fixture(_ marker: String, in directory: URL) throws -> URL {
    let app = directory.appendingPathComponent("App.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try Data(marker.utf8).write(to: app.appendingPathComponent("Contents/marker.txt"))
    return app
}

private func marker(_ app: URL) -> String? {
    (try? Data(contentsOf: app.appendingPathComponent("Contents/marker.txt"))).map { String(decoding: $0, as: UTF8.self) }
}

private func setUp() throws -> (installed: URL, staged: StagedUpdate) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = root.appendingPathComponent("staging")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return (try fixture("old", in: root), StagedUpdate(app: try fixture("new", in: folder), folder: folder))
}

@Test func swapPutsTheNewAppInPlaceAndTrashesTheOldOne() throws {
    let (installed, staged) = try setUp()
    var trashed: [URL] = []
    try UpdateInstaller.install(staged, over: installed, isCancelled: { false }, trash: { trashed.append($0) })
    #expect(marker(installed) == "new")
    #expect(!FileManager.default.fileExists(atPath: staged.folder.path))
    #expect(trashed.count == 1)
    #expect(marker(trashed[0]) == "old")
}

@Test func aTrashFailureStillCountsAsUpdated() throws {
    let (installed, staged) = try setUp()
    try UpdateInstaller.install(
        staged, over: installed, isCancelled: { false }, trash: { _ in throw CocoaError(.fileWriteNoPermission) })
    #expect(marker(installed) == "new")
}

@Test func aFailedSwapLeavesTheInstalledAppAsItWas() throws {
    let (installed, staged) = try setUp()
    try FileManager.default.removeItem(at: staged.app)
    #expect(throws: UpdateFailure.self) {
        try UpdateInstaller.install(staged, over: installed, isCancelled: { false }, trash: { _ in })
    }
    #expect(marker(installed) == "old")
}

@Test func cancelBeforeTheSwapKeepsTheInstalledAppAndRemovesStaging() throws {
    let (installed, staged) = try setUp()
    #expect(throws: UpdateFailure.cancelled) {
        try UpdateInstaller.install(staged, over: installed, isCancelled: { true }, trash: { _ in })
    }
    #expect(marker(installed) == "old")
    #expect(!FileManager.default.fileExists(atPath: staged.folder.path))
}

@Test func cancelOnceTheSwapStartedDoesNotStopIt() throws {
    let (installed, staged) = try setUp()
    var started = false
    try UpdateInstaller.install(
        staged, over: installed, isCancelled: { started }, trash: { _ in }, beginSwap: { started = true })
    #expect(marker(installed) == "new")
}

@Test func relaunchArgumentsCarryThePidAndPathAsSeparateArguments() {
    let app = URL(fileURLWithPath: "/Apps/My \"Odd\" Folder/Tabieum.app")
    let arguments = UpdateRelaunch.arguments(pid: 42, app: app)
    #expect(Array(arguments.suffix(2)) == ["42", app.path])
    #expect(!arguments[1].contains("Odd"))
}
