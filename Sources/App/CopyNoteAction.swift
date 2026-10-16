import AppKit
import NotesCore

/// Copies the note open in Notes to the pasteboard, or shows an alert naming why it could not.
@MainActor
enum CopyNoteAction {
    static func markdown() {
        run { key, reader in
            let text = try CopyNote.markdown(key: key, from: reader)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    static func link() {
        run { key, reader in
            let url = try CopyNote.link(key: key, from: reader)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }

    private static func run(_ copy: (Int, NotesReader) throws -> Void) {
        do {
            let key = try CurrentNote.key(fromSelection: selectedNoteIDs())
            try copy(key, NotesReader())
        } catch let failure as CopyFailure {
            alert(message(failure))
        } catch let error as NotesReaderError {
            alert("Could not read the Notes database: \(error)")
        } catch {
            alert("Could not copy the note: \(error)")
        }
    }

    private static func selectedNoteIDs() throws -> [String] {
        let source = #"tell application "Notes" to get id of selection"#
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            throw CurrentNote.failure(scriptErrorNumber: error?[NSAppleScript.errorNumber] as? Int ?? 0)
        }
        if result.numberOfItems == 0 { return result.stringValue.map { [$0] } ?? [] }
        return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
    }

    private static func message(_ failure: CopyFailure) -> String {
        switch failure {
        case .noCurrentNote: "Select exactly one note in Notes first."
        case .locked: "This note is locked, so its text cannot be read."
        case .notFound: "Notes has no saved copy of this note yet."
        case .automationDenied: "Allow this app to control Notes in System Settings > Privacy & Security > Automation."
        }
    }

    private static func alert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        NSApp.activate()
        alert.runModal()
    }
}
