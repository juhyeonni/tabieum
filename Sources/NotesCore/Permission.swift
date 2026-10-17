import Foundation

public enum Permission: CaseIterable, Sendable {
    case accessibility
    case fullDiskAccess
    case automation

    public var settingsURL: URL {
        let anchor = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .automation: "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public enum PermissionState: Equatable, Sendable {
    case granted
    case notGranted
    case notesNotRunning
    case unknown

    public init(automationStatus: Int32) {
        switch automationStatus {
        case 0: self = .granted
        case -1743, -1744: self = .notGranted
        case -600: self = .notesNotRunning
        default: self = .unknown
        }
    }

    public init(fullDiskAccessProbe path: String) {
        let fd = open(path, O_RDONLY)
        guard fd < 0 else {
            close(fd)
            self = .granted
            return
        }
        self = (errno == EPERM || errno == EACCES) ? .notGranted : .unknown
    }
}

public func permissionPollInterval(allGranted: Bool) -> TimeInterval {
    allGranted ? 5 : 1
}

public enum NotesDatabase {
    public static var path: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite").path
    }
}
