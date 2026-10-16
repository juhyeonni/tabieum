import Accelerate
import Foundation
import NaturalLanguage
import SQLite3

public struct Chunk: Equatable, Sendable {
    public let noteID: String
    public let path: String
    public let position: Int
    public let modified: Date
    public let text: String

    var embeddedText: String { [path, text].filter { !$0.isEmpty }.joined(separator: "\n") }
}

public enum Chunker {
    static let maxLength = 300
    static let overlap = 50

    /// One chunk per Markdown section; a section over `maxLength` characters is cut at whitespace with `overlap` characters shared.
    public static func chunks(noteID: String, title: String, markdown: String, modified: Date) -> [Chunk] {
        var sections: [(path: String, text: String)] = []
        var stack: [(level: Int, text: String)] = []
        var lines: [Substring] = []
        var inFence = false

        func flush() {
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            lines = []
            guard !text.isEmpty else { return }
            sections.append((([title] + stack.map(\.text)).joined(separator: " › "), text))
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") { inFence.toggle() }
            guard !inFence, let (level, text) = heading(line) else {
                lines.append(line)
                continue
            }
            flush()
            if level == 1 && text == title {
                stack = []
                continue
            }
            while let last = stack.last, last.level >= level { stack.removeLast() }
            stack.append((level, text))
        }
        flush()
        if sections.isEmpty, !title.isEmpty { sections = [(title, "")] }

        let pieces = sections.flatMap { section in split(section.text).map { (section.path, $0) } }
        return pieces.enumerated().map { Chunk(noteID: noteID, path: $1.0, position: $0, modified: modified, text: $1.1) }
    }

    private static func heading(_ line: Substring) -> (Int, String)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
        return (level, line.dropFirst(level).trimmingCharacters(in: .whitespaces))
    }

    static func split(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count > maxLength else { return [text] }
        var result: [String] = []
        var start = 0
        while true {
            let end = start + maxLength
            if end >= characters.count {
                result.append(String(characters[start...]))
                return result
            }
            let cut = (start + overlap + 1...end).reversed().first { characters[$0].isWhitespace } ?? end
            result.append(String(characters[start..<cut]))
            start = cut - overlap
        }
    }
}

public protocol Embedder: Sendable {
    /// The identifier of the model that embeds `text`, or nil when no model covers it.
    func modelID(for text: String) -> String?
    /// Whether the model's assets are on this Mac.
    func isReady(_ modelID: String) -> Bool
    /// An L2-normalized vector.
    func embed(_ text: String, modelID: String) throws -> [Float]
}

enum Vector {
    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vDSP.sum(vDSP.square(vector)).squareRoot()
        return norm > 0 ? vDSP.divide(vector, norm) : vector
    }

    static func data(_ vector: [Float]) -> Data {
        vector.withUnsafeBytes { Data($0) }
    }
}

/// Apple's on-device `NLContextualEmbedding`. The model follows the text's dominant language; token vectors are mean-pooled.
public final class AppleEmbedder: Embedder, @unchecked Sendable {
    private let lock = NSLock()
    private var byLanguage: [NLLanguage: NLContextualEmbedding] = [:]
    private var byID: [String: NLContextualEmbedding] = [:]
    private var loaded: Set<String> = []

    public init() {}

    public func modelID(for text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let language = recognizer.dominantLanguage ?? .english
        lock.lock()
        defer { lock.unlock() }
        if let model = byLanguage[language] { return model.modelIdentifier }
        guard let model = NLContextualEmbedding(language: language) else { return nil }
        byLanguage[language] = model
        byID[model.modelIdentifier] = model
        return model.modelIdentifier
    }

    public func isReady(_ modelID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return byID[modelID]?.hasAvailableAssets ?? false
    }

    public func embed(_ text: String, modelID: String) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard let model = byID[modelID] else { throw SQLiteError(message: "unknown model \(modelID)", code: 0) }
        if loaded.insert(modelID).inserted { try model.load() }
        let result = try model.embeddingResult(for: text, language: nil)
        var sum = [Float](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for i in 0..<min(vector.count, sum.count) { sum[i] += Float(vector[i]) }
            count += 1
            return true
        }
        guard count > 0 else { throw SQLiteError(message: "no token vectors", code: 0) }
        return Vector.normalized(sum)
    }

    /// Asks macOS to download the models for the user's languages and English.
    public static func requestAssets() async {
        let languages = Set(Locale.preferredLanguages.map { NLLanguage(Locale(identifier: $0).language.languageCode?.identifier ?? $0) } + [.english])
        for language in languages {
            guard let model = NLContextualEmbedding(language: language), !model.hasAvailableAssets else { continue }
            _ = try? await model.requestAssets()
        }
    }
}

public struct EmbeddingProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int
    public var waitingForModel: Bool
}

public enum EmbedOutcome: Equatable, Sendable {
    case finished, paused, waitingForModel
}

public struct HybridResult: Equatable, Sendable {
    public let note: SearchResult
    /// The note's best-matching chunk; nil when the note matched only by full text.
    public let chunkText: String?
    public let headingPath: String?
}

struct StoredChunk {
    let chunk: Chunk
    let model: String
    let vector: [Float]
}

extension SearchIndex {
    /// Embeds notes whose chunks are missing or older than the note, in batches, until done, paused or waiting for the model.
    func embedPending(
        using embedder: Embedder,
        batchSize: Int = 20,
        shouldPause: () -> Bool,
        log: (String) -> Void,
        progress: (EmbeddingProgress) -> Void
    ) throws -> EmbedOutcome {
        let ids = try db.rows("""
            SELECT n.id FROM notes n
            WHERE NOT EXISTS (SELECT 1 FROM chunks c WHERE c.note_id = n.id AND c.modified = n.modified)
            """) { SQLiteConnection.text($0, 0) }
        var done = 0
        progress(EmbeddingProgress(done: 0, total: ids.count, waitingForModel: false))
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            if shouldPause() { return .paused }
            for id in ids[start..<min(start + batchSize, ids.count)] {
                guard let note = try noteForEmbedding(id) else { continue }
                var stored: [StoredChunk] = []
                var failed = false
                for chunk in Chunker.chunks(noteID: id, title: note.title, markdown: note.body, modified: note.modified) {
                    guard let model = embedder.modelID(for: chunk.embeddedText) else { continue }
                    guard embedder.isReady(model) else {
                        progress(EmbeddingProgress(done: done, total: ids.count, waitingForModel: true))
                        return .waitingForModel
                    }
                    do {
                        stored.append(StoredChunk(chunk: chunk, model: model,
                                                  vector: try embedder.embed(chunk.embeddedText, modelID: model)))
                    } catch {
                        log("cannot embed note \(id): \(error)")
                        failed = true
                        break
                    }
                }
                if !failed { try replaceChunks(noteID: id, with: stored) }
                done += 1
            }
            progress(EmbeddingProgress(done: done, total: ids.count, waitingForModel: false))
        }
        return .finished
    }

    private func noteForEmbedding(_ id: String) throws -> IndexedNote? {
        try db.rows("""
            SELECT n.id, f.title, f.body, n.modified FROM notes n JOIN notes_fts f ON f.rowid = n.rowid WHERE n.id = ?1
            """, [.text(id)]) {
            IndexedNote(id: SQLiteConnection.text($0, 0), title: SQLiteConnection.text($0, 1), folder: "",
                        modified: Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0, 3)),
                        body: SQLiteConnection.text($0, 2))
        }.first
    }

    func replaceChunks(noteID: String, with chunks: [StoredChunk]) throws {
        try db.transaction {
            try db.run("DELETE FROM chunks WHERE note_id = ?1", [.text(noteID)])
            for item in chunks {
                try db.run("""
                    INSERT INTO chunks(note_id, position, path, text, modified, model, vec) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                    """, [.text(noteID), .int(Int64(item.chunk.position)), .text(item.chunk.path), .text(item.chunk.text),
                          .real(item.chunk.modified.timeIntervalSinceReferenceDate), .text(item.model),
                          .blob(Vector.data(item.vector))])
            }
        }
    }

    func clearChunks() throws {
        try db.run("DELETE FROM chunks")
    }

    func chunkCount(noteID: String) throws -> Int {
        try db.rows("SELECT count(*) FROM chunks WHERE note_id = ?1", [.text(noteID)]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    func chunkCount() throws -> Int {
        try db.rows("SELECT count(*) FROM chunks") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    /// Reciprocal rank fusion (Cormack, Clarke and Büttcher, SIGIR 2009). Ties keep first-seen order.
    static func reciprocalRankFusion(_ rankings: [[String]], k: Double = 60) -> [String] {
        var scores: [String: Double] = [:]
        var order: [String] = []
        for ranking in rankings {
            for (offset, id) in ranking.enumerated() {
                if scores[id] == nil { order.append(id) }
                scores[id, default: 0] += 1 / (k + Double(offset + 1))
            }
        }
        return order.enumerated().sorted { (scores[$0.element]!, $1.offset) > (scores[$1.element]!, $0.offset) }.map(\.element)
    }

    private struct VectorHit {
        let noteID: String
        let path: String
        let text: String
        let score: Float
    }

    /// The best chunk per note by cosine similarity, over chunks of the query's own model only.
    private func vectorHits(_ query: String, embedder: Embedder, limit: Int) throws -> [VectorHit] {
        guard let model = embedder.modelID(for: query), embedder.isReady(model),
              let queryVector = try? embedder.embed(query, modelID: model) else { return [] }
        var best: [String: VectorHit] = [:]
        _ = try db.rows("SELECT note_id, path, text, vec FROM chunks WHERE model = ?1", [.text(model)]) { row -> Void in
            let blob = SQLiteConnection.blob(row, 3)
            guard blob.count == queryVector.count * MemoryLayout<Float>.size else { return }
            var score: Float = 0
            vDSP_dotpr(queryVector, 1, blob.baseAddress!.assumingMemoryBound(to: Float.self), 1, &score, vDSP_Length(queryVector.count))
            let id = SQLiteConnection.text(row, 0)
            guard score > best[id]?.score ?? -.infinity else { return }
            best[id] = VectorHit(noteID: id, path: SQLiteConnection.text(row, 1), text: SQLiteConnection.text(row, 2), score: score)
        }
        return best.values.sorted { ($0.score, $1.noteID) > ($1.score, $0.noteID) }.prefix(limit).map { $0 }
    }

    /// Fuses the top 50 notes of full-text search and of vector search by reciprocal rank fusion.
    /// With no comparable vectors the order is the full-text order.
    public func hybridSearch(_ query: String, embedder: Embedder?, limit: Int = 20) throws -> [HybridResult] {
        let text = try search(query, limit: 50)
        let vectors = try embedder.map { try vectorHits(query, embedder: $0, limit: 50) } ?? []
        let textByID = Dictionary(text.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let vectorByID = Dictionary(vectors.map { ($0.noteID, $0) }, uniquingKeysWith: { first, _ in first })
        var results: [HybridResult] = []
        for id in Self.reciprocalRankFusion([text.map(\.id), vectors.map(\.noteID)]) {
            let hit = vectorByID[id]
            guard let note = try textByID[id] ?? noteResult(id, snippet: hit.map { String($0.text.prefix(120)) } ?? "")
            else { continue }
            results.append(HybridResult(note: note, chunkText: hit?.text, headingPath: hit?.path))
            if results.count == limit { break }
        }
        return results
    }

    private func noteResult(_ id: String, snippet: String) throws -> SearchResult? {
        try db.rows("""
            SELECT n.id, f.title, f.folder, n.modified FROM notes n JOIN notes_fts f ON f.rowid = n.rowid WHERE n.id = ?1
            """, [.text(id)]) {
            SearchResult(id: SQLiteConnection.text($0, 0), title: SQLiteConnection.text($0, 1),
                         folder: SQLiteConnection.text($0, 2),
                         modified: Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0, 3)), snippet: snippet)
        }.first
    }
}
