import Foundation

/// `tabieum search <words> [--limit n] [--json]`: word search over the index, printed as JSON.
public enum SearchCommand {
    public static func run(arguments: [String], serverName: String, indexURL: URL) -> (output: String, exitCode: Int32) {
        guard let (words, limit) = parse(arguments) else {
            return (MCPServer.json(["error": "Usage: \(serverName) search <words> [--limit n] [--json]"]), 2)
        }
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return (MCPServer.json(["error": "No search index yet. Open \(serverName) and let it sync your notes first."]), 1)
        }
        do {
            let hits = try SearchIndex(url: indexURL, readOnly: true).search(words, limit: limit)
            return (MCPServer.json(["results": hits.map(MCPServer.fields)]), 0)
        } catch {
            return (MCPServer.json(["error": "The search index could not be read: \(error)"]), 1)
        }
    }

    private static func parse(_ arguments: [String]) -> (words: String, limit: Int)? {
        var words: [String] = []
        var limit = 10
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--json": continue
            case "--limit":
                guard let value = rest.popFirst().flatMap({ Int($0) }) else { return nil }
                limit = min(max(value, 1), 50)
            default: words.append(argument)
            }
        }
        let query = words.joined(separator: " ")
        return query.isEmpty ? nil : (query, limit)
    }
}
