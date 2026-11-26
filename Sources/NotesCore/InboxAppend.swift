import Combine
import Foundation

/// Writes to Notes for the person typing; unlike `NoteWriter` it is not gated by the AI agent settings.
public protocol InboxWriter: Sendable {
    /// False when no note has this title.
    func append(html: String, toNoteTitled title: String) async throws -> Bool
    func createNote(titled title: String, html: String) async throws
    /// Brings Notes to the front on the note; false when no note has this title.
    func showNote(titled title: String) async throws -> Bool
}

/// The one-line input: nothing is written until `submit` or `open`.
@MainActor
public final class AppendModel: ObservableObject {
    @Published public var text: String
    @Published public private(set) var error: String?
    public let title: String
    public let openShortcut: String?
    private let writer: InboxWriter

    public init(text: String = "", title: String, openShortcut: String? = nil, writer: InboxWriter) {
        self.text = text
        self.title = title.allSatisfy(\.isWhitespace) ? "Inbox" : title
        self.openShortcut = openShortcut
        self.writer = writer
    }

    public var caption: String {
        let adds = "Adds to \"\(title)\""
        guard let openShortcut else { return adds }
        return "\(adds) · \(openShortcut) again to open"
    }

    private var isBlank: Bool { text.allSatisfy(\.isWhitespace) }

    /// True when the line was written.
    public func submit() async -> Bool {
        guard !isBlank else { return false }
        return await attempt { try await self.appendLine() }
    }

    /// Appends any typed line, then shows the Inbox note, creating it when missing. True when the note was shown.
    public func open() async -> Bool {
        await attempt {
            if !self.isBlank { try await self.appendLine() }
            if try await self.writer.showNote(titled: self.title) { return }
            try await self.writer.createNote(titled: self.title, html: "")
            _ = try await self.writer.showNote(titled: self.title)
        }
    }

    private func appendLine() async throws {
        let html = NoteHTML.line(text)
        if try await !writer.append(html: html, toNoteTitled: title) {
            try await writer.createNote(titled: title, html: html)
        }
    }

    private func attempt(_ work: () async throws -> Void) async -> Bool {
        do {
            try await work()
            error = nil
            return true
        } catch WriteFailure.automationDenied {
            error = "Allow Tabieum to control Notes under Automation in System Settings."
        } catch let failure {
            error = "Notes could not take the line: \(failure)"
        }
        return false
    }
}
