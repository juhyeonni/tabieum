import Foundation

public struct SearchEvalCase: Codable, Equatable, Sendable {
    public let query: String
    public let expected: [String]

    public init(query: String, expected: [String]) {
        self.query = query
        self.expected = expected
    }
}

public struct SearchEvalCases: Codable, Equatable, Sendable {
    public let cases: [SearchEvalCase]
}

public struct SearchMetrics: Codable, Equatable, Sendable {
    public let recallAt5: Double
    public let mrr: Double

    public init(recallAt5: Double, mrr: Double) {
        self.recallAt5 = recallAt5
        self.mrr = mrr
    }
}

public struct SearchEvalReport: Equatable, Sendable {
    public let keyword: SearchMetrics
    public let hybrid: SearchMetrics?
}

public struct PanelMetrics: Equatable, Sendable {
    public let metrics: SearchMetrics
    /// Average number of meaning-only notes in the top 5, over the queries that expect no note.
    public let meaningOnlyOnNoAnswer: Double
}

public struct PanelEvalReport: Equatable, Sendable {
    public let withoutThreshold: PanelMetrics
    public let withThreshold: PanelMetrics
}

public enum SearchEval {
    /// Averages recall@5 and MRR@10 over the cases that expect a note; the others are left out.
    public static func metrics(_ cases: [SearchEvalCase], ranked: (String) throws -> [String]) rethrows -> SearchMetrics {
        var recall = 0.0
        var reciprocal = 0.0
        var counted = 0.0
        for item in cases where !item.expected.isEmpty {
            let ids = try ranked(item.query)
            recall += Double(item.expected.filter { ids.prefix(5).contains($0) }.count) / Double(item.expected.count)
            reciprocal += ids.prefix(10).firstIndex { item.expected.contains($0) }.map { 1 / Double($0 + 1) } ?? 0
            counted += 1
        }
        guard counted > 0 else { return SearchMetrics(recallAt5: 0, mrr: 0) }
        return SearchMetrics(recallAt5: recall / counted, mrr: reciprocal / counted)
    }

    public static func evaluate(_ index: SearchIndex, cases: [SearchEvalCase], embedder: Embedder? = nil) throws -> SearchEvalReport {
        let keyword = try metrics(cases) { try index.search($0, limit: 10).map(\.id) }
        let hybrid = try embedder.map { embedder in
            try metrics(cases) { try index.hybridSearch($0, embedder: embedder, limit: 10).map(\.note.id) }
        }
        return SearchEvalReport(keyword: keyword, hybrid: hybrid)
    }

    /// The panel's recall@5, MRR and meaning-only count on no-answer queries, for one similarity threshold.
    public static func panelMetrics(_ index: SearchIndex, cases: [SearchEvalCase], embedder: Embedder, minSimilarity: Float?) throws -> PanelMetrics {
        func hits(_ query: String) throws -> [PanelHit] {
            try index.panelHits(query, embedder: embedder, limit: 10, minSimilarity: minSimilarity)
        }
        let recall = try metrics(cases) { try hits($0).map(\.note.id) }
        let noAnswer = cases.filter { $0.expected.isEmpty }
        let counts = try noAnswer.map { try hits($0.query).prefix(5).filter(\.byMeaningOnly).count }
        let average = noAnswer.isEmpty ? 0 : Double(counts.reduce(0, +)) / Double(noAnswer.count)
        return PanelMetrics(metrics: recall, meaningOnlyOnNoAnswer: average)
    }

    public static func panelEvaluate(_ index: SearchIndex, cases: [SearchEvalCase], embedder: Embedder, threshold: Float) throws -> PanelEvalReport {
        PanelEvalReport(
            withoutThreshold: try panelMetrics(index, cases: cases, embedder: embedder, minSimilarity: nil),
            withThreshold: try panelMetrics(index, cases: cases, embedder: embedder, minSimilarity: threshold))
    }

    /// The highest threshold in steps of 0.01 that keeps panel recall@5 and MRR at the no-threshold run, less `margin`
    /// against fitting a small set. Nil when no step keeps them, or the margin leaves nothing above zero.
    public static func chooseThreshold(_ index: SearchIndex, cases: [SearchEvalCase], embedder: Embedder, margin: Float = 0.05) throws -> Float? {
        let base = try panelMetrics(index, cases: cases, embedder: embedder, minSimilarity: nil).metrics
        var best: Float?
        for step in 1...99 {
            let candidate = Float(step) / 100
            let metrics = try panelMetrics(index, cases: cases, embedder: embedder, minSimilarity: candidate).metrics
            if metrics.recallAt5 >= base.recallAt5 - 1e-9 && metrics.mrr >= base.mrr - 1e-9 { best = candidate }
        }
        return best.map { $0 - margin }.flatMap { $0 > 0 ? $0 : nil }
    }
}
