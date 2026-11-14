import Foundation

public enum NotesBlock: Equatable, Sendable {
    case heading(String)
    case bullet(String)
    case code(String)
    case paragraph(String)
}

public struct UpdatePrompt: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case install, openReleasePage, copyCommand, later, close }
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
        let page = Button(title: "Open Release Page", action: .openReleasePage)
        if kind == .homebrew {
            info = "You have \(current). This copy was installed with Homebrew, so Homebrew should update it."
                + "\n\nThen relaunch \(product) to use the new version."
            command = "brew upgrade --cask \(product.lowercased())"
            buttons = [Button(title: "Copy Command", action: .copyCommand), later]
            return
        }
        command = nil
        switch kind {
        case .fixed(.notWritable):
            info = "You have \(current).\n\n\(product) can't replace the app in its folder because the folder is not writable."
            buttons = [page, later]
        case .fixed(.translocated):
            info = "You have \(current).\n\nThis copy runs from a temporary location, so \(product) can't replace it."
                + " Move it to /Applications and open it again."
            buttons = [page, later]
        default:
            info = "You have \(current)."
            buttons = [Button(title: "Install and Relaunch", action: .install), page, later]
        }
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

extension UpdateFailure {
    public var reason: String {
        switch self {
        case .missingAsset: "This release has no downloadable app."
        case .addressNotAllowed: "The download address is not one this app trusts."
        case .download(let detail): "The download failed: \(detail)"
        case .checksumFileUnreadable: "The checksum file could not be read."
        case .checksumNamesOtherFile: "The checksum file is for a different download."
        case .checksumMismatch: "The download does not match its checksum."
        case .unsafeArchive: "The download holds files outside the app."
        case .unpackFailed: "The download could not be unpacked."
        case .appMissing: "The download does not contain the app."
        case .wrongBundle: "The download is not the same app."
        case .wrongVersion: "The download is not the version that was offered."
        case .notNewer: "The download is not newer than this app."
        case .signature(let detail): "The download is not signed like this app: \(detail)"
        case .replaceFailed(let detail): "The app could not be replaced: \(detail)"
        case .cancelled: "The update was cancelled."
        }
    }
}

public struct UpdateFailurePrompt: Equatable, Sendable {
    public let title: String
    public let info: String
    /// The first button is the default one.
    public let buttons: [UpdatePrompt.Button]

    public init(failure: UpdateFailure, product: String, version: String) {
        title = "Couldn't install \(product) \(version)"
        info = failure.reason + "\n\nYour current version is unchanged."
        buttons = [.init(title: "Open Release Page", action: .openReleasePage), .init(title: "Close", action: .close)]
    }
}

public enum UpdateProgress {
    public enum Step: Int, Sendable { case found, downloading, verifying, replacing, relaunching }
    public enum Mark: Equatable, Sendable { case done, current, todo }
    public struct Line: Equatable, Sendable {
        public let text: String
        public let mark: Mark
    }

    public static func lines(step: Step, fraction: Double = 0) -> [Line] {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
        let titles = [
            "Release found", step == .downloading ? "Downloading (\(percent)%)" : "Downloading",
            "Check the checksum and the signature", "Replace the app", "Relaunch",
        ]
        return titles.enumerated().map { index, text in
            Line(text: text, mark: index < step.rawValue ? .done : index == step.rawValue ? .current : .todo)
        }
    }
}
