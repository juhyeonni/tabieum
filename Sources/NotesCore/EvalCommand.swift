import Foundation

/// `tabieum eval <file>`: recall@5 and MRR of search over the real index, for an eval file kept outside the repo.
public enum EvalCommand {
    public static func run(
        arguments: [String], serverName: String, indexURL: URL,
        ragEnabled: Bool, makeEmbedder: () -> Embedder
    ) -> (output: String, exitCode: Int32) {
        guard arguments.count == 1 else {
            return (MCPServer.json(["error": "Usage: \(serverName) eval <file>"]), 2)
        }
        let cases: [SearchEvalCase]
        do {
            let file = URL(fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath)
            cases = try JSONDecoder().decode(SearchEvalCases.self, from: Data(contentsOf: file)).cases
        } catch {
            return (MCPServer.json(["error": "The eval file could not be read: \(error)"]), 1)
        }
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return (MCPServer.json(["error": "No search index yet. Open \(serverName) and let it sync your notes first."]), 1)
        }
        do {
            let index = try SearchIndex(url: indexURL, readOnly: true)
            let useHybrid = try ragEnabled && index.chunkCount() > 0
            let report = try SearchEval.evaluate(index, cases: cases, embedder: useHybrid ? makeEmbedder() : nil)
            var output: [String: Any] = ["cases": cases.count, "keyword": fields(report.keyword)]
            output["hybrid"] = report.hybrid.map(fields)
            return (MCPServer.json(output), 0)
        } catch {
            return (MCPServer.json(["error": "The search index could not be read: \(error)"]), 1)
        }
    }

    private static func fields(_ metrics: SearchMetrics) -> [String: Double] {
        ["recall_at_5": metrics.recallAt5, "mrr": metrics.mrr]
    }
}
