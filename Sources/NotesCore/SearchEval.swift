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
}
