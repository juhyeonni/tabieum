import CoreML
import Foundation
import Testing
@testable import NotesCore

private struct Reference: Decodable {
    let text: String
    let ids: [Int]
    let vector: [Float]
}

private func references() throws -> [Reference] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/e5-reference.json")
    return try JSONDecoder().decode([Reference].self, from: Data(contentsOf: url))
}

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func localSource(in directory: URL, packageSHA: String? = nil) throws -> ModelSource {
    let content = directory.appendingPathComponent("content")
    try FileManager.default.createDirectory(at: content.appendingPathComponent("m.mlpackage"), withIntermediateDirectories: true)
    try Data("weights".utf8).write(to: content.appendingPathComponent("m.mlpackage/weights.bin"))
    let archive = directory.appendingPathComponent("m.zip")
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-c", "-k", "--keepParent", content.appendingPathComponent("m.mlpackage").path, archive.path]
    try ditto.run()
    ditto.waitUntilExit()
    let tokenizer = directory.appendingPathComponent("tokenizer.json")
    try Data("{}".utf8).write(to: tokenizer)
    func file(_ url: URL, sha: String? = nil) throws -> ModelFile {
        ModelFile(name: url.lastPathComponent, url: url, sha256: try sha ?? ModelInstaller.sha256(of: url),
                  size: Int64(try Data(contentsOf: url).count))
    }
    return ModelSource(id: "test", revision: "r1", package: try file(archive, sha: packageSHA), tokenizer: [try file(tokenizer)])
}

private let fakeCompile: ModelInstaller.Compile = { package in
    let compiled = package.deletingLastPathComponent().appendingPathComponent("compiled.mlmodelc")
    try FileManager.default.copyItem(at: package, to: compiled)
    return compiled
}

struct E5EmbedderTests {
    @Test func shortInputIsPaddedWithAMaskOverTheTokens() {
        let (ids, mask) = E5Embedder.padded([0, 10, 11, 2])
        #expect(ids.count == 256 && mask.count == 256)
        #expect(Array(ids.prefix(5)) == [0, 10, 11, 2, 1])
        #expect(mask.reduce(0, +) == 4)
        #expect(mask[3] == 1 && mask[4] == 0)
    }

    @Test func longInputIsCutButKeepsTheClosingToken() {
        let (ids, mask) = E5Embedder.padded([0] + Array(repeating: 7, count: 400) + [2])
        #expect(ids.count == 256 && ids[255] == 2 && ids[254] == 7)
        #expect(mask.allSatisfy { $0 == 1 })
    }

    @Test func installedMeansTheModelAndTheTokenizerFilesExist() throws {
        let directory = try scratch()
        let store = ModelStore(directory: directory)
        let source = ModelSource.e5Small
        #expect(!store.isInstalled(source))
        for name in [ModelStore.compiledName] + source.tokenizer.map(\.name) {
            try Data().write(to: store.file(name))
        }
        #expect(store.isInstalled(source))
        store.remove()
        #expect(!store.isInstalled(source))
    }

    @Test func installerVerifiesCompilesAndPublishesTheModelOnce() async throws {
        let directory = try scratch()
        let source = try localSource(in: directory)
        let store = ModelStore(directory: directory.appendingPathComponent("models/test@r1"))
        let reported = OSAllocatedUnfairLockBox()
        try await ModelInstaller.install(source, into: store, compile: fakeCompile) { reported.append($0) }
        #expect(store.isInstalled(source))
        #expect(reported.values.last == 1)
        #expect(reported.values == reported.values.sorted())
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.deletingLastPathComponent().path)
        #expect(leftovers == ["test@r1"])
    }

    @Test func installerRefusesAFileWithTheWrongChecksumAndLeavesNothing() async throws {
        let directory = try scratch()
        let source = try localSource(in: directory, packageSHA: String(repeating: "0", count: 64))
        let store = ModelStore(directory: directory.appendingPathComponent("models/test@r1"))
        await #expect(throws: ModelDownloadError.self) {
            try await ModelInstaller.install(source, into: store, compile: fakeCompile) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("models").path)
        #expect(leftovers.isEmpty)
    }

    @Test func configuredEmbedderFollowsTheSettingOnEveryCall() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let configured = ConfiguredEmbedder(defaults: defaults, apple: Labeled("apple"), e5: Labeled("e5"))
        #expect(configured.fingerprint == "apple")
        defaults.set(EmbeddingModel.e5Small.rawValue, forKey: EmbeddingModel.defaultsKey)
        #expect(configured.fingerprint == "e5")
        defaults.set("unknown", forKey: EmbeddingModel.defaultsKey)
        #expect(configured.fingerprint == "apple")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TABIEUM_E5_DIR"] != nil))
    func realModelMatchesThePyTorchReference() async throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TABIEUM_E5_DIR"]!)
        let store = ModelStore(directory: try scratch())
        let compiled = try await MLModel.compileModel(at: source.appendingPathComponent("e5small_fp16_256.mlpackage"))
        try FileManager.default.moveItem(at: compiled, to: store.compiledModel)
        for name in ModelSource.e5Small.tokenizer.map(\.name) {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: store.file(name))
        }
        let embedder = E5Embedder(store: store, idleSeconds: 0.5)
        let id = try #require(embedder.modelID(for: ""))
        #expect(embedder.isReady(id))
        for reference in try references() {
            let kind: EmbeddingKind = reference.text.hasPrefix("query: ") ? .query : .passage
            let text = String(reference.text.drop { $0 != " " }.dropFirst())
            let ids = try embedder.tokenIDs(for: reference.text)
            #expect(E5Embedder.padded(ids).ids.prefix(reference.ids.count).map(Int.init) == reference.ids, "tokens of \(reference.text.prefix(30))")
            let vector = try embedder.embed(text, modelID: id, kind: kind)
            let cosine = zip(vector, reference.vector).map(*).reduce(0, +)
            #expect(cosine > 0.999, "vector of \(reference.text.prefix(30)): \(cosine)")
        }
        #expect(embedder.isLoaded)
        try await Task.sleep(for: .seconds(1.5))
        #expect(!embedder.isLoaded)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TABIEUM_E5_DIR"] != nil))
    func realFilesInstallThroughTheInstallerAndEmbed() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TABIEUM_E5_DIR"]!)
        let base = ProcessInfo.processInfo.environment["TABIEUM_E5_BASE_URL"].flatMap(URL.init(string:))
        func file(_ name: String) throws -> ModelFile {
            let url = directory.appendingPathComponent(name)
            return ModelFile(name: name, url: base?.appendingPathComponent(name) ?? url, sha256: try ModelInstaller.sha256(of: url),
                             size: Int64(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int))
        }
        let source = ModelSource(id: ModelSource.e5Small.id, revision: "local", package: try file("e5small-fp16-256.mlpackage.zip"),
                                 tokenizer: try ModelSource.e5Small.tokenizer.map { try file($0.name) })
        let store = ModelStore(directory: try scratch().appendingPathComponent("model"))
        try await ModelInstaller.install(source, into: store) { _ in }
        #expect(store.isInstalled(source))
        let embedder = E5Embedder(source: source, store: store)
        let vector = try embedder.embed("치과 예약", modelID: source.versionedID, kind: .query)
        #expect(vector.count == 384)
        #expect(abs(vector.map { $0 * $0 }.reduce(0, +) - 1) < 0.01)
    }
}

private final class Labeled: Embedder, @unchecked Sendable {
    let fingerprint: String
    init(_ fingerprint: String) { self.fingerprint = fingerprint }
    func modelID(for text: String) -> String? { fingerprint }
    func isReady(_ modelID: String) -> Bool { true }
    func embed(_ text: String, modelID: String) throws -> [Float] { [1] }
}

private final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    var values: [Double] { lock.withLock { stored } }
    func append(_ value: Double) { lock.withLock { stored.append(value) } }
}
