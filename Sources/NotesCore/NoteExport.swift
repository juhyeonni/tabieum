import Foundation

public struct ExportFailure: Equatable, Sendable {
    public let noteID: String
    public let folderPath: String
    public let title: String
    public let message: String
}

public struct ExportResult: Equatable, Sendable {
    public var written: [URL] = []
    public var failed: [ExportFailure] = []
}

public enum NoteExportError: Error, Equatable {
    case outputNotEmpty(path: String)
}

/// Writes every readable note as `<output>/<account>/<folder>/…/<title>.md`. The output directory must not exist or must be empty.
public func exportNotes(from reader: NotesReader, to output: URL) throws -> ExportResult {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: output.path, isDirectory: &isDirectory) {
        let contents = isDirectory.boolValue ? try? fileManager.contentsOfDirectory(atPath: output.path) : nil
        guard let contents, contents.isEmpty else { throw NoteExportError.outputNotEmpty(path: output.path) }
    }

    let accounts = Dictionary(try reader.accounts().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let folders = Dictionary(try reader.folders().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let notes = try reader.notes().sorted { ($0.created, $0.id) < ($1.created, $1.id) }

    var taken = Set<String>()
    var accountDirectories: [String: String] = [:]
    var folderDirectories: [String: [String]] = [:]

    func claim(_ name: String, in parent: [String], suffix: String) -> String {
        let base = fileName(name)
        var candidate = base
        var n = 1
        while !taken.insert((parent + [candidate + suffix]).joined(separator: "/").lowercased()).inserted {
            n += 1
            candidate = "\(base) (\(n))"
        }
        return candidate + suffix
    }

    func directory(of folder: Folder) -> [String]? {
        if let known = folderDirectories[folder.id] { return known }
        let parent: [String]
        if let parentID = folder.parentID {
            guard let parentFolder = folders[parentID], let path = directory(of: parentFolder) else { return nil }
            parent = path
        } else {
            guard let account = accounts[folder.accountID] else { return nil }
            if accountDirectories[account.id] == nil { accountDirectories[account.id] = claim(account.name, in: [], suffix: "") }
            parent = [accountDirectories[account.id]!]
        }
        let path = parent + [claim(folder.name, in: parent, suffix: "")]
        folderDirectories[folder.id] = path
        return path
    }

    var result = ExportResult()
    for note in notes {
        guard let folder = folders[note.folderID], let path = directory(of: folder) else { continue }
        let file = claim(note.title, in: path, suffix: ".md")
        do {
            let markdown = try NoteBodyDecoder.decode(note.body).markdown()
            let directory = path.reduce(output) { $0.appendingPathComponent($1) }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(file)
            try Data(markdown.utf8).write(to: target)
            result.written.append(target)
        } catch {
            result.failed.append(ExportFailure(
                noteID: note.id, folderPath: path.joined(separator: "/"), title: note.title, message: "\(error)"))
        }
    }
    return result
}

/// A file or folder name safe on APFS: no `/` or `:`, no edge whitespace or leading dots, at most 200 UTF-8 bytes.
func fileName(_ raw: String) -> String {
    let replaced = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    var name = Substring(replaced.trimmingCharacters(in: .whitespacesAndNewlines))
    name = name.drop(while: { $0 == "." })
    var bytes = 0
    name = name.prefix { character in
        bytes += character.utf8.count
        return bytes <= 200
    }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Untitled" : trimmed
}
