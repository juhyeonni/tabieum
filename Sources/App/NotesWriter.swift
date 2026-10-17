import AppKit
import NotesCore
import SwiftUI
import os

private let log = Logger(subsystem: "NotesExtension", category: "write")

/// A value an AppleScript returned, in a form that can leave the main actor.
enum ScriptValue: Sendable {
    case text(String), date(Date), number(Int), flag(Bool), list([ScriptValue])

    init(_ descriptor: NSAppleEventDescriptor) {
        switch descriptor.descriptorType {
        case 0x6C69_7374:
            self = .list((0..<descriptor.numberOfItems).compactMap { descriptor.atIndex($0 + 1).map(ScriptValue.init) })
        case 0x626F_6F6C, 0x7472_7565, 0x6661_6C73: self = .flag(descriptor.booleanValue)
        case 0x6C64_7420: self = .date(descriptor.dateValue ?? .distantPast)
        case 0x6C6F_6E67, 0x7368_6F72: self = .number(Int(descriptor.int32Value))
        default: self = .text(descriptor.stringValue ?? "")
        }
    }

    var items: [ScriptValue] { if case .list(let values) = self { values } else { [] } }
    var text: String { if case .text(let value) = self { value } else { "" } }
    var flag: Bool { if case .flag(let value) = self { value } else { false } }
    var number: Int { if case .number(let value) = self { value } else { 0 } }
    var date: Date { if case .date(let value) = self { value } else { .distantPast } }
}

/// Writes through Notes itself with AppleScript; nothing is ever written to the Notes database.
struct AppleScriptNotesWriter: NoteWriter {
    func folderExists(_ target: NoteTarget) async throws -> Bool {
        do {
            return try await Self.run("tell application \"Notes\" to return exists \(Self.folder(target))").flag
        } catch WriteFailure.failed(let message) where message.hasPrefix("-1728") {
            return false
        }
    }

    func createNote(title: String?, html: String, in target: NoteTarget) async throws {
        let heading = title?.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
        let body = heading.map { "<div><h1>\($0)</h1></div>" + html } ?? html
        let handle = try await Self.run("""
        tell application "Notes"
            set created to make new note at \(Self.folder(target)) with properties {body:\(Self.quoted(body))}
            return id of created
        end tell
        """).text
        if !handle.isEmpty { CreatedNoteLog().record(handle) }
    }

    func resolveNote(identifier: String, scope: WriteScope, target: NoteTarget) async throws -> ResolvedNote? {
        guard let key = try NotesReader().noteKey(identifier: identifier) else { return nil }
        let sample = try await Self.run("tell application \"Notes\" to return id of first note").text
        guard let range = sample.range(of: "/ICNote/p") else { return nil }
        let handle = sample[..<range.upperBound] + String(key)
        let inFolder = scope == .targetFolder
            ? "(id of every note of \(Self.folder(target))) contains (id of n)" : "true"
        let found = try await Self.run("""
        tell application "Notes"
            try
                set n to note id \(Self.quoted(String(handle)))
            on error
                return {}
            end try
            return {id of n, name of n, modification date of n, count of attachments of n, password protected of n, \(inFolder)}
        end tell
        """).items
        guard found.count == 6, !found[4].flag, found[5].flag else { return nil }
        if scope == .mcpCreated, !CreatedNoteLog().contains(String(handle)) { return nil }
        return ResolvedNote(
            handle: found[0].text, title: found[1].text, folder: scope == .targetFolder ? target.folder : "",
            modified: found[2].date, hasAttachments: found[3].number > 0)
    }

    func replaceBody(of note: ResolvedNote, with html: String) async throws {
        _ = try await Self.run("tell application \"Notes\" to set body of note id \(Self.quoted(note.handle)) to \(Self.quoted(html))")
    }

    /// Every folder in every account, for the settings picker.
    func folders() async -> [NoteTarget] {
        let script = """
        tell application "Notes"
            set out to {}
            repeat with a in accounts
                repeat with f in folders of a
                    set end of out to {name of a, name of f}
                end repeat
            end repeat
            return out
        end tell
        """
        guard let result = try? await Self.run(script) else { return [] }
        return result.items.map { NoteTarget(account: $0.items[0].text, folder: $0.items[1].text) }
    }

    private static func folder(_ target: NoteTarget) -> String {
        "folder \(quoted(target.folder)) of account \(quoted(target.account))"
    }

    private static func quoted(_ string: String) -> String {
        "\"" + string.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    }

    /// NSAppleScript runs on the main thread, like the rest of the app's scripts.
    @MainActor
    private static func run(_ source: String) throws -> ScriptValue {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let number = error["NSAppleScriptErrorNumber"] as? Int ?? 0
            log.error("AppleScript failed: \(error, privacy: .public)")
            if number == -1743 { throw WriteFailure.automationDenied }
            throw WriteFailure.failed("\(number) \(error["NSAppleScriptErrorMessage"] as? String ?? "")")
        }
        guard let result else { throw WriteFailure.failed("The script could not be compiled.") }
        return ScriptValue(result)
    }
}

/// Asks the owner in a modal alert. Cancelling the waiting task closes the alert.
struct AlertConfirmer: WriteConfirmer {
    @MainActor private final class Shown { var alert: NSAlert? }

    func confirm(_ request: ConfirmRequest) async -> Bool {
        let shown = await MainActor.run { Shown() }
        return await withTaskCancellationHandler {
            await MainActor.run {
                guard !Task.isCancelled else { return false }
                let alert = NSAlert()
                alert.messageText = "Allow an AI agent to \(request.action.rawValue) a note?"
                let place = [request.target.folder, request.target.account.isEmpty ? "" : "(\(request.target.account))"]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                alert.informativeText = (place.isEmpty ? "" : "Folder: \(place)\n\n") + request.preview
                alert.addButton(withTitle: "Allow")
                alert.addButton(withTitle: "Cancel")
                shown.alert = alert
                NSApp.activate()
                return alert.runModal() == .alertFirstButtonReturn
            }
        } onCancel: {
            Task { @MainActor in
                if let window = shown.alert?.window, NSApp.modalWindow === window { NSApp.abortModal() }
            }
        }
    }
}

extension ConsentMode {
    var displayName: String {
        switch self {
        case .always: "Always allow"
        case .oncePerSession: "Ask once per session"
        case .eachTime: "Ask every time"
        case .never: "Never allow"
        }
    }
}

extension WriteScope {
    var displayName: String {
        switch self {
        case .targetFolder: "Only the target folder"
        case .anyNote: "Any note"
        case .mcpCreated: "Only notes created by agents"
        }
    }
}

struct WriteSettingsCard: View {
    @ObservedObject var toggles: FeatureToggles
    @State private var folders: [NoteTarget] = []

    private var chosen: NoteTarget { NoteTarget(account: toggles.write.targetAccount, folder: toggles.write.targetFolder) }

    var body: some View {
        Card {
            Toggle("Let AI agents write to Notes", isOn: $toggles.write.enabled)
            Text("Off by default. Agents write through the Notes app, never into its database, and only while this app is running.")
                .font(.callout).foregroundStyle(.secondary)
            Group {
                ForEach(WriteAction.allCases, id: \.self) { action in
                    Toggle("Allow \(action.rawValue)", isOn: actionBinding(action))
                }
                Text("Edit and delete are saved here and used once agents can edit and delete.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Edit and delete reach", selection: $toggles.write.scope) {
                    ForEach(WriteScope.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Target folder", selection: folderBinding) {
                    Text("None chosen").tag(NoteTarget(account: "", folder: ""))
                    ForEach(options, id: \.self) { Text("\($0.folder) (\($0.account))").tag($0) }
                }
                Picker("Consent", selection: $toggles.write.consent) {
                    ForEach(ConsentMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Mark notes as created by an AI agent", isOn: $toggles.write.marker)
            }
            .disabled(!toggles.write.enabled)
        }
        .task { folders = await AppleScriptNotesWriter().folders() }
    }

    /// The saved folder stays in the list even when Notes can't be asked right now.
    private var options: [NoteTarget] {
        folders.contains(chosen) || chosen.folder.isEmpty ? folders : folders + [chosen]
    }

    private var folderBinding: Binding<NoteTarget> {
        Binding(
            get: { chosen },
            set: {
                toggles.write.targetAccount = $0.account
                toggles.write.targetFolder = $0.folder
            })
    }

    private func actionBinding(_ action: WriteAction) -> Binding<Bool> {
        Binding(
            get: { toggles.write.allowedActions.contains(action) },
            set: { isOn in
                if isOn { toggles.write.allowedActions.insert(action) } else { toggles.write.allowedActions.remove(action) }
            })
    }
}
