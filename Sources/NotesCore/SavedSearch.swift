import Foundation

public struct SavedSearch: Codable, Equatable, Sendable {
    public let name: String
    public let query: String

    public init(name: String, query: String) {
        self.name = name
        self.query = query
    }
}

extension Array where Element == SavedSearch {
    /// Saving under a name that exists replaces that search in place; a new name goes last.
    public mutating func save(_ search: SavedSearch) {
        guard let index = firstIndex(where: { $0.name == search.name }) else { return append(search) }
        self[index] = search
    }
}

extension SearchIndex {
    /// The panel's search for a query that may hold `in:` and `since:` words. With a condition it asks for 200 hits and
    /// filters them, so a match ranked below 200 is missed.
    public func conditionalPanelSearch(_ query: String, embedder: Embedder?, limit: Int = 50) throws -> [PanelHit] {
        let parsed = ParsedQuery(query)
        guard parsed.hasConditions else { return try panelSearch(query, embedder: embedder, limit: limit) }
        guard !parsed.words.allSatisfy(\.isWhitespace) else { return [] }
        let hits = try panelSearch(parsed.words, embedder: embedder, limit: 200)
        return Array(hits.filter { parsed.keeps($0.note) }.prefix(limit))
    }
}

/// A query with its `in:` and `since:` words taken out.
public struct ParsedQuery: Equatable, Sendable {
    public var words: String
    public var folder: String?
    public var days: Int?

    public var hasConditions: Bool { folder != nil || days != nil }

    public init(_ query: String) {
        var rest: [String] = []
        var folder: String?
        var days: Int?
        var scanner = query[...]
        while let token = Self.nextToken(&scanner) {
            if token.lowercased().hasPrefix("in:"), let value = Self.folderValue(token, &scanner) {
                folder = value
            } else if token.lowercased().hasPrefix("since:"), let value = Self.dayCount(token) {
                days = value
            } else {
                rest.append(token)
            }
        }
        words = rest.joined(separator: " ")
        self.folder = folder
        self.days = days
    }

    /// Keeps the hits in the folder and inside the day window.
    public func keeps(_ note: SearchResult, now: Date = Date()) -> Bool {
        if let folder, note.folder.caseInsensitiveCompare(folder) != .orderedSame { return false }
        guard let days else { return true }
        return note.modified >= now.addingTimeInterval(-Double(days) * 86400)
    }

    private static func nextToken(_ text: inout Substring) -> String? {
        text = text.drop(while: \.isWhitespace)
        guard !text.isEmpty else { return nil }
        let end = text.firstIndex(where: \.isWhitespace) ?? text.endIndex
        let token = String(text[..<end])
        text = text[end...]
        return token
    }

    /// `in:Work`, or `in:"Work Notes"`, whose quoted name runs on into the following words.
    private static func folderValue(_ token: String, _ rest: inout Substring) -> String? {
        var value = String(token.dropFirst(3))
        guard value.hasPrefix("\"") else { return value.isEmpty ? nil : value }
        value.removeFirst()
        while !value.hasSuffix("\"") {
            guard let next = nextToken(&rest) else { break }
            value += " " + next
        }
        if value.hasSuffix("\"") { value.removeLast() }
        return value.isEmpty ? nil : value
    }

    private static func dayCount(_ token: String) -> Int? {
        let value = token.dropFirst(6).lowercased()
        guard value.hasSuffix("d"), let days = Int(value.dropLast()), days > 0 else { return nil }
        return days
    }
}
