import Darwin
import Foundation
import os

/// Listens on a Unix socket only the current user can open and serves newline-delimited JSON requests to a `NoteWriteService`.
/// A connection is served only when `peerCheck` accepts the process at its other end.
public final class WriteSocketServer: @unchecked Sendable {
    public enum Failure: Error { case pathTooLong, socket(String) }

    private static let logger = Logger(subsystem: "NotesCore", category: "WriteSocket")

    private let path: String
    private let service: NoteWriteService
    private let peerCheck: WritePeerCheck
    private let acceptConnection: @Sendable (Int32) -> Int32
    private let retryDelay: TimeInterval
    private let lock = NSLock()
    private var listener: Int32 = -1

    /// `acceptConnection` and `retryDelay` exist so tests can inject accept failures; `acceptConnection` must set `errno` when it returns -1.
    init(
        path: URL, service: NoteWriteService, peerCheck: WritePeerCheck,
        acceptConnection: @escaping @Sendable (Int32) -> Int32, retryDelay: TimeInterval
    ) {
        self.path = path.path
        self.service = service
        self.peerCheck = peerCheck
        self.acceptConnection = acceptConnection
        self.retryDelay = retryDelay
    }

    public convenience init(path: URL, service: NoteWriteService, peerCheck: WritePeerCheck = .sameCode) {
        self.init(path: path, service: service, peerCheck: peerCheck,
                  acceptConnection: { Darwin.accept($0, nil, nil) }, retryDelay: 0.5)
    }

    public func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw Failure.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.socket(String(cString: strerror(errno))) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            throw Failure.socket(reason)
        }
        lock.withLock { listener = descriptor }
        signal(SIGPIPE, SIG_IGN)
        Thread.detachNewThread { [self] in accept(on: descriptor) }
    }

    public func stop() {
        let descriptor = lock.withLock { () -> Int32 in
            defer { listener = -1 }
            return listener
        }
        guard descriptor >= 0 else { return }
        close(descriptor)
        unlink(path)
    }

    private func isListening(on descriptor: Int32) -> Bool { lock.withLock { listener == descriptor } }

    /// Runs until `stop()` closes the listener. A failed accept is retried, never the end of the loop: otherwise one
    /// interrupted call or a moment out of file descriptors would turn agent writes off until the app is relaunched.
    private func accept(on descriptor: Int32) {
        while isListening(on: descriptor) {
            let connection = acceptConnection(descriptor)
            let failure = errno
            if connection >= 0 {
                Task.detached { [service, peerCheck] in await Self.serve(connection, service, peerCheck) }
                continue
            }
            guard isListening(on: descriptor) else { break }
            let reason = String(cString: strerror(failure))
            if failure == EINTR || failure == ECONNABORTED {
                Self.logger.info("accept failed with \(reason, privacy: .public); retrying")
            } else {
                // EMFILE and ENFILE clear once descriptors are freed; the pause keeps the loop from spinning until then.
                Self.logger.error("accept failed with \(reason, privacy: .public); retrying after a pause")
                Thread.sleep(forTimeInterval: retryDelay)
            }
        }
        Self.logger.info("write socket closed; accept loop ends")
    }

    private static func serve(_ descriptor: Int32, _ service: NoteWriteService, _ peerCheck: WritePeerCheck) async {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard peerCheck.allows(descriptor) else {
            logger.error("refused a write socket connection from a process that is not this app")
            try? handle.write(contentsOf: Data((NoteWriteService.reply(error: "Only this app's own --mcp process may write to Notes.") + "\n").utf8))
            return
        }
        let session = WriteSession()
        do {
            for try await line in handle.bytes.lines {
                let reply = await service.handle(line, session: session)
                try handle.write(contentsOf: Data((reply + "\n").utf8))
            }
        } catch {}
    }
}
