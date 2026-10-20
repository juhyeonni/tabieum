import AppKit
import Foundation
import Testing

enum Capture {
    private static let environment = ProcessInfo.processInfo.environment

    /// Set by `scripts/ui-capture.sh`; without it the capture tests do nothing.
    static let enabled = environment["UI_CAPTURE_DIR"] != nil

    static func directory() throws -> URL {
        URL(fileURLWithPath: try #require(environment["UI_CAPTURE_DIR"]))
    }

    @MainActor
    static func prepareApp() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
    }

    /// Below every normal window and never key, so the front app and keyboard focus stay as they are.
    @MainActor
    static func lower(_ window: NSWindow) {
        window.level = NSWindow.Level(rawValue: -10)
        window.orderBack(nil)
    }

    @MainActor
    static func wait() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    @MainActor
    static func capture(_ window: NSWindow, as name: String) throws {
        let file = try directory().appendingPathComponent("\(name).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-l", String(window.windowNumber), "-o", file.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor
    static func captureLowered(_ window: NSWindow, as name: String) throws {
        lower(window)
        wait()
        try capture(window, as: name)
    }
}
