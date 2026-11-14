import Foundation

public enum NotesBlock: Equatable, Sendable {
    case heading(String)
    case bullet(String)
    case code(String)
    case paragraph(String)
}

public struct UpdatePrompt: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case openReleasePage, copyCommand, later }
    public struct Button: Equatable, Sendable {
        public let title: String
        public let action: Action
    }

    public let title: String
    public let info: String
    public let notes: [NotesBlock]
    public let command: String?
    /// The first button is the default one.
    public let buttons: [Button]

    public init(release: Release, current: String, kind: InstallKind, product: String) {
        title = "\(product) \(release.version) is available"
        notes = Self.blocks(from: release.notes)
        let later = Button(title: "Later", action: .later)
        guard kind == .homebrew else {
            info = "You have \(current)."
            command = nil
            buttons = [Button(title: "Open Release Page", action: .openReleasePage), later]
            return
        }
        info = "You have \(current). This copy was installed with Homebrew, so Homebrew should update it."
            + "\n\nThen relaunch \(product) to use the new version."
        command = "brew upgrade --cask \(product.lowercased())"
        buttons = [Button(title: "Copy Command", action: .copyCommand), later]
    }

    public static func blocks(from text: String) -> [NotesBlock] {
        var result: [NotesBlock] = []
        var fence: [String]?
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = fence { result.append(.code(lines.joined(separator: "\n"))) }
                fence = fence == nil ? [] : nil
            } else if fence != nil {
                fence?.append(line)
            } else if let match = trimmed.wholeMatch(of: /#{1,6}\s+(.*)/) {
                result.append(.heading(String(match.1)))
            } else if let match = trimmed.wholeMatch(of: /[-*+]\s+(.*)/) {
                result.append(.bullet(String(match.1)))
            } else if !trimmed.isEmpty {
                result.append(.paragraph(trimmed))
            }
        }
        if let lines = fence { result.append(.code(lines.joined(separator: "\n"))) }
        return result
    }
}
