import Combine
import Foundation

/// Writes to Notes for the person typing; unlike `NoteWriter` it is not gated by the AI agent settings.
public protocol InboxWriter: Sendable {
    /// False when no note has this title.
    func append(html: String, toNoteTitled title: String) async throws -> Bool
    func createNote(titled title: String, html: String) async throws
}

/// The one-line input: nothing is written until `submit`.
@MainActor
public final class AppendModel: ObservableObject {
    @Published public var text: String
    @Published public private(set) var error: String?
    public let title: String
    private let writer: InboxWriter

    public init(text: String = "", title: String, writer: InboxWriter) {
        self.text = text
        self.title = title.allSatisfy(\.isWhitespace) ? "Inbox" : title
        self.writer = writer
    }

    /// True when the line was written.
    public func submit() async -> Bool {
        guard !text.allSatisfy(\.isWhitespace) else { return false }
        let html = NoteHTML.line(text)
        do {
            if try await !writer.append(html: html, toNoteTitled: title) {
                try await writer.createNote(titled: title, html: html)
            }
            error = nil
            return true
        } catch WriteFailure.automationDenied {
            error = "Allow tabieum to control Notes under Automation in System Settings."
        } catch let failure {
            error = "Notes could not take the line: \(failure)"
        }
        return false
    }
}
