import Foundation
import NotesCore

let usage = "usage: notes-export <output-dir> [--db <path>]"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var output: String?
var database = NotesReader.defaultDatabaseURL
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    if argument == "--db" {
        guard let path = arguments.popFirst() else { fail(usage) }
        database = URL(fileURLWithPath: path)
    } else if output == nil, !argument.hasPrefix("--") {
        output = argument
    } else {
        fail(usage)
    }
}
guard let output else { fail(usage) }

let result: ExportResult
do {
    result = try exportNotes(from: NotesReader(databaseURL: database), to: URL(fileURLWithPath: output))
} catch NotesReaderError.permissionDenied(let path) {
    fail("Cannot read \(path). Grant Full Disk Access to your terminal in System Settings > Privacy & Security.")
} catch NoteExportError.outputNotEmpty(let path) {
    fail("\(path) must not exist or must be empty.")
} catch {
    fail("\(error)")
}

for failure in result.failed {
    let line = "\(failure.noteID)\t\(failure.folderPath)\t\(failure.title)\t\(failure.message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
print("Exported \(result.written.count) notes, \(result.failed.count) failed")
exit(result.failed.isEmpty ? 0 : 1)
