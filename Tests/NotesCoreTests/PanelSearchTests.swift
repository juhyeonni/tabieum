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
    #expect(try index.panelSearch("automobile", embedder: nil).map(\.id) == ["car"])
}

@Test func panelSearchWithAnEmbedderAlsoFindsByMeaning() throws {
    let index = try fixture()
    #expect(try index.panelSearch("car", embedder: CarEmbedder()).map(\.id) == ["car"])
}

@Test func panelSearchKeepsWordHitsWhenTheEmbedderHasNoVectors() throws {
    let index = try fixture()
    let silent = CarEmbedder()
    #expect(try index.panelSearch("kilometres", embedder: silent).map(\.id).contains("run"))
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
