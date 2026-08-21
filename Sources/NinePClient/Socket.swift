import Foundation
import NineP

#if canImport(Darwin)
import Darwin
private let sysRead = Darwin.read
private let sysWrite = Darwin.write
private let sysClose = Darwin.close
private let sysConnect = Darwin.connect
private let sysSocket = Darwin.socket
private let sysShutdown = Darwin.shutdown
#elseif canImport(Glibc)
import Glibc
private let sysRead = Glibc.read
private let sysWrite = Glibc.write
private let sysClose = Glibc.close
private let sysConnect = Glibc.connect
private let sysSocket = Glibc.socket
private let sysShutdown = Glibc.shutdown
#endif

/// Where to reach a 9P server.
public enum NinePEndpoint: Sendable, Hashable, CustomStringConvertible {
    /// A TCP host and port. 9P's registered port is 564.
    case tcp(host: String, port: Int)
    /// A Unix domain socket path.
    case unix(path: String)
    /// An already-connected file descriptor, which the session takes ownership of.
    /// Used for stdio-style transports such as `ssh host 9pserve`.
    case fileDescriptor(Int32)

    public var description: String {
        switch self {
        case let .tcp(host, port): "tcp!\(host)!\(port)"
        case let .unix(path): "unix!\(path)"
        case let .fileDescriptor(fd): "fd!\(fd)"
        }
    }

    /// Parses the Plan 9 dial string forms plus a few conveniences:
    /// `tcp!host!port`, `unix!/path`, `host:port`, `host`, `/path/to/socket`.
    public static func parse(_ s: String, defaultPort: Int = P9.defaultPort) throws -> NinePEndpoint {
        if s.hasPrefix("/") || s.hasPrefix("./") { return .unix(path: s) }
        let parts = s.split(separator: "!", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 2 {
            switch parts[0] {
            case "tcp", "tcp4", "tcp6":
                let port = parts.count >= 3 ? Int(parts[2]) ?? defaultPort : defaultPort
                return .tcp(host: parts[1], port: port)
            case "unix":
                return .unix(path: parts.dropFirst().joined(separator: "!"))
            default:
                throw NinePClientError.badEndpoint(s)
            }
        }
        // host:port, with IPv6 literals in brackets.
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) ?? defaultPort : defaultPort
            return .tcp(host: host, port: port)
        }
        if let colon = s.lastIndex(of: ":"), let port = Int(s[s.index(after: colon)...]) {
            return .tcp(host: String(s[s.startIndex..<colon]), port: port)
        }
        return .tcp(host: s, port: defaultPort)
    }
}

/// Errors raised by the socket layer and the session.
public enum NinePClientError: Error, CustomStringConvertible {
    case badEndpoint(String)
    case resolutionFailed(host: String, detail: String)
    case connectionFailed(errno: Int32, detail: String)
    case connectionClosed
    case timedOut
    case io(errno: Int32, operation: String)
    /// The server's reply frame claimed a size larger than the negotiated msize.
    case frameTooLarge(UInt32, limit: UInt32)
    /// The server did not agree to any version this client speaks.
    case versionNegotiationFailed(offered: [String], serverSaid: String)
    /// A reply arrived whose tag matches no outstanding request.
    case unexpectedReply(Tag)
    /// A reply arrived that is not a valid answer to the request that was sent.
    case protocolViolation(String)
    case sessionClosed

    public var description: String {
        switch self {
        case let .badEndpoint(s): "cannot parse 9P address '\(s)'"
        case let .resolutionFailed(host, detail): "cannot resolve '\(host)': \(detail)"
        case let .connectionFailed(e, detail): "connect failed: \(detail) (errno \(e))"
        case .connectionClosed: "the server closed the connection"
        case .timedOut: "operation timed out"
        case let .io(e, op): "\(op) failed: \(String(cString: strerror(e))) (errno \(e))"
        case let .frameTooLarge(n, limit): "server sent a \(n)-byte frame, over the \(limit)-byte msize"
        case let .versionNegotiationFailed(offered, said):
            "server accepted none of \(offered.joined(separator: ", ")); it replied '\(said)'"
        case let .unexpectedReply(tag): "reply for unknown tag \(tag)"
        case let .protocolViolation(d): "protocol violation: \(d)"
        case .sessionClosed: "the 9P session is closed"
        }
    }
}

/// A connected stream socket with blocking, EINTR-safe, fully-draining I/O.
///
/// The session drives this from one dedicated reader thread and serializes
/// writes behind a lock, so the socket itself needs no internal synchronisation
/// beyond `close` being safe to call from another thread.
public final class StreamSocket: @unchecked Sendable {
    private let fd: Int32
    private let closed = ManagedAtomicFlag()

    private init(fd: Int32) {
        self.fd = fd
        #if canImport(Darwin)
        // Darwin has no MSG_NOSIGNAL; the suppression is a socket option.
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    public static func connect(to endpoint: NinePEndpoint, timeout: TimeInterval = 30) throws -> StreamSocket {
        switch endpoint {
        case let .fileDescriptor(fd):
            return StreamSocket(fd: fd)
        case let .unix(path):
            return try connectUnix(path: path, timeout: timeout)
        case let .tcp(host, port):
            return try connectTCP(host: host, port: port, timeout: timeout)
        }
    }

    private static func connectTCP(host: String, port: Int, timeout: TimeInterval) throws -> StreamSocket {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &result)
        guard rc == 0, let list = result else {
            throw NinePClientError.resolutionFailed(
                host: host, detail: String(cString: gai_strerror(rc)))
        }
        defer { freeaddrinfo(list) }

        var lastErrno: Int32 = ECONNREFUSED
        var candidate: UnsafeMutablePointer<addrinfo>? = list
        while let info = candidate {
            let fd = sysSocket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                if connectWithTimeout(fd: fd, addr: info.pointee.ai_addr,
                                      len: info.pointee.ai_addrlen, timeout: timeout) {
                    let s = StreamSocket(fd: fd)
                    s.setNoDelay()
                    return s
                }
                lastErrno = errno
                _ = sysClose(fd)
            } else {
                lastErrno = errno
            }
            candidate = info.pointee.ai_next
        }
        throw NinePClientError.connectionFailed(
            errno: lastErrno, detail: "\(host):\(port): \(String(cString: strerror(lastErrno)))")
    }

    private static func connectUnix(path: String, timeout: TimeInterval) throws -> StreamSocket {
        #if canImport(Darwin)
        let fd = sysSocket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = sysSocket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else {
            throw NinePClientError.connectionFailed(errno: errno, detail: "socket(AF_UNIX)")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            _ = sysClose(fd)
            throw NinePClientError.badEndpoint("unix socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connectWithTimeout(fd: fd, addr: UnsafeMutablePointer(mutating: sa),
                                   len: socklen_t(MemoryLayout<sockaddr_un>.size), timeout: timeout)
            }
        }
        guard ok else {
            let e = errno
            _ = sysClose(fd)
            throw NinePClientError.connectionFailed(errno: e, detail: path)
        }
        return StreamSocket(fd: fd)
    }

    /// Connects with a bounded wait by flipping the socket to non-blocking for
    /// the duration of `connect(2)` and polling for writability.
    private static func connectWithTimeout(
        fd: Int32, addr: UnsafeMutablePointer<sockaddr>?, len: socklen_t, timeout: TimeInterval
    ) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }

        if sysConnect(fd, addr, len) == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms = timeout <= 0 ? -1 : Int32(timeout * 1000)
        while true {
            let n = poll(&pfd, 1, ms)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { errno = n == 0 ? ETIMEDOUT : errno; return false }
            break
        }
        var soError: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &size) == 0, soError == 0 else {
            errno = soError == 0 ? EIO : soError
            return false
        }
        return true
    }

    /// Bounds how long a single `read` will block. Zero removes the bound.
    ///
    /// Used during the handshake: some servers answer an unsupported Tversion
    /// by saying nothing at all, and a client that blocks forever on that is
    /// indistinguishable from a hang.
    public func setReadTimeout(_ seconds: TimeInterval) {
        let whole = Int(seconds)
        let micros = Int((seconds - Double(whole)) * 1e6)
        var tv = timeval(tv_sec: whole, tv_usec: .init(micros))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func setNoDelay() {
        // 9P is a request/response protocol with small headers; Nagle would add
        // a round trip of latency to every operation.
        var on: Int32 = 1
        _ = setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Reads exactly `count` bytes, or throws.
    public func readFully(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        try buf.withUnsafeMutableBytes { raw in
            while got < count {
                let n = sysRead(fd, raw.baseAddress!.advanced(by: got), count - got)
                if n > 0 { got += n; continue }
                if n == 0 { throw NinePClientError.connectionClosed }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw NinePClientError.timedOut }
                throw NinePClientError.io(errno: errno, operation: "read")
            }
        }
        return buf
    }

    /// Writes every byte, or throws.
    ///
    /// Writing to a socket the peer has closed raises SIGPIPE, whose default
    /// action is to kill the process. A 9P server going away must produce an
    /// error, not take down the mount helper or the filesystem extension with
    /// it, so the write is suppressed at the socket (Darwin) or at the call
    /// (Linux) rather than by installing a process-wide signal handler, which
    /// a library has no business doing to its host.
    public func writeFully(_ bytes: [UInt8]) throws {
        var sent = 0
        try bytes.withUnsafeBytes { raw in
            while sent < bytes.count {
                #if canImport(Darwin)
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                #else
                let n = Glibc.send(fd, raw.baseAddress!.advanced(by: sent), bytes.count - sent,
                                   Int32(MSG_NOSIGNAL))
                #endif
                if n > 0 { sent += n; continue }
                if errno == EINTR { continue }
                if errno == EPIPE { throw NinePClientError.connectionClosed }
                throw NinePClientError.io(errno: errno, operation: "write")
            }
        }
    }

    /// Closes the socket. Safe to call more than once and from any thread; the
    /// shutdown wakes a reader blocked in `read(2)`.
    public func close() {
        guard closed.testAndSet() == false else { return }
        _ = sysShutdown(fd, Int32(SHUT_RDWR))
        _ = sysClose(fd)
    }

    deinit { close() }
}

/// A tiny test-and-set flag; enough to make `close()` idempotent without
/// pulling in a dependency.
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// True once the flag has been set.
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Sets the flag and returns its previous value.
    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = true
        return old
    }
}
