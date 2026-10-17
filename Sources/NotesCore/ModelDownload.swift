import CoreML
import CryptoKit
import Foundation

public struct ModelFile: Equatable, Sendable {
    public let name: String
    public let url: URL
    public let sha256: String
    public let size: Int64
}

/// A model that is downloaded once and then runs on this Mac. Files are pinned to a commit and checked against their SHA-256.
public struct ModelSource: Equatable, Sendable {
    public let id: String
    public let revision: String
    public let package: ModelFile
    public let tokenizer: [ModelFile]

    public var versionedID: String { "\(id)@\(revision)" }
    public var files: [ModelFile] { [package] + tokenizer }
    public var downloadSize: Int64 { files.reduce(0) { $0 + $1.size } }

    public static let e5Small: ModelSource = {
        let revision = "088fcdfabeb40a23f12364c1fc1989f30a974aba"
        func file(_ name: String, _ sha256: String, _ size: Int64) -> ModelFile {
            ModelFile(name: name, url: URL(string: "https://huggingface.co/juhyeonni/tabieum-e5-small-coreml/resolve/\(revision)/\(name)")!,
                      sha256: sha256, size: size)
        }
        return ModelSource(
            id: "e5-small-coreml-fp16-256", revision: String(revision.prefix(8)),
            package: file("e5small-fp16-256.mlpackage.zip", "15db4628f7554c411c692f8414d8d12900daf630d3e0331ea69f812022252942", 216_819_697),
            tokenizer: [
                file("tokenizer.json", "0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39", 17_082_730),
                file("tokenizer_config.json", "a1d6bc8734a6f635dc158508bef000f8e2e5a759c7d92f984b2c86e5ff53425b", 443),
            ])
    }()
}

public struct ModelStore: Equatable, Sendable {
    public static let compiledName = "model.mlmodelc"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init(source: ModelSource, bundleIdentifier: String) {
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(bundleIdentifier)/models/\(source.versionedID)")
    }

    public var compiledModel: URL { directory.appendingPathComponent(Self.compiledName) }

    public func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    public func isInstalled(_ source: ModelSource) -> Bool {
        let names = [Self.compiledName] + source.tokenizer.map(\.name)
        return names.allSatisfy { FileManager.default.fileExists(atPath: file($0).path) }
    }

    public func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

public struct ModelDownloadError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public enum ModelInstaller {
    public typealias Compile = @Sendable (URL) async throws -> URL

    /// Downloads, verifies and compiles the model into `store`, which appears only when everything succeeded.
    public static func install(
        _ source: ModelSource, into store: ModelStore,
        compile: Compile = { try await MLModel.compileModel(at: $0) },
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let parent = store.directory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".installing-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let total = Double(max(source.downloadSize, 1))
        var finished: Int64 = 0
        for file in source.files {
            let base = finished
            let downloaded = try await Downloader.download(file.url) { progress((Double(base) + Double($0)) / total * 0.95) }
            defer { try? fileManager.removeItem(at: downloaded) }
            guard try sha256(of: downloaded) == file.sha256 else {
                throw ModelDownloadError(description: "\(file.name) does not match its checksum")
            }
            finished += file.size
            if file == source.package {
                try unzip(downloaded, into: staging)
            } else {
                try fileManager.moveItem(at: downloaded, to: staging.appendingPathComponent(file.name))
            }
        }
        let compiled = try await compile(try packageURL(in: staging))
        try fileManager.moveItem(at: compiled, to: staging.appendingPathComponent(ModelStore.compiledName))
        try? fileManager.removeItem(at: store.directory)
        try fileManager.moveItem(at: staging, to: store.directory)
        progress(1)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func unzip(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ModelDownloadError(description: "cannot unpack the model") }
    }

    private static func packageURL(in directory: URL) throws -> URL {
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard let package = items.first(where: { $0.pathExtension == "mlpackage" }) else {
            throw ModelDownloadError(description: "the download holds no model")
        }
        return package
    }
}

private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
    }

    static func download(_ url: URL, report: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let downloader = Downloader(report: report)
        let session = URLSession(configuration: .ephemeral, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            downloader.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            finish(.failure(ModelDownloadError(description: "the server answered \(status)")))
            return
        }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
