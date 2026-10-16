import Foundation
import Testing
@testable import NotesCore

private final class FakeNotes: NoteSource, @unchecked Sendable {
    var notes: [String: Note] = [:]

    func set(_ id: String, title: String, body: String, modified: Double = 1) {
        notes[id] = Note(id: id, title: title, folderID: "f1", created: Date(timeIntervalSinceReferenceDate: 0),
                         modified: Date(timeIntervalSinceReferenceDate: modified), snippet: nil, body: Data(body.utf8))
    }

    func noteStamps() throws -> [NoteStamp] { notes.values.map { NoteStamp(id: $0.id, modified: $0.modified) } }
    func notes(ids: [String]) throws -> [Note] { ids.compactMap { notes[$0] } }
    func folders() throws -> [Folder] { [Folder(id: "f1", name: "Work", accountID: "a", parentID: nil)] }
    func attachmentLinkTargets(ids: [String]) throws -> [String: String] { [:] }
}

/// Texts mentioning a car or an automobile share one direction; everything else is orthogonal.
private final class StubEmbedder: Embedder, @unchecked Sendable {
    let model: String
    nonisolated(unsafe) var embedded: [String] = []

    init(model: String = "stub") { self.model = model }

    func modelID(for text: String) -> String? { model }
    func isReady(_ modelID: String) -> Bool { true }
    func embed(_ text: String, modelID: String) throws -> [Float] {
        embedded.append(text)
        return text.contains("car") || text.contains("automobile") ? [1, 0] : [0, 1]
    }
}

private func plain(_ data: Data) throws -> String { String(decoding: data, as: UTF8.self) }

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite")
}

private func chunks(_ title: String, _ markdown: String) -> [Chunk] {
    Chunker.chunks(noteID: "n", title: title, markdown: markdown, modified: Date(timeIntervalSinceReferenceDate: 1))
}

@Suite struct RAGTests {
    @Test func sectionsBecomeChunksWithHeadingPaths() {
        let result = chunks("Trip", "# Trip\nintro\n## Food\nramen\n### Soup\nmiso\n## Sights\ntemple")
        #expect(result.map(\.path) == ["Trip", "Trip › Food", "Trip › Food › Soup", "Trip › Sights"])
        #expect(result.map(\.text) == ["intro", "ramen", "miso", "temple"])
        #expect(result.map(\.position) == [0, 1, 2, 3])
    }

    @Test func noteWithoutHeadingsUsesTitleAsPath() {
        let result = chunks("Plain", "just text\nmore text")
        #expect(result.map(\.path) == ["Plain"])
        #expect(result.map(\.text) == ["just text\nmore text"])
    }

    @Test func longSectionSplitsAtWhitespaceWithOverlap() {
        let words = (0..<200).map { "word\($0)" }.joined(separator: " ")
        let result = chunks("Long", words).map(\.text)
        #expect(result.count > 1)
        #expect(result.allSatisfy { $0.count <= 300 })
        for (previous, next) in zip(result, result.dropFirst()) {
            #expect(next.hasPrefix(String(previous.suffix(50))))
        }
        #expect(result.dropLast().allSatisfy { words.contains($0 + " ") })
    }

    @Test func fusionOrdersByReciprocalRank() {
        let fused = SearchIndex.reciprocalRankFusion([["a", "b", "c"], ["c", "d", "a"]])
        #expect(fused == ["a", "c", "b", "d"])
    }

    @Test func noteInOneListStillAppears() {
        #expect(SearchIndex.reciprocalRankFusion([["a"], ["b"]]) == ["a", "b"])
    }

    @Test func noVectorsKeepsFullTextOrder() throws {
        let source = FakeNotes()
        source.set("body", title: "Groceries", body: "remember the budget")
        source.set("title", title: "Budget", body: "plan")
        let index = try SearchIndex(url: tempURL())
        try index.sync(from: source, decode: plain)
        let hybrid = try index.hybridSearch("budget", embedder: StubEmbedder())
        let fullText = try index.search("budget").map(\.id)
        #expect(hybrid.map(\.note.id) == fullText)
    }

    @Test func similarVectorFindsNoteWithoutSharedWord() throws {
        let source = FakeNotes()
        source.set("a", title: "Garage", body: "## Repairs\ncar needs new brakes")
        source.set("b", title: "Recipes", body: "soup")
        let index = try SearchIndex(url: tempURL())
        try index.sync(from: source, decode: plain, embedder: { StubEmbedder() })
        let hybrid = try index.hybridSearch("automobile", embedder: StubEmbedder())
        #expect(hybrid.first?.note.id == "a")
        #expect(hybrid.first?.headingPath == "Garage › Repairs")
        #expect(hybrid.first?.chunkText == "car needs new brakes")
    }

    @Test func vectorsOfAnotherModelAreNotCompared() throws {
        let source = FakeNotes()
        source.set("a", title: "Garage", body: "car needs new brakes")
        let index = try SearchIndex(url: tempURL())
        try index.sync(from: source, decode: plain, embedder: { StubEmbedder(model: "one") })
        #expect(try index.hybridSearch("automobile", embedder: StubEmbedder(model: "two")).isEmpty)
        #expect(try index.hybridSearch("automobile", embedder: StubEmbedder(model: "one")).map(\.note.id) == ["a"])
    }

    @Test func onlyChangedNoteIsReembeddedAndDeletedNoteLosesChunks() throws {
        let source = FakeNotes()
        source.set("a", title: "one", body: "alpha")
        source.set("b", title: "two", body: "beta")
        let index = try SearchIndex(url: tempURL())
        try index.sync(from: source, decode: plain, embedder: { StubEmbedder() })
        let embedder = StubEmbedder()
        source.set("b", title: "two", body: "gamma", modified: 2)
        try index.sync(from: source, decode: plain, embedder: { embedder })
        #expect(embedder.embedded == ["two\ngamma"])
        source.notes["a"] = nil
        try index.sync(from: source, decode: plain, embedder: { embedder })
        #expect(try index.chunkCount(noteID: "a") == 0)
        #expect(try index.chunkCount(noteID: "b") == 1)
    }

    @Test func ragOffWritesNoChunksAndCreatesNoEmbedder() throws {
        let source = FakeNotes()
        source.set("a", title: "one", body: "alpha")
        let index = try SearchIndex(url: tempURL())
        nonisolated(unsafe) var created = 0
        let off: (() -> Embedder)? = false ? { created += 1; return StubEmbedder() } : nil
        try index.sync(from: source, decode: plain, embedder: off)
        #expect(created == 0)
        #expect(try index.chunkCount() == 0)
    }

    @Test func turningRagOffDeletesAllChunks() throws {
        let source = FakeNotes()
        source.set("a", title: "one", body: "alpha")
        let index = try SearchIndex(url: tempURL())
        try index.sync(from: source, decode: plain, embedder: { StubEmbedder() })
        #expect(try index.chunkCount() == 1)
        try index.sync(from: source, decode: plain, embedder: nil)
        #expect(try index.chunkCount() == 0)
    }

    @Test func pausedEmbeddingResumes() throws {
        let source = FakeNotes()
        source.set("a", title: "one", body: "alpha")
        let index = try SearchIndex(url: tempURL())
        #expect(try index.sync(from: source, decode: plain, embedder: { StubEmbedder() }, shouldPause: { true }) == .paused)
        #expect(try index.chunkCount() == 0)
        #expect(try index.sync(from: source, decode: plain, embedder: { StubEmbedder() }, shouldPause: { false }) == .finished)
        #expect(try index.chunkCount() == 1)
    }
}
