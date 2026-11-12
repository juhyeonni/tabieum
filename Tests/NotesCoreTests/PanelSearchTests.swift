import Foundation
import Testing
@testable import NotesCore

private final class CarEmbedder: Embedder, @unchecked Sendable {
    func modelID(for text: String) -> String? { "stub" }
    func isReady(_ modelID: String) -> Bool { true }
    func embed(_ text: String, modelID: String) throws -> [Float] {
        text.contains("car") || text.contains("automobile") ? [1, 0] : [0, 1]
    }
}

private func fixture() throws -> SearchIndex {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite")
    let index = try SearchIndex(url: url)
    let modified = Date(timeIntervalSinceReferenceDate: 100)
    try index.upsert([
        IndexedNote(id: "car", title: "Garage", folder: "Home", modified: modified, body: "my automobile", owner: ""),
        IndexedNote(id: "run", title: "Running", folder: "Home", modified: modified, body: "five kilometres", owner: ""),
    ])
    let chunk = Chunk(noteID: "car", path: "Garage", position: 0, modified: modified, text: "my automobile")
    try index.replaceChunks(noteID: "car", with: [StoredChunk(chunk: chunk, model: "stub", vector: [1, 0])])
    return index
}

@Test func panelSearchWithoutAnEmbedderIsWordSearchOnly() throws {
    let index = try fixture()
    #expect(try index.panelSearch("car", embedder: nil).isEmpty)
    #expect(try index.panelSearch("automobile", embedder: nil).map(\.note.id) == ["car"])
    #expect(try index.panelSearch("automobile", embedder: nil).allSatisfy { !$0.byMeaningOnly })
}

@Test func panelSearchWithAnEmbedderAlsoFindsByMeaning() throws {
    let index = try fixture()
    let hits = try index.panelSearch("car", embedder: CarEmbedder())
    #expect(hits.map(\.note.id) == ["car"] && hits.first?.byMeaningOnly == true)
}

@Test func panelSearchKeepsWordHitsWhenTheEmbedderHasNoVectors() throws {
    let index = try fixture()
    let silent = CarEmbedder()
    #expect(try index.panelSearch("kilometres", embedder: silent).map(\.note.id).contains("run"))
}

@Test func panelSearchDropsMeaningOnlyNotesBelowTheModelThreshold() throws {
    let index = try fixture()
    func ids(_ query: String, _ thresholds: [String: Float]) throws -> [String] {
        try index.panelSearch(query, embedder: CarEmbedder(), thresholds: thresholds).map(\.note.id)
    }
    #expect(try ids("car", ["stub": 0.5]) == ["car"])
    #expect(try ids("car", ["stub": 1.5]).isEmpty)
    #expect(try ids("car", [:]) == ["car"])
    #expect(try ids("car", ["other": 1.5]) == ["car"])
}

@Test func panelSearchKeepsNotesMatchedByWordsWhateverTheirSimilarity() throws {
    let index = try fixture()
    let hits = try index.panelSearch("garage", embedder: CarEmbedder(), thresholds: ["stub": 0.9])
    #expect(hits.map(\.note.id) == ["car"] && hits.first?.byMeaningOnly == false)
}

@Test func thresholdLookupIgnoresTheRevisionAfterAt() {
    let table: [String: Float] = ["e5-small": 0.8]
    #expect(SimilarityThreshold.lookup("e5-small@abc", in: table) == 0.8)
    #expect(SimilarityThreshold.lookup("e5-small", in: table) == 0.8)
    #expect(SimilarityThreshold.lookup("other@1", in: table) == nil)
    #expect(SimilarityThreshold.lookup(nil, in: table) == nil)
}

@Test func semanticPanelSearchIsOffByDefaultAndPersists() {
    let name = "test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let toggles = FeatureToggles(defaults: defaults)
    #expect(!toggles.semanticPanelSearch)
    toggles.semanticPanelSearch = true
    #expect(FeatureToggles(defaults: defaults).semanticPanelSearch)
}
