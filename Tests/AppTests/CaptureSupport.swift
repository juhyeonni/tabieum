import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

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
    static func lower(_ window: NSWindow, level: Int = -10) {
        window.level = NSWindow.Level(rawValue: level)
        window.orderBack(nil)
    }

    @MainActor
    static func wait() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    @MainActor
    static func capture(_ window: NSWindow, to file: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-l", String(window.windowNumber), "-o", file.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor
    static func capture(_ window: NSWindow, as name: String) throws {
        try capture(window, to: try directory().appendingPathComponent("\(name).png"))
    }

    @MainActor
    static func captureLowered(_ window: NSWindow, as name: String) throws {
        lower(window)
        wait()
        try capture(window, as: name)
    }

    /// One PNG with each visible overlay drawn over `base` at its place on screen.
    @MainActor
    static func composite(base: NSWindow, overlays: [NSWindow], as name: String) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ui-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let baseImage = try image(of: base, in: temp)
        let scale = CGFloat(baseImage.width) / base.frame.width
        let context = try #require(CGContext(
            data: nil, width: baseImage.width, height: baseImage.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(baseImage, in: CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height))
        for overlay in overlays where overlay.isVisible {
            let overlayImage = try image(of: overlay, in: temp)
            context.draw(overlayImage, in: CGRect(
                x: (overlay.frame.minX - base.frame.minX) * scale, y: (overlay.frame.minY - base.frame.minY) * scale,
                width: CGFloat(overlayImage.width), height: CGFloat(overlayImage.height)))
        }

        let file = try directory().appendingPathComponent("\(name).png")
        let result = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, result, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @MainActor
    private static func image(of window: NSWindow, in directory: URL) throws -> CGImage {
        let file = directory.appendingPathComponent("\(window.windowNumber).png")
        try capture(window, to: file)
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}
