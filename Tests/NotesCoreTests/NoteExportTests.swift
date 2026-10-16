import Foundation
import Testing
@testable import NotesCore

private func outputDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

private func body(_ text: String) -> Data {
    Encode.gzipBody(text, [Encode.run(text.utf16.count)])
}

private func relative(_ result: ExportResult, _ output: URL) -> [String] {
    result.written.map { String($0.path.dropFirst(output.path.count + 1)) }.sorted()
}

@Test func exportsEachReadableNoteAtItsFolderPath() throws {
    let library = try Library()
    try library.populate()
    try library.note(pk: 110, id: "N-110", title: "Alpha", folder: 10, created: 1, modified: 1, snippet: nil, body: body("one"))
    try library.note(pk: 111, id: "N-111", title: "Beta", folder: 11, created: 2, modified: 2, snippet: nil, body: body("two"))
    try library.note(pk: 112, id: "N-112", title: "Gamma", folder: 14, created: 3, modified: 3, snippet: nil, body: body("three"))
    try library.note(pk: 113, id: "N-113", title: "Gone", folder: 14, created: 3, modified: 3, snippet: nil, body: body("x"), deleted: 1)
    try library.note(pk: 114, id: "N-114", title: "Hidden", folder: 14, created: 3, modified: 3, snippet: nil, body: body("x"), locked: 1)
    let output = outputDirectory()
    defer { try? FileManager.default.removeItem(at: output) }

    let result = try exportNotes(from: NotesReader(databaseURL: library.url), to: output)

    #expect(relative(result, output) == ["On My Mac/Local/Gamma.md", "iCloud/Notes/Alpha.md", "iCloud/Notes/Nested/Beta.md"])
    #expect(try String(contentsOf: output.appendingPathComponent("iCloud/Notes/Nested/Beta.md"), encoding: .utf8) == "two")
}

@Test func namesAreValidDistinctAndStable() throws {
    let library = try Library()
    try library.account(pk: 1, id: "A-1", name: "iCloud")
    try library.folder(pk: 10, id: "F-10", title: "Notes", account: 1)
    let long = String(repeating: "é", count: 150)
    let titles = ["a/b", "c:d", ".hidden", "", long, "Same", "same"]
    for (index, title) in titles.enumerated() {
        try library.note(pk: 100 + index, id: "N-\(100 + index)", title: title, folder: 10, created: Double(index),
                         modified: 0, snippet: nil, body: body("t"))
    }
    let first = outputDirectory()
    let second = outputDirectory()
    defer { for url in [first, second] { try? FileManager.default.removeItem(at: url) } }

    let one = relative(try exportNotes(from: NotesReader(databaseURL: library.url), to: first), first)
    let two = relative(try exportNotes(from: NotesReader(databaseURL: library.url), to: second), second)

    #expect(one == two)
    #expect(one.count == 7)
    let names = one.map { String($0.dropFirst("iCloud/Notes/".count)).precomposedStringWithCanonicalMapping }
    #expect(names.contains("a-b.md") && names.contains("c-d.md") && names.contains("hidden.md") && names.contains("Untitled.md"))
    #expect(names.contains("Same.md") && names.contains("same (2).md"))
    #expect(names.allSatisfy { $0.utf8.count <= 203 })
    #expect(names.contains { $0.hasPrefix("éé") && $0.utf8.count == 203 })
}

@Test func undecodableNoteIsReportedAndSkipped() throws {
    let library = try Library()
    try library.populate()
    try library.note(pk: 110, id: "N-110", title: "Good", folder: 10, created: 1, modified: 1, snippet: nil, body: body("ok"))
    let output = outputDirectory()
    defer { try? FileManager.default.removeItem(at: output) }

    let result = try exportNotes(from: NotesReader(databaseURL: library.url), to: output)

    #expect(relative(result, output) == ["iCloud/Notes/Good.md"])
    #expect(result.failed.map(\.noteID).sorted() == ["N-100", "N-101"])
    #expect(result.failed.first { $0.noteID == "N-101" }?.folderPath == "iCloud/Notes/Nested")
}

@Test func nonEmptyOutputDirectoryStopsExport() throws {
    let library = try Library()
    try library.populate()
    let output = outputDirectory()
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: output.appendingPathComponent("existing.txt"))
    defer { try? FileManager.default.removeItem(at: output) }

    #expect(throws: NoteExportError.outputNotEmpty(path: output.path)) {
        try exportNotes(from: NotesReader(databaseURL: library.url), to: output)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["existing.txt"])
}

@Test func emptyOutputDirectoryIsAccepted() throws {
    let library = try Library()
    try library.populate()
    let output = outputDirectory()
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: output) }

    _ = try exportNotes(from: NotesReader(databaseURL: library.url), to: output)
}
