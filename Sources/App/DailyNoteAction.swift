import AppKit
import NotesCore

/// Today's note through Notes' own scripting, so it needs Automation but not Full Disk Access.
@MainActor
struct AppleScriptDailyNoteStore: DailyNoteStore {
    let templateFolder: String

    func existingNote(titled title: String) throws -> String? {
        // ponytail: the trash is skipped by its English name; other languages may open a deleted note
        let handle = try AppleScriptNotesWriter.run("""
        tell application "Notes"
            repeat with a in accounts
                repeat with f in folders of a
                    if name of f is not "Recently Deleted" then
                        set found to notes of f whose name is \(AppleScriptNotesWriter.quoted(title))
                        if (count of found) > 0 then return id of item 1 of found
                    end if
                end repeat
            end repeat
            return ""
        end tell
        """).text
        return handle.isEmpty ? nil : handle
    }

    func dailyTemplate() throws -> String? {
        let body = try AppleScriptNotesWriter.run("""
        tell application "Notes"
            repeat with a in accounts
                repeat with f in (folders of a whose name is \(AppleScriptNotesWriter.quoted(templateFolder)))
                    set found to notes of f whose name is "Daily"
                    if (count of found) > 0 then return body of item 1 of found
                end repeat
            end repeat
            return ""
        end tell
        """).text
        return body.isEmpty ? nil : body
    }

    func create(html: String) throws -> String {
        try AppleScriptNotesWriter.run("""
        tell application "Notes" to return id of (make new note with properties {body:\(AppleScriptNotesWriter.quoted(html))})
        """).text
    }

    func show(_ handle: String) throws {
        _ = try AppleScriptNotesWriter.run("""
        tell application "Notes"
            activate
            show note id \(AppleScriptNotesWriter.quoted(handle))
        end tell
        """)
    }
}

@MainActor
enum DailyNoteAction {
    static func open(templateFolder: String) {
        do {
            _ = try DailyNote.open(now: Date(), in: .current, store: AppleScriptDailyNoteStore(templateFolder: templateFolder))
        } catch WriteFailure.automationDenied {
            alert("Allow this app to control Notes in System Settings > Privacy & Security > Automation.")
        } catch {
            alert("Could not open today's note: \(error)")
        }
    }

    private static func alert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        NSApp.activate()
        alert.runModal()
    }
}
