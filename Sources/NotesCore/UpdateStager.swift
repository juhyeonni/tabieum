import Foundation
import Security

public struct StagedUpdate: Equatable, Sendable {
    public let app: URL
    public let folder: URL
}

public enum UpdateFailure: Error, Equatable {
    case missingAsset
    case addressNotAllowed
    case download(String)
    case checksumFileUnreadable
    case checksumNamesOtherFile
    case checksumMismatch
    case unsafeArchive
    case unpackFailed
    case appMissing
    case wrongBundle
    case wrongVersion
    case notNewer
    case signature(String)
    case replaceFailed(String)
    case cancelled
}

/// Fetches a release and decides whether it is the one offered and signed like the running app. The installed app is never touched.
public enum UpdateStager {
    public typealias Fetch = @Sendable (URL, @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL

    /// The staging folder sits on the installed app's volume, so the next step can swap by renaming. It is deleted on any failure.
    public static func stage(
        _ release: Release, installed: URL, runningVersion: String, product: String, repository: String,
        fetch: Fetch? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> StagedUpdate {
        guard let zip = release.zip, let checksum = release.checksum else { throw UpdateFailure.missingAsset }
        guard [zip, checksum].allSatisfy({ UpdateCheck.isReleaseAsset($0, repository: repository) }) else {
            throw UpdateFailure.addressNotAllowed
        }
        let folder = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed, create: true)
        do {
            let app = try await fetchAndVerify(
                release, zip: zip, checksum: checksum, into: folder, installed: installed,
                runningVersion: runningVersion, product: product, fetch: fetch ?? { try await Downloader.download($0, report: $1) },
                progress: progress)
            return StagedUpdate(app: app, folder: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw failure(from: error)
        }
    }

    private static func fetchAndVerify(
        _ release: Release, zip: URL, checksum: URL, into folder: URL, installed: URL,
        runningVersion: String, product: String, fetch: Fetch, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let sums = try await fetch(checksum) { _, _ in }
        defer { try? FileManager.default.removeItem(at: sums) }
        let archive = try await fetch(zip) { written, expected in
            if expected > 0 { progress(min(Double(written) / Double(expected), 1)) }
        }
        defer { try? FileManager.default.removeItem(at: archive) }

        try verifyChecksum(of: archive, named: zip.lastPathComponent, against: sums)
        try checkEntries(try listEntries(of: archive), product: product)
        try unpack(archive, into: folder)
        let app = folder.appendingPathComponent("\(product).app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateFailure.appMissing }
        let running = Bundle(url: installed)?.infoDictionary?["CFBundleIdentifier"] as? String
        try checkApp(app, bundleIdentifier: running, version: release.version, newerThan: runningVersion)
        try checkSignature(of: app, against: installed)
        return app
    }

    private static func failure(from error: Error) -> UpdateFailure {
        if let failure = error as? UpdateFailure { return failure }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        return .download(error.localizedDescription)
    }

    static func verifyChecksum(of archive: URL, named name: String, against checksumFile: URL) throws {
        guard let text = try? String(contentsOf: checksumFile, encoding: .utf8),
              let expected = UpdateCheck.parseChecksum(text)
        else { throw UpdateFailure.checksumFileUnreadable }
        guard expected.file == name else { throw UpdateFailure.checksumNamesOtherFile }
        guard try ModelInstaller.sha256(of: archive) == expected.digest else { throw UpdateFailure.checksumMismatch }
    }

    /// Every entry must lie inside `<product>.app/`, apart from a `__MACOSX/` resource folder.
    static func checkEntries(_ entries: [String], product: String) throws {
        guard !entries.isEmpty else { throw UpdateFailure.unsafeArchive }
        for entry in entries {
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let safe = !entry.hasPrefix("/") && !parts.contains("..") && [product + ".app", "__MACOSX"].contains(parts[0])
            guard safe else { throw UpdateFailure.unsafeArchive }
        }
    }

    static func checkApp(_ app: URL, bundleIdentifier: String?, version: String, newerThan running: String) throws {
        let info = Bundle(url: app)?.infoDictionary
        guard let bundleIdentifier, info?["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateFailure.wrongBundle
        }
        guard info?["CFBundleShortVersionString"] as? String == version else { throw UpdateFailure.wrongVersion }
        guard UpdateCheck.isNewer(version, than: running) else { throw UpdateFailure.notNewer }
    }

    /// Strict, all architectures and nested code, against the running app's own designated requirement. No network.
    static func checkSignature(of app: URL, against running: URL) throws {
        var runningCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(running as CFURL, [], &runningCode) == errSecSuccess, let runningCode,
              SecCodeCopyDesignatedRequirement(runningCode, [], &requirement) == errSecSuccess, let requirement
        else { throw UpdateFailure.signature("the running app has no signature to compare with") }
        var staged: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staged) == errSecSuccess, let staged else {
            throw UpdateFailure.signature("the new app cannot be read")
        }
        var error: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidityWithErrors(staged, flags, requirement, &error) == errSecSuccess else {
            throw UpdateFailure.signature(error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "invalid")
        }
    }

    private static func listEntries(of archive: URL) throws -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archive.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure.unsafeArchive }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private static func unpack(_ archive: URL, into folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, folder.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure.unpackFailed }
    }
}
