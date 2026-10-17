import Darwin
import Foundation

/// How the MCP server reaches the app's write service. One request line in, one reply line out.
public protocol WriteChannel: Sendable {
    func send(_ line: String) throws -> String
}

public enum WriteChannelError: Error, Equatable, Sendable {
    case appNotRunning
    case noAnswer
}

/// Keeps one connection to the app's socket for the life of the process, so the app sees one session.
/// A broken connection is replaced, which starts a new session.
public final class WriteSocketClient: WriteChannel, @unchecked Sendable {
    private let path: String
    private let timeout: Int
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    /// The app waits 60 seconds for the owner, so the default waits a little longer for its reply.
    public init(path: URL, timeoutSeconds: Int = 75) {
        self.path = path.path
        self.timeout = timeoutSeconds
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    public func send(_ line: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 {
            do {
                return try exchange(line)
            } catch WriteChannelError.noAnswer {
                disconnect()
                throw WriteChannelError.noAnswer
            } catch {}
        }
        disconnect()
        try connect()
        do {
            return try exchange(line)
        } catch {
            disconnect()
            throw error
        }
    }

    private func connect() throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw WriteChannelError.appNotRunning }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WriteChannelError.appNotRunning }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw WriteChannelError.appNotRunning
        }
        var limit = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        descriptor = fd
    }

    private func disconnect() {
        if descriptor >= 0 { close(descriptor) }
        descriptor = -1
    }

    private func exchange(_ line: String) throws -> String {
        let bytes = Array((line + "\n").utf8)
        guard write(descriptor, bytes, bytes.count) == bytes.count else { throw WriteChannelError.appNotRunning }
        var reply: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 10 { return String(decoding: reply, as: UTF8.self) }
                reply.append(byte)
            } else if count == 0 {
                throw WriteChannelError.appNotRunning
            } else {
                throw errno == EAGAIN || errno == EWOULDBLOCK ? WriteChannelError.noAnswer : WriteChannelError.appNotRunning
            }
        }
    }
}
