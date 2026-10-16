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
            let reader = try NotesReader()
            try copy(try CurrentNote.open { try reader.noteKeys(title: $0) }.key, reader)
        } catch let failure as CopyFailure {
            alert(message(failure))
        } catch let error as NotesReaderError {
            alert("Could not read the Notes database: \(error)")
        } catch {
            alert("Could not copy the note: \(error)")
        }
    }

    private static func message(_ failure: CopyFailure) -> String {
        switch failure {
        case .noCurrentNote: "Open or select one note in Notes first."
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
