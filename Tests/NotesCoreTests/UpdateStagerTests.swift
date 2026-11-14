import Foundation
import Testing
@testable import NotesCore

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "\(tool) \(arguments)")
}

private func makeApp(
    in directory: URL, version: String, id: String = "me.app", marker: String = "a", sign: Bool = true
) throws -> URL {
    let app = directory.appendingPathComponent("App.app")
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
    try fileManager.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/App"))
    try Data(marker.utf8).write(to: app.appendingPathComponent("Contents/Resources/marker.txt"))
    let info: [String: Any] = [
        "CFBundleIdentifier": id, "CFBundleName": "App", "CFBundleExecutable": "App",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
    ]
    try (info as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
    if sign { try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) }
    return app
}

private func zip(_ app: URL, to archive: URL) throws {
    try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path])
}

private func tree(_ directory: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = walker?.nextObject() as? URL {
        guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
        files[url.path.replacingOccurrences(of: directory.path, with: "")] = try Data(contentsOf: url)
    }
    return files
}

private let downloads = "https://github.com/me/app/releases/download/v1.1.0/"

private func release(version: String = "1.1.0") -> Release {
    Release(
        version: version, url: URL(string: "https://github.com/me/app/releases/tag/v\(version)")!, notes: "",
        zip: URL(string: downloads + "App-\(version).zip")!, checksum: URL(string: downloads + "App-\(version).zip.sha256")!)
}

/// Serves the files of `remote` for the release addresses, as a copy, the way a download hands over a temporary file.
private func fetch(from remote: URL) -> UpdateStager.Fetch {
    { url, _ in
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: remote.appendingPathComponent(url.lastPathComponent), to: copy)
        return copy
    }
}

private func publish(_ archive: URL, as name: String = "App-1.1.0.zip", in remote: URL, checksumName: String? = nil) throws {
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: archive, to: remote.appendingPathComponent(name))
    let line = "\(try ModelInstaller.sha256(of: archive))  \(checksumName ?? name)\n"
    try Data(line.utf8).write(to: remote.appendingPathComponent(name + ".sha256"))
}

private func failure(_ body: () async throws -> Void) async -> UpdateFailure? {
    do { try await body() } catch { return error as? UpdateFailure }
    return nil
}

private final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite(.serialized)
struct UpdateStagerTests {
    @Test func checksumMustMatchTheZipAndNameIt() throws {
        let directory = try scratch()
        let archive = directory.appendingPathComponent("App-1.1.0.zip")
        try Data("zip".utf8).write(to: archive)
        let digest = try ModelInstaller.sha256(of: archive)
        func check(_ text: String) -> UpdateFailure? {
            let file = directory.appendingPathComponent("sums")
            try? Data(text.utf8).write(to: file)
            do { try UpdateStager.verifyChecksum(of: archive, named: "App-1.1.0.zip", against: file) } catch {
                return error as? UpdateFailure
            }
            return nil
        }
        #expect(check("\(digest)  App-1.1.0.zip\n") == nil)
        #expect(check("\(String(repeating: "0", count: 64))  App-1.1.0.zip\n") == .checksumMismatch)
        #expect(check("\(digest)  Other.zip\n") == .checksumNamesOtherFile)
        #expect(check("not a checksum") == .checksumFileUnreadable)
        #expect(check("") == .checksumFileUnreadable)
    }

    @Test func archiveEntriesMustStayInsideTheApp() {
        func check(_ entries: [String]) -> UpdateFailure? {
            do { try UpdateStager.checkEntries(entries, product: "App") } catch { return error as? UpdateFailure }
            return nil
        }
        #expect(check(["App.app/", "App.app/Contents/Info.plist", "__MACOSX/", "__MACOSX/._App.app"]) == nil)
        #expect(check([]) == .unsafeArchive)
        #expect(check(["/etc/passwd"]) == .unsafeArchive)
        #expect(check(["App.app/../../x"]) == .unsafeArchive)
        #expect(check(["App.app/Contents/../../x"]) == .unsafeArchive)
        #expect(check(["Other.app/Contents"]) == .unsafeArchive)
        #expect(check(["App.app/ok", "evil.txt"]) == .unsafeArchive)
        #expect(check(["App.appx/ok"]) == .unsafeArchive)
        #expect(check(["__MACOSX/../x"]) == .unsafeArchive)
    }

    @Test func stagedAppNeedsTheSameIdentifierAndTheOfferedNewerVersion() throws {
        let app = try makeApp(in: try scratch(), version: "1.1.0", sign: false)
        func check(id: String? = "me.app", version: String = "1.1.0", running: String = "1.0.0") -> UpdateFailure? {
            do { try UpdateStager.checkApp(app, bundleIdentifier: id, version: version, newerThan: running) } catch {
                return error as? UpdateFailure
            }
            return nil
        }
        #expect(check() == nil)
        #expect(check(id: "other.app") == .wrongBundle)
        #expect(check(id: nil) == .wrongBundle)
        #expect(check(version: "1.2.0") == .wrongVersion)
        #expect(check(running: "1.1.0") == .notNewer)
        #expect(check(running: "1.2.0") == .notNewer)
    }

    @Test func signatureMustSatisfyTheRunningAppsRequirement() throws {
        let directory = try scratch()
        let running = try makeApp(in: directory.appendingPathComponent("running", isDirectory: true), version: "1.0.0")
        let copy = directory.appendingPathComponent("copy.app")
        try FileManager.default.copyItem(at: running, to: copy)
        let other = try makeApp(in: directory.appendingPathComponent("other", isDirectory: true), version: "1.0.0", marker: "b")
        let unsigned = try makeApp(in: directory.appendingPathComponent("unsigned", isDirectory: true), version: "1.0.0", sign: false)
        func check(_ app: URL) -> Bool {
            do { try UpdateStager.checkSignature(of: app, against: running) } catch { return false }
            return true
        }
        #expect(check(copy))
        #expect(!check(other))
        #expect(!check(unsigned))
    }

    @Test func aVerifiedReleaseIsStagedBesideTheInstalledAppWithoutTouchingIt() async throws {
        let directory = try scratch()
        let installed = try makeApp(in: directory.appendingPathComponent("Applications", isDirectory: true), version: "1.1.0")
        let remote = directory.appendingPathComponent("remote")
        let archive = directory.appendingPathComponent("App-1.1.0.zip")
        try zip(installed, to: archive)
        try publish(archive, in: remote)
        let before = try tree(installed)
        let reported = Box<Double>()
        let staged = try await UpdateStager.stage(
            release(), installed: installed, runningVersion: "1.0.0", product: "App", repository: "me/app",
            fetch: fetch(from: remote)
        ) { reported.append($0) }
        #expect(reported.values == reported.values.sorted())
        #expect(staged.app == staged.folder.appendingPathComponent("App.app"))
        #expect(try tree(staged.app) == before)
        #expect(try tree(installed) == before)
        try FileManager.default.removeItem(at: staged.folder)
    }

    @Test func everyFailureAndACancelLeaveNoStagingFolderAndTheInstalledAppUnchanged() async throws {
        let directory = try scratch()
        let installed = try makeApp(in: directory.appendingPathComponent("Applications", isDirectory: true), version: "1.1.0")
        let good = directory.appendingPathComponent("good")
        let archive = directory.appendingPathComponent("App-1.1.0.zip")
        try zip(installed, to: archive)
        try publish(archive, in: good)
        let before = try tree(installed)

        let probe = try await UpdateStager.stage(
            release(), installed: installed, runningVersion: "1.0.0", product: "App", repository: "me/app",
            fetch: fetch(from: good))
        let staging = probe.folder.deletingLastPathComponent()
        try FileManager.default.removeItem(at: probe.folder)
        let baseline = try FileManager.default.contentsOfDirectory(atPath: staging.path).sorted()

        let other = try makeApp(in: directory.appendingPathComponent("other", isDirectory: true), version: "1.1.0", marker: "b")
        let otherZip = directory.appendingPathComponent("other.zip")
        try zip(other, to: otherZip)
        let wrongSignature = directory.appendingPathComponent("wrong-signature")
        try publish(otherZip, as: "App-1.1.0.zip", in: wrongSignature)
        let wrongName = directory.appendingPathComponent("wrong-name")
        try publish(archive, in: wrongName, checksumName: "Other.zip")
        let evil = directory.appendingPathComponent("evil")
        try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: evil.appendingPathComponent("evil.txt"))
        let evilZip = directory.appendingPathComponent("evil.zip")
        try run("/usr/bin/ditto", ["-c", "-k", evil.path, evilZip.path])
        let unsafe = directory.appendingPathComponent("unsafe")
        try publish(evilZip, as: "App-1.1.0.zip", in: unsafe)

        func stage(_ remote: URL, running: String = "1.0.0") async -> UpdateFailure? {
            await failure {
                _ = try await UpdateStager.stage(
                    release(), installed: installed, runningVersion: running, product: "App", repository: "me/app",
                    fetch: fetch(from: remote))
            }
        }
        #expect(await stage(wrongName) == .checksumNamesOtherFile)
        #expect(await stage(unsafe) == .unsafeArchive)
        #expect(await stage(good, running: "1.1.0") == .notNewer)
        if case .signature = await stage(wrongSignature) {} else { Issue.record("a differently built app must fail its signature") }

        let cancelled = Task {
            try await UpdateStager.stage(
                release(), installed: installed, runningVersion: "1.0.0", product: "App", repository: "me/app",
                fetch: { _, _ in try await Task.sleep(for: .seconds(60)); return directory })
        }
        cancelled.cancel()
        #expect(await failure { _ = try await cancelled.value } == .cancelled)

        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).sorted() == baseline)
        #expect(try tree(installed) == before)
    }

    @Test func addressesOutsideTheRepositoryAreNeverRequested() async throws {
        let installed = try makeApp(in: try scratch(), version: "1.1.0", sign: false)
        var offered = release()
        offered = Release(version: offered.version, url: offered.url, notes: "",
                          zip: URL(string: "https://github.com/other/app/releases/download/v1/App.zip"), checksum: offered.checksum)
        let problem = await failure {
            _ = try await UpdateStager.stage(
                offered, installed: installed, runningVersion: "1.0.0", product: "App", repository: "me/app",
                fetch: { _, _ in Issue.record("requested"); throw CancellationError() })
        }
        #expect(problem == .addressNotAllowed)
        let none = Release(version: "1.1.0", url: offered.url, notes: "", zip: nil, checksum: nil)
        let missing = await failure {
            _ = try await UpdateStager.stage(none, installed: installed, runningVersion: "1.0.0", product: "App", repository: "me/app")
        }
        #expect(missing == .missingAsset)
    }

    @Test func downloadingAFileReportsGrowingProgressUpToItsSize() async throws {
        let directory = try scratch()
        let source = directory.appendingPathComponent("source.bin")
        let content = Data(repeating: 7, count: 3 << 20)
        try content.write(to: source)
        let written = Box<Int64>()
        let got = try await Downloader.download(source) { bytes, _ in written.append(bytes) }
        #expect(written.values.last == Int64(content.count))
        #expect(written.values == written.values.sorted())
        #expect(try ModelInstaller.sha256(of: got) == ModelInstaller.sha256(of: source))
        try FileManager.default.removeItem(at: got)
    }

    /// Needs the signed release zips: set TABIEUM_RELEASE_ZIPS to a folder holding Tabieum-0.4.1.zip and Tabieum-0.4.2.zip.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TABIEUM_RELEASE_ZIPS"] != nil))
    func theRealReleaseIsAcceptedAndAnAdHocBuildOfItIsNot() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TABIEUM_RELEASE_ZIPS"] ?? "")
        let directory = try scratch()
        let applications = directory.appendingPathComponent("Applications")
        try run("/usr/bin/ditto", ["-x", "-k", folder.appendingPathComponent("Tabieum-0.4.1.zip").path, applications.path])
        let installed = applications.appendingPathComponent("Tabieum.app")
        let release = Release(
            version: "0.4.2", url: URL(string: "https://github.com/juhyeonni/tabieum/releases/tag/v0.4.2")!, notes: "",
            zip: URL(string: "https://github.com/juhyeonni/tabieum/releases/download/v0.4.2/Tabieum-0.4.2.zip")!,
            checksum: URL(string: "https://github.com/juhyeonni/tabieum/releases/download/v0.4.2/Tabieum-0.4.2.zip.sha256")!)

        let real = directory.appendingPathComponent("real")
        try publish(folder.appendingPathComponent("Tabieum-0.4.2.zip"), as: "Tabieum-0.4.2.zip", in: real)
        let staged = try await UpdateStager.stage(
            release, installed: installed, runningVersion: "0.4.1", product: "Tabieum", repository: "juhyeonni/tabieum",
            fetch: fetch(from: real))
        let quarantine = Process()
        quarantine.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        quarantine.arguments = ["-p", "com.apple.quarantine", staged.app.path]
        quarantine.standardError = FileHandle.nullDevice
        try quarantine.run()
        quarantine.waitUntilExit()
        print("quarantine attribute on the staged app: \(quarantine.terminationStatus == 0 ? "present" : "absent")")
        try FileManager.default.removeItem(at: staged.folder)

        let adHoc = directory.appendingPathComponent("adhoc/Tabieum.app")
        try FileManager.default.createDirectory(at: adHoc.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", folder.appendingPathComponent("Tabieum-0.4.2.zip").path, adHoc.deletingLastPathComponent().path])
        try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", adHoc.path])
        let forged = directory.appendingPathComponent("forged")
        let forgedZip = directory.appendingPathComponent("Tabieum-0.4.2.zip")
        try zip(adHoc, to: forgedZip)
        try publish(forgedZip, as: "Tabieum-0.4.2.zip", in: forged)
        let problem = await failure {
            _ = try await UpdateStager.stage(
                release, installed: installed, runningVersion: "0.4.1", product: "Tabieum", repository: "juhyeonni/tabieum",
                fetch: fetch(from: forged))
        }
        if case .signature = problem {} else { Issue.record("an ad-hoc build must fail its signature, got \(String(describing: problem))") }
    }
}
