import AppKit
import NotesCore
import SwiftUI
import os

private let log = Logger(subsystem: "NotesExtension", category: "write")

/// Writes through Notes itself with AppleScript; nothing is ever written to the Notes database.
struct AppleScriptNotesWriter: NoteWriter {
    func folderExists(_ target: NoteTarget) async throws -> Bool {
        do {
            return try await Self.run("tell application \"Notes\" to return exists \(Self.folder(target))").flag
        } catch WriteFailure.failed(let message) where message.hasPrefix("-1728") {
            return false
        }
    }

    func createNote(title: String, html: String, in target: NoteTarget) async throws {
        let heading = title.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
        let body = "<div><h1>\(heading)</h1></div>" + html
        _ = try await Self.run("""
        tell application "Notes"
            make new note at \(Self.folder(target)) with properties {name:\(Self.quoted(title)), body:\(Self.quoted(body))}
        end tell
        """)
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
        return result.pairs.map { NoteTarget(account: $0[0], folder: $0[1]) }
    }

    private struct ScriptResult: Sendable {
        let flag: Bool
        let pairs: [[String]]
    }

    private static func folder(_ target: NoteTarget) -> String {
        "folder \(quoted(target.folder)) of account \(quoted(target.account))"
    }

    private static func quoted(_ string: String) -> String {
        "\"" + string.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    }

    /// NSAppleScript runs on the main thread, like the rest of the app's scripts.
    @MainActor
    private static func run(_ source: String) throws -> ScriptResult {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let number = error["NSAppleScriptErrorNumber"] as? Int ?? 0
            log.error("AppleScript failed: \(error, privacy: .public)")
            if number == -1743 { throw WriteFailure.automationDenied }
            throw WriteFailure.failed("\(number) \(error["NSAppleScriptErrorMessage"] as? String ?? "")")
        }
        guard let result else { throw WriteFailure.failed("The script could not be compiled.") }
        let pairs = (0..<result.numberOfItems).compactMap { index -> [String]? in
            guard let pair = result.atIndex(index + 1), let first = pair.atIndex(1)?.stringValue,
                  let second = pair.atIndex(2)?.stringValue else { return nil }
            return [first, second]
        }
        return ScriptResult(flag: result.booleanValue, pairs: pairs)
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
                alert.informativeText = "Folder: \(request.target.folder) (\(request.target.account))\n\n\(request.preview)"
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
