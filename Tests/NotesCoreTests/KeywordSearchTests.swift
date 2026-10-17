import Foundation
import Testing
@testable import NotesCore

private func index(_ notes: [(String, String, String)]) throws -> SearchIndex {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite")
    let index = try SearchIndex(url: url)
    let modified = Date(timeIntervalSinceReferenceDate: 100)
    try index.upsert(notes.map { IndexedNote(id: $0.0, title: $0.1, folder: "Home", modified: modified, body: $0.2, owner: "") })
    return index
}

@Test func notesWithEveryWordComeBeforeNotesWithSome() throws {
    let found = try index([
        ("some", "Groceries", "milk and eggs"),
        ("all", "Plan", "buy milk and bread today"),
    ]).search("milk bread")
    #expect(found.map(\.id) == ["all", "some"])
}

@Test func aSentenceFindsNotesThatHaveOnlySomeOfItsWords() throws {
    let found = try index([("a", "Dentist", "teeth cleaning on thursday")]).search("when is my teeth cleaning appointment")
    #expect(found.map(\.id) == ["a"])
}

@Test func oneLetterWordsDoNotWidenTheSearch() throws {
    let found = try index([("a", "Note", "a b c")]).search("zzz a")
    #expect(found.isEmpty)
}

@Test func aKoreanWordWithAnEndingFindsItsStem() throws {
    let notes = [("run", "러닝", "아침마다 조깅 5km"), ("other", "카레", "양파를 볶는다")]
    #expect(try index(notes).search("조깅했던").map(\.id) == ["run"])
    #expect(try index(notes).search("조깅했던 기록").map(\.id) == ["run"])
}

@Test func stemsOfKoreanWordsAreOnlyAsShortAsTwoLetters() {
    #expect(SearchIndex.spellings("조깅했던") == ["\"조깅했던\"*", "\"조깅했\"*", "\"조깅\"*"])
    #expect(SearchIndex.spellings("병원") == ["\"병원\"*"])
    #expect(SearchIndex.spellings("아파서") == ["\"아파서\"*", "\"아파\"*"])
    #expect(SearchIndex.spellings("dentist") == ["\"dentist\"*"])
}

@Test func aQuoteInTheQueryStaysInsideTheTerm() throws {
    let found = try index([("a", "Note", "plain text")]).search("\"plain\" OR")
    #expect(found.isEmpty || found.allSatisfy { $0.id == "a" })
}

@Test func panelSearchCapsNotesFoundOnlyByMeaning() throws {
    struct Everything: Embedder {
        func modelID(for text: String) -> String? { "stub" }
        func isReady(_ modelID: String) -> Bool { true }
        func embed(_ text: String, modelID: String) throws -> [Float] { [1, 0] }
    }
    let notes = (1...25).map { ("n\($0)", "Note \($0)", "body \($0)") }
    let index = try index(notes)
    let modified = Date(timeIntervalSinceReferenceDate: 100)
    for note in notes {
        let chunk = Chunk(noteID: note.0, path: note.1, position: 0, modified: modified, text: note.2)
        try index.replaceChunks(noteID: note.0, with: [StoredChunk(chunk: chunk, model: "stub", vector: [1, 0])])
    }
    let hits = try index.panelSearch("unrelated", embedder: Everything())
    #expect(hits.count == 20 && hits.allSatisfy(\.byMeaningOnly))
}
