import Foundation

public struct NoteTarget: Hashable, Sendable {
    public let account: String
    public let folder: String

    public init(account: String, folder: String) {
        self.account = account
        self.folder = folder
    }
}

public enum WriteFailure: Error, Equatable, Sendable {
    case automationDenied
    case failed(String)
}

/// A note found in Notes, in the shape an edit needs to judge it.
public struct ResolvedNote: Equatable, Sendable {
    public let handle: String
    public let title: String
    public let folder: String
    public let modified: Date
    public let hasAttachments: Bool

    public init(handle: String, title: String, folder: String, modified: Date, hasAttachments: Bool) {
        self.handle = handle
        self.title = title
        self.folder = folder
        self.modified = modified
        self.hasAttachments = hasAttachments
    }
}

/// Writes into Notes itself; the real one sends Apple events, so tests use a fake.
public protocol NoteWriter: Sendable {
    func folderExists(_ target: NoteTarget) async throws -> Bool
    func createNote(title: String?, html: String, in target: NoteTarget) async throws
    /// The note with this database identifier, only if it is inside `scope`, not locked and in Notes; else nil.
    func resolveNote(identifier: String, scope: WriteScope, target: NoteTarget) async throws -> ResolvedNote?
    func replaceBody(of note: ResolvedNote, with html: String) async throws
    /// Moves the note to Recently Deleted, where the owner can restore it.
    func moveToTrash(_ note: ResolvedNote) async throws
}

public struct ConfirmRequest: Equatable, Sendable {
    public let action: WriteAction
    public let target: NoteTarget
    public let preview: String
}

/// Asks the owner. A task that is cancelled while waiting must stop asking.
public protocol WriteConfirmer: Sendable {
    func confirm(_ request: ConfirmRequest) async -> Bool
}

/// One socket connection, which is one `--mcp` process lifetime.
public final class WriteSession: @unchecked Sendable {
    private let lock = NSLock()
    private var granted: Set<WriteAction> = []

    public init() {}

    func isGranted(_ action: WriteAction) -> Bool {
        lock.withLock { granted.contains(action) }
    }

    func grant(_ action: WriteAction) {
        lock.withLock { _ = granted.insert(action) }
    }
}

/// Decides whether a write request from the `--mcp` process may reach Notes, and performs it.
public struct NoteWriteService: Sendable {
    let settings: @Sendable () -> WriteSettings
    let writer: NoteWriter
    let confirmer: WriteConfirmer
    let productName: String
    let timeout: Duration

    public init(
        settings: @escaping @Sendable () -> WriteSettings, writer: NoteWriter, confirmer: WriteConfirmer,
        productName: String, timeout: Duration = .seconds(60)
    ) {
        self.settings = settings
        self.writer = writer
        self.confirmer = confirmer
        self.productName = productName
        self.timeout = timeout
    }

    public static func socketURL(bundleIdentifier: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(bundleIdentifier)/write.sock")
    }

    /// The reply line for one request line. Always one JSON object.
    public func handle(_ line: String, session: WriteSession) async -> String {
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = (request["action"] as? String).flatMap(WriteAction.init(rawValue:))
        else { return Self.reply(error: "Not a valid write request.") }
        switch action {
        case .create:
            let title = (request["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let html = request["html"] as? String, title != nil || !html.isEmpty else {
                return Self.reply(error: "create needs an html body, or a title.")
            }
            return await create(title: title, html: html, session: session)
        case .edit:
            guard let id = request["id"] as? String, !id.isEmpty, let html = request["html"] as? String,
                  let expected = (request["expected_modified"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) })
            else { return Self.reply(error: "edit needs an id, an html body and an ISO 8601 expected_modified.") }
            return await edit(id: id, html: html, expectedModified: expected, session: session)
        case .delete:
            guard let id = request["id"] as? String, !id.isEmpty else { return Self.reply(error: "delete needs an id.") }
            return await delete(id: id, session: session)
        }
    }

    /// nil when the request may go on, else the reason it may not: the switches that apply to every action.
    private func gate(_ action: WriteAction, _ settings: WriteSettings) -> String? {
        guard settings.enabled else { return "Writing to Notes is off. Turn it on in \(productName) Settings." }
        guard settings.allowedActions.contains(action) else { return "\(action.rawValue.capitalized) is not allowed in \(productName) Settings." }
        guard settings.consent != .never else { return "The owner has set writing to Notes to never allow." }
        return nil
    }

    private func create(title: String?, html: String, session: WriteSession) async -> String {
        let settings = settings()
        if let refusal = gate(.create, settings) { return Self.reply(error: refusal) }
        guard !settings.targetFolder.isEmpty else { return Self.reply(error: "No target folder is chosen. Choose one in \(productName) Settings.") }
        let target = NoteTarget(account: settings.targetAccount, folder: settings.targetFolder)
        do {
            guard try await writer.folderExists(target) else {
                return Self.reply(error: "The target folder \"\(target.folder)\" does not exist in Notes. Choose another in \(productName) Settings.")
            }
            if let refusal = await consent(.create, target: target, preview: Self.preview(title: title, html: html), settings, session) {
                return Self.reply(error: refusal)
            }
            let body = settings.marker ? html + "<div>Created by an AI agent through \(productName).</div>" : html
            try await writer.createNote(title: title, html: body, in: target)
            return Self.reply(ok: true)
        } catch {
            return failureReply(error)
        }
    }

    private func edit(id: String, html: String, expectedModified: Date, session: WriteSession) async -> String {
        let settings = settings()
        if let refusal = gate(.edit, settings) { return Self.reply(error: refusal) }
        if settings.scope == .targetFolder, settings.targetFolder.isEmpty {
            return Self.reply(error: "No target folder is chosen. Choose one in \(productName) Settings.")
        }
        let target = NoteTarget(account: settings.targetAccount, folder: settings.targetFolder)
        do {
            guard let note = try await writer.resolveNote(identifier: id, scope: settings.scope, target: target) else {
                return Self.reply(error: "No note with that id can be edited.")
            }
            guard !note.hasAttachments else {
                return Self.reply(error: "This note has attachments, which an edit would remove, so it was not changed.")
            }
            guard abs(note.modified.timeIntervalSince(expectedModified)) <= 1.5 else {
                return Self.reply(error: "The note changed after it was read. Read it again, then retry the edit.")
            }
            let place = NoteTarget(account: "", folder: note.folder)
            if let refusal = await consent(.edit, target: place, preview: Self.preview(title: note.title, html: html), settings, session) {
                return Self.reply(error: refusal)
            }
            try await writer.replaceBody(of: note, with: html)
            return Self.reply(ok: true)
        } catch {
            return failureReply(error)
        }
    }

    private func delete(id: String, session: WriteSession) async -> String {
        let settings = settings()
        if let refusal = gate(.delete, settings) { return Self.reply(error: refusal) }
        if settings.scope == .targetFolder, settings.targetFolder.isEmpty {
            return Self.reply(error: "No target folder is chosen. Choose one in \(productName) Settings.")
        }
        let target = NoteTarget(account: settings.targetAccount, folder: settings.targetFolder)
        do {
            guard let note = try await writer.resolveNote(identifier: id, scope: settings.scope, target: target) else {
                return Self.reply(error: "No note with that id can be deleted.")
            }
            let place = NoteTarget(account: "", folder: note.folder)
            let preview = "\(note.title)\n\nThe note moves to Recently Deleted, where it can be restored."
            if let refusal = await consent(.delete, target: place, preview: preview, settings, session) { return Self.reply(error: refusal) }
            try await writer.moveToTrash(note)
            return Self.reply(ok: true)
        } catch {
            return failureReply(error)
        }
    }

    private func failureReply(_ error: Error) -> String {
        if case WriteFailure.automationDenied = error {
            return Self.reply(error: "\(productName) is not allowed to control Notes. Allow it under Automation in System Settings.")
        }
        return Self.reply(error: "Notes could not write the note: \(error)")
    }

    /// nil when the write may go ahead, else the reason it may not.
    private func consent(
        _ action: WriteAction, target: NoteTarget, preview: String, _ settings: WriteSettings, _ session: WriteSession
    ) async -> String? {
        if settings.consent == .always || (settings.consent == .oncePerSession && session.isGranted(action)) { return nil }
        let request = ConfirmRequest(action: action, target: target, preview: preview)
        switch await ask(request) {
        case .some(true):
            if settings.consent == .oncePerSession { session.grant(action) }
            return nil
        case .some(false): return "The owner declined the write."
        case .none: return "The owner did not answer in time, so the write was declined."
        }
    }

    /// nil when the owner did not answer within the timeout.
    private func ask(_ request: ConfirmRequest) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await confirmer.confirm(request) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    static func preview(title: String?, html: String) -> String {
        let text = html.replacing(/<[^>]*>/, with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let title else { return String(text.prefix(800)) }
        return "\(title)\n\n\(text.prefix(800))"
    }

    static func reply(ok: Bool) -> String { json(["ok": ok]) }
    static func reply(error: String) -> String { json(["ok": false, "error": error]) }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
