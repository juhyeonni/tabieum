import CoreGraphics
import Foundation

public enum AIAction: CaseIterable, Sendable {
    case rewrite, summarize, instruction, prompt
}

public enum AIPromptError: Error, Equatable {
    case tooLong
}

/// Ollama's default context is 4,096 tokens and the OpenAI-compatible API cannot raise it.
public let maxAISelectionLength = 4_000

public func availableAIActions(aiOn: Bool, hasSelection: Bool) -> [AIAction] {
    guard aiOn else { return [] }
    return hasSelection ? [.rewrite, .summarize, .instruction] : [.prompt]
}

/// A free prompt sends only the instruction; the other actions send the selection verbatim.
public func aiMessages(for action: AIAction, selection: String, instruction: String = "") throws -> [ChatMessage] {
    let system = ChatMessage(role: .system, content: """
    You are a writing assistant inside Apple Notes. Reply with plain text only, with no Markdown, \
    in the same language as the input. Reply with only the result: no preamble, no explanation.
    """)
    let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    if action == .prompt { return [system, ChatMessage(role: .user, content: instruction)] }
    guard selection.count <= maxAISelectionLength else { throw AIPromptError.tooLong }
    let task = switch action {
    case .rewrite: "Rewrite the text below to read better, keeping its meaning."
    case .summarize: "Summarize the text below."
    case .instruction, .prompt: ""
    }
    let lead = [task, instruction].filter { !$0.isEmpty }.joined(separator: "\n")
    return [system, ChatMessage(role: .user, content: "\(lead)\n\nText:\n\(selection)")]
}

/// Streams the provider's reply, or fails with `AIPromptError` without calling the provider.
public func aiResult(provider: any AIProvider, action: AIAction, selection: String, instruction: String = "") -> AsyncThrowingStream<String, Error> {
    do {
        return provider.chat(try aiMessages(for: action, selection: selection, instruction: instruction))
    } catch {
        return AsyncThrowingStream { $0.finish(throwing: error) }
    }
}

/// Removes a leading `<think>…</think>` block; an unclosed block is left as is.
public func strippingThinkBlock(_ text: String) -> String {
    let body = text.drop { $0.isWhitespace }
    guard body.hasPrefix("<think>"), let end = body.range(of: "</think>") else { return text }
    return String(body[end.upperBound...])
}

public enum InsertDecision: Equatable, Sendable {
    case write, refuse
}

/// Writes only into the focused Notes body, with the snapshot's text and selection restored.
public func insertDecision(notesFrontmost: Bool, bodyFocused: Bool, current: VimBuffer?, snapshot: VimBuffer) -> InsertDecision {
    notesFrontmost && bodyFocused && current == snapshot ? .write : .refuse
}

public struct HotKey: Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: CGEventFlags
    /// What the key is called in Settings.
    public var key: String

    public init(keyCode: UInt16, modifiers: CGEventFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    public static let aiDefault = HotKey(keyCode: 0, modifiers: [.maskControl, .maskAlternate, .maskCommand], key: "A")

    public static let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]

    /// Since macOS 15, shortcuts whose only modifiers are ⌥ or ⇧⌥ fail to register.
    public var isValid: Bool { !modifiers.isDisjoint(with: [.maskCommand, .maskControl]) }

    public func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        keyCode == self.keyCode && flags.intersection(Self.relevant) == modifiers
    }

    public var label: String {
        let symbols: [(CGEventFlags, String)] = [(.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")]
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + key
    }
}
