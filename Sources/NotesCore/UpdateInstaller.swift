import Foundation

/// Swaps a staged app in for the installed one. `replaceItemAt` exchanges them in place, so a failure leaves the installed app whole.
public enum UpdateInstaller {
    public static func install(
        _ staged: StagedUpdate, over installed: URL,
        isCancelled: () -> Bool = { Task.isCancelled },
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        beginSwap: () -> Void = {}
    ) throws {
        defer { try? FileManager.default.removeItem(at: staged.folder) }
        if isCancelled() { throw UpdateFailure.cancelled }
        beginSwap()
        let previous = installed.deletingLastPathComponent()
            .appendingPathComponent(installed.deletingPathExtension().lastPathComponent + " (previous).app")
        do {
            _ = try FileManager.default.replaceItemAt(
                installed, withItemAt: staged.app, backupItemName: previous.lastPathComponent,
                options: .withoutDeletingBackupItem)
        } catch {
            throw UpdateFailure.replaceFailed(error.localizedDescription)
        }
        try? trash(previous)
    }
}

public enum UpdateRelaunch {
    /// The path is an argument of a fixed script, never part of a shell string.
    public static func arguments(pid: Int32, app: URL) -> [String] {
        ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$2\"", "sh", String(pid), app.path]
    }

    public static func launch(pid: Int32 = ProcessInfo.processInfo.processIdentifier, app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(pid: pid, app: app)
        try process.run()
    }
}
