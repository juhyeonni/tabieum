import Foundation

public struct AskSource: Equatable, Sendable {
    public let noteID: String
    public let title: String
    public let headingPath: String
    public let text: String
}

public let askSourceCount = 6
/// Ollama's default context is 4,096 tokens: the sources and the question must fit with room for the answer.
public let askSourceBudget = 4_000

public func canAskNotes(aiOn: Bool, ragOn: Bool) -> Bool { aiOn && ragOn }

/// Takes results in rank order until the budget is used up; the first source is always kept, cut to the budget.
public func askSources(from results: [HybridResult]) -> [AskSource] {
    var sources: [AskSource] = []
    var used = 0
    for result in results.prefix(askSourceCount) {
        let text = result.chunkText ?? result.note.snippet
        guard sources.isEmpty || used + text.count <= askSourceBudget else { break }
        let kept = String(text.prefix(askSourceBudget - used))
        used += kept.count
        sources.append(AskSource(noteID: result.note.id, title: result.note.title,
                                 headingPath: result.headingPath ?? result.note.title, text: kept))
    }
    return sources
}

public func askMessages(question: String, sources: [AskSource]) -> [ChatMessage] {
    let system = ChatMessage(role: .system, content: """
    Answer the question using only the numbered sources. Cite the sources you use as [n]. \
    If the sources do not contain the answer, say so. Reply in the language of the question.
    """)
    let list = sources.enumerated().map { "[\($0.offset + 1)] \($0.element.headingPath)\n\($0.element.text)" }
    let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
    return [system, ChatMessage(role: .user, content: "Sources:\n\n\(list.joined(separator: "\n\n"))\n\nQuestion: \(question)")]
}

/// The sources the answer cites by `[n]`, once each, in order of first appearance. Numbers outside the sources are ignored.
public func citedSources(in answer: String, sources: [AskSource]) -> [AskSource] {
    var seen: Set<Int> = []
    var cited: [AskSource] = []
    for match in answer.matches(of: /\[(\d+)\]/) {
        guard let n = Int(match.1), sources.indices.contains(n - 1), seen.insert(n).inserted else { continue }
        cited.append(sources[n - 1])
    }
    return cited
}
