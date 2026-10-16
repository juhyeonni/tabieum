import Foundation
import Testing
@testable import NotesCore

private func result(_ id: String, path: String, text: String) -> HybridResult {
    HybridResult(note: SearchResult(id: id, title: "Note \(id)", folder: "", modified: Date(), snippet: "", ownerIdentifier: nil),
                 chunkText: text, headingPath: path)
}

private func sources(_ count: Int) -> [AskSource] {
    (1...count).map { AskSource(noteID: "n\($0)", title: "Note \($0)", headingPath: "Note \($0) › H", text: "t") }
}

// AC1
@Test func askNeedsAIAndRAG() {
    #expect(canAskNotes(aiOn: true, ragOn: true))
    #expect(!canAskNotes(aiOn: true, ragOn: false))
    #expect(!canAskNotes(aiOn: false, ragOn: true))
}

// AC2
@Test func sourcesKeepRankOrderAndStopAtBudget() {
    let results = (1...5).map { result("\($0)", path: "Note \($0) › H", text: String(repeating: "a", count: 1_500)) }
    let kept = askSources(from: results)
    #expect(kept.map(\.noteID) == ["1", "2"])
    #expect(kept.map(\.text.count).reduce(0, +) <= askSourceBudget)
    #expect(askSources(from: (1...9).map { result("\($0)", path: "p", text: "x") }).count == askSourceCount)
}

@Test func firstSourceIsCutToBudget() {
    let kept = askSources(from: [result("1", path: "p", text: String(repeating: "a", count: 9_000)), result("2", path: "p", text: "b")])
    #expect(kept.count == 1)
    #expect(kept[0].text.count == askSourceBudget)
}

// AC3
@Test func promptCarriesQuestionSourcesAndCiteInstruction() {
    let messages = askMessages(question: "When is the trip?", sources: [
        AskSource(noteID: "1", title: "Trip", headingPath: "Trip › Dates", text: "May 3"),
        AskSource(noteID: "2", title: "Work", headingPath: "Work › Plan", text: "Ship"),
    ])
    #expect(messages.map(\.role) == [.system, .user])
    #expect(messages[0].content.contains("[n]"))
    #expect(messages[1].content.contains("When is the trip?"))
    #expect(messages[1].content.contains("[1] Trip › Dates\nMay 3"))
    #expect(messages[1].content.contains("[2] Work › Plan\nShip"))
}

// AC4
@Test func citationsAreDeduplicatedInOrderAndBounded() {
    let cited = citedSources(in: "A [2] and B [1], again [2], bad [9].", sources: sources(3))
    #expect(cited.map(\.noteID) == ["n2", "n1"])
}
