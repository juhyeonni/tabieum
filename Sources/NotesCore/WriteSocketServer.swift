import Darwin
import Foundation

/// Listens on a Unix socket only the current user can open and serves newline-delimited JSON requests to a `NoteWriteService`.
public final class WriteSocketServer: @unchecked Sendable {
    public enum Failure: Error { case pathTooLong, socket(String) }

    private let path: String
    private let service: NoteWriteService
    private let lock = NSLock()
    private var listener: Int32 = -1

    public init(path: URL, service: NoteWriteService) {
        self.path = path.path
        self.service = service
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

    private func accept(on descriptor: Int32) {
        while true {
            let connection = Darwin.accept(descriptor, nil, nil)
            guard connection >= 0 else { return }
            Task.detached { [service] in await Self.serve(connection, service) }
        }
    }

    private static func serve(_ descriptor: Int32, _ service: NoteWriteService) async {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let session = WriteSession()
        do {
            for try await line in handle.bytes.lines {
                let reply = await service.handle(line, session: session)
                try handle.write(contentsOf: Data((reply + "\n").utf8))
            }
        } catch {}
    }
}
