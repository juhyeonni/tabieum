import Foundation
import Testing
@testable import NotesCore

private struct EvalNote: Codable {
    let id: String
    let title: String
    let folder: String
    let body: String
}

private struct EvalBaseline: Codable {
    let keyword: SearchMetrics
    let hybrid: [String: SearchMetrics]
}

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

private func load<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(contentsOf: fixtures.appendingPathComponent(name)))
}

private func corpusIndex() throws -> SearchIndex {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite")
    let index = try SearchIndex(url: url)
    let notes = try load("search-eval-notes.json", as: [String: [EvalNote]].self)["notes"] ?? []
    try index.upsert(notes.map {
        IndexedNote(id: $0.id, title: $0.title, folder: $0.folder, modified: Date(timeIntervalSinceReferenceDate: 1), body: $0.body, owner: "")
    })
    return index
}

private func below(_ metrics: SearchMetrics, _ baseline: SearchMetrics) -> Bool {
    metrics.recallAt5 < baseline.recallAt5 - 1e-9 || metrics.mrr < baseline.mrr - 1e-9
}

/// An embedder is ready for the benchmark only when both the Korean and the English text have a model on this Mac.
private func isReadyForBothLanguages(_ embedder: Embedder) -> Bool {
    ["한국어로 쓴 문장입니다", "a sentence written in English"].allSatisfy {
        embedder.modelID(for: $0).map(embedder.isReady) ?? false
    }
}

@Suite struct SearchEvalTests {
    @Test func perfectRankingScoresOne() {
        let cases = [SearchEvalCase(query: "a", expected: ["x", "y"]), SearchEvalCase(query: "b", expected: ["z"])]
        let ranking = ["a": ["x", "y", "q"], "b": ["z"]]
        let metrics = SearchEval.metrics(cases) { ranking[$0] ?? [] }
        #expect(metrics == SearchMetrics(recallAt5: 1, mrr: 1))
    }

    @Test func missingNotesScoreZero() {
        let cases = [SearchEvalCase(query: "a", expected: ["x"])]
        let late = (0..<10).map { "o\($0)" } + ["x"]
        #expect(SearchEval.metrics(cases) { _ in late } == SearchMetrics(recallAt5: 0, mrr: 0))
    }

    @Test func recallCountsTop5AndMRRUsesFirstRank() {
        let cases = [SearchEvalCase(query: "a", expected: ["x", "y"])]
        let metrics = SearchEval.metrics(cases) { _ in ["o", "x", "o", "o", "o", "y"] }
        #expect(metrics == SearchMetrics(recallAt5: 0.5, mrr: 0.5))
    }

    @Test func queriesWithoutExpectedNotesAreLeftOut() {
        let cases = [SearchEvalCase(query: "a", expected: ["x"]), SearchEvalCase(query: "none", expected: [])]
        let metrics = SearchEval.metrics(cases) { _ in ["x"] }
        #expect(metrics == SearchMetrics(recallAt5: 1, mrr: 1))
    }

    @Test func fallingBelowTheBaselineIsCaught() {
        let today = SearchMetrics(recallAt5: 0.5, mrr: 0.5)
        #expect(!below(today, today))
        #expect(below(today, SearchMetrics(recallAt5: 0.51, mrr: 0.5)))
        #expect(below(today, SearchMetrics(recallAt5: 0.5, mrr: 0.51)))
    }

    @Test func panelModeReportsMetricsWithAndWithoutTheThreshold() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite")
        let index = try SearchIndex(url: url)
        let modified = Date(timeIntervalSinceReferenceDate: 1)
        try index.upsert([("a", "alpha"), ("b", "beta"), ("c", "gamma")].map {
            IndexedNote(id: $0.0, title: $0.0.uppercased(), folder: "", modified: modified, body: $0.1, owner: "")
        })
        let stub = ThresholdEmbedder()
        _ = try index.embedPending(using: stub, shouldPause: { false }, log: { _ in }, progress: { _ in })
        let cases = [SearchEvalCase(query: "alpha", expected: ["a"]), SearchEvalCase(query: "nothing", expected: [])]
        let report = try SearchEval.panelEvaluate(index, cases: cases, embedder: stub, threshold: 0.5)
        #expect(report.withoutThreshold.meaningOnlyOnNoAnswer == 3)
        #expect(report.withThreshold.meaningOnlyOnNoAnswer == 2)
        #expect(report.withThreshold.metrics == SearchMetrics(recallAt5: 1, mrr: 1))
        #expect(report.withoutThreshold.metrics == report.withThreshold.metrics)
        let chosen = try #require(try SearchEval.chooseThreshold(index, cases: cases, embedder: stub))
        #expect(chosen > 0 && chosen < 1)
    }

    @Test func eachReadyModelThresholdKeepsPanelMetricsAndDropsNoAnswerNotes() throws {
        let cases = try load("search-eval-cases.json", as: SearchEvalCases.self).cases
        let index = try corpusIndex()
        for embedder in [AppleEmbedder(), E5Embedder.standard()] as [Embedder] {
            guard isReadyForBothLanguages(embedder) else { continue }
            _ = try index.embedPending(using: embedder, shouldPause: { false }, log: { print($0) }, progress: { _ in })
            let chosen = try SearchEval.chooseThreshold(index, cases: cases, embedder: embedder)
            let label = chosen.map { "\($0)" } ?? "none"
            print("search eval panel threshold [\(embedder.fingerprint)]: \(label)")
            guard let chosen else { continue }
            let report = try SearchEval.panelEvaluate(index, cases: cases, embedder: embedder, threshold: chosen)
            print("search eval panel [\(embedder.fingerprint)]: \(report)")
            #expect(!below(report.withThreshold.metrics, report.withoutThreshold.metrics))
            #expect(report.withThreshold.meaningOnlyOnNoAnswer <= report.withoutThreshold.meaningOnlyOnNoAnswer)
        }
    }

    @Test func syntheticCorpusStaysAtTheRecordedBaseline() throws {
        let cases = try load("search-eval-cases.json", as: SearchEvalCases.self).cases
        let baseline = try load("search-eval-baseline.json", as: EvalBaseline.self)
        let index = try corpusIndex()
        let keyword = try SearchEval.evaluate(index, cases: cases).keyword
        print("search eval keyword: recall@5 \(keyword.recallAt5) MRR \(keyword.mrr)")
        #expect(!below(keyword, baseline.keyword), "keyword search fell below the baseline \(baseline.keyword)")

        let embedders: [Embedder] = [AppleEmbedder(), E5Embedder.standard()]
        for embedder in embedders {
            let fingerprint = embedder.fingerprint
            guard isReadyForBothLanguages(embedder) else {
                print("search eval hybrid skipped for \(fingerprint): model assets are not all installed")
                continue
            }
            let outcome = try index.embedPending(using: embedder, shouldPause: { false }, log: { print($0) }, progress: { _ in })
            #expect(outcome == .finished)
            let hybrid = try #require(try SearchEval.evaluate(index, cases: cases, embedder: embedder).hybrid)
            print("search eval hybrid [\(fingerprint)]: recall@5 \(hybrid.recallAt5) MRR \(hybrid.mrr)")
            guard let recorded = baseline.hybrid[fingerprint] else {
                print("search eval hybrid [\(fingerprint)]: no recorded baseline")
                continue
            }
            #expect(!below(hybrid, recorded), "hybrid search fell below the baseline \(recorded) for \(fingerprint)")
        }
    }
}

private final class ThresholdEmbedder: Embedder, @unchecked Sendable {
    func modelID(for text: String) -> String? { "stub@1" }
    func isReady(_ modelID: String) -> Bool { true }
    func embed(_ text: String, modelID: String) throws -> [Float] {
        text.contains("alpha") ? [1, 0] : text.contains("beta") ? [0.6, 0.8] : [0, 1]
    }
}
