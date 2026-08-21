import Foundation
import NineP
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Errors raised while setting a server up. Once a connection is running,
/// failures are reported to the peer as 9P errors instead.
public enum NinePServerStartupError: Error, Sendable, CustomStringConvertible {
    case socket(String, Int32)
    case alreadyRunning
    case pathTooLong(String)

    public var description: String {
        switch self {
        case let .socket(what, code): return "\(what) failed: \(String(cString: strerror(code)))"
        case .alreadyRunning: return "the server is already running"
        case let .pathTooLong(path): return "socket path is too long: \(path)"
        }
    }
}

/// A 9P server: accepts connections and runs a ``NinePServerSession`` on each.
///
/// One thread accepts on each endpoint and one thread serves each connection,
/// with blocking reads. That is a lot of threads for a huge fanout, but this
/// server exists to back tests and debugging sessions where a handful of
/// connections is the norm, and blocking I/O keeps the framing code readable.
public final class NinePServer: @unchecked Sendable {
    public typealias Configuration = NinePServerConfiguration

    public let fileSystem: any NinePFileServer
    public let configuration: Configuration

    private let lock = NSLock()
    private let quiesced = NSCondition()
    private var running = false
    private var listeners: [Int32] = []
    private var unixPaths: [String] = []
    private var connections: Set<Int32> = []
    private var liveThreads = 0
    private var endpoints: [NinePEndpoint] = []

    public init(fileSystem: any NinePFileServer, configuration: Configuration = Configuration()) {
        self.fileSystem = fileSystem
        self.configuration = configuration
    }

    deinit { stop() }

    /// The addresses actually bound, with ephemeral ports resolved.
    public var boundEndpoints: [NinePEndpoint] { lock.withLock { endpoints } }

    /// Convenience for the common single-TCP-endpoint case.
    public var boundPort: Int? { boundEndpoints.compactMap(\.port).first }

    /// Binds every configured endpoint and starts accepting.
    @discardableResult
    public func start() throws -> [NinePEndpoint] {
        try lock.withLock {
            guard !running else { throw NinePServerStartupError.alreadyRunning }
            var bound: [NinePEndpoint] = []
            do {
                for endpoint in configuration.endpoints {
                    let (fd, resolved) = try listen(on: endpoint)
                    listeners.append(fd)
                    bound.append(resolved)
                    if case let .unix(path) = resolved { unixPaths.append(path) }
                }
            } catch {
                for fd in listeners { sysClose(fd) }
                listeners.removeAll()
                for path in unixPaths { _ = sysUnlink(path) }
                unixPaths.removeAll()
                throw error
            }
            endpoints = bound
            running = true
            for fd in listeners {
                spawn { [weak self] in self?.acceptLoop(listener: fd) }
            }
            return bound
        }
    }

    /// Stops accepting, drops every live connection and waits for the threads.
    ///
    /// Blocked reads are woken by shutting the sockets down; closing alone is
    /// not enough, because another thread still holds the descriptor.
    public func stop() {
        let (wasRunning, listenerFDs, connectionFDs, paths) =
            lock.withLock { () -> (Bool, [Int32], [Int32], [String]) in
                guard running else { return (false, [], [], []) }
                running = false
                let listenerFDs = listeners
                let connectionFDs = Array(connections)
                let paths = unixPaths
                listeners.removeAll()
                unixPaths.removeAll()
                endpoints.removeAll()
                return (true, listenerFDs, connectionFDs, paths)
            }
        guard wasRunning else { return }

        // Every descriptor is shut down so the thread blocked in `read` on it
        // wakes up, but only the listeners are closed here.
        //
        // A connection's descriptor belongs to the thread serving it, which
        // closes it once `run()` returns. Closing it here as well would be a
        // double close, and the window between them is long enough for another
        // thread to be handed the same number by `accept` or `socket` — after
        // which the second close silently kills somebody else's live socket.
        // That showed up as EBADF and as one protocol's bytes arriving on
        // another protocol's connection.
        for fd in connectionFDs { sysShutdown(fd) }
        for fd in listenerFDs { sysShutdown(fd) }
        for fd in listenerFDs { sysClose(fd) }
        for path in paths { _ = sysUnlink(path) }

        // Waiting for the serving threads is what makes the descriptors above
        // actually gone by the time this returns.
        quiesced.lock()
        let deadline = Date().addingTimeInterval(5)
        while liveThreads > 0, quiesced.wait(until: deadline) {}
        quiesced.unlock()
    }

    // MARK: - Listening

    private func listen(on endpoint: NinePEndpoint) throws -> (fd: Int32, resolved: NinePEndpoint) {
        switch endpoint {
        case let .fileDescriptor(fd):
            // An inherited listening socket: the caller already bound it, so
            // there is nothing to resolve.
            guard sysListen(fd, configuration.backlog) == 0 || sysErrno() == EINVAL else {
                throw NinePServerStartupError.socket("listen", sysErrno())
            }
            return (fd, endpoint)

        case let .tcp(host, port):
            let fd = sysSocket(AF_INET, sysSockStream, 0)
            guard fd >= 0 else { throw NinePServerStartupError.socket("socket", sysErrno()) }
            sysSetIntOption(fd, SOL_SOCKET, SO_REUSEADDR, 1)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port)).bigEndian
            guard host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
                sysClose(fd)
                throw NinePServerStartupError.socket("inet_pton(\(host))", EINVAL)
            }
            #if canImport(Darwin)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            let bindResult = withUnsafePointer(to: &addr) { raw in
                raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sysBind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                let code = sysErrno()
                sysClose(fd)
                throw NinePServerStartupError.socket("bind", code)
            }
            guard sysListen(fd, configuration.backlog) == 0 else {
                let code = sysErrno()
                sysClose(fd)
                throw NinePServerStartupError.socket("listen", code)
            }
            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let assigned = withUnsafeMutablePointer(to: &actual) { raw in
                raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sysGetSockName(fd, $0, &length)
                }
            }
            let realPort = assigned == 0 ? Int(UInt16(bigEndian: actual.sin_port)) : port
            return (fd, .tcp(host: host, port: realPort))

        case let .unix(path):
            var addr = sockaddr_un()
            let capacity = MemoryLayout.size(ofValue: addr.sun_path)
            let bytes = Array(path.utf8)
            guard bytes.count < capacity else { throw NinePServerStartupError.pathTooLong(path) }
            let fd = sysSocket(AF_UNIX, sysSockStream, 0)
            guard fd >= 0 else { throw NinePServerStartupError.socket("socket", sysErrno()) }
            addr.sun_family = sa_family_t(AF_UNIX)
            #if canImport(Darwin)
            addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            #endif
            withUnsafeMutablePointer(to: &addr.sun_path) { raw in
                raw.withMemoryRebound(to: CChar.self, capacity: capacity) { slot in
                    for (i, byte) in bytes.enumerated() { slot[i] = CChar(bitPattern: byte) }
                    slot[bytes.count] = 0
                }
            }
            // A leftover socket file from a crashed run would make bind fail;
            // only a socket is safe to clear away.
            var existing = stat()
            if sysLstat(path, &existing) == 0,
               UInt32(existing.st_mode) & PosixFileType.mask == PosixFileType.sock {
                _ = sysUnlink(path)
            }
            let bindResult = withUnsafePointer(to: &addr) { raw in
                raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sysBind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else {
                let code = sysErrno()
                sysClose(fd)
                throw NinePServerStartupError.socket("bind", code)
            }
            guard sysListen(fd, configuration.backlog) == 0 else {
                let code = sysErrno()
                sysClose(fd)
                throw NinePServerStartupError.socket("listen", code)
            }
            return (fd, .unix(path: path))
        }
    }

    private func acceptLoop(listener: Int32) {
        while lock.withLock({ running }) {
            let fd = sysAccept(listener)
            if fd < 0 {
                if sysErrno() == EINTR { continue }
                break
            }
            let accepted: Bool = lock.withLock {
                guard running else { return false }
                connections.insert(fd)
                return true
            }
            guard accepted else {
                sysShutdown(fd)
                sysClose(fd)
                break
            }
            spawn { [weak self] in self?.serve(connection: fd) }
        }
    }

    private func serve(connection fd: Int32) {
        #if canImport(Darwin)
        sysSetIntOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
        #endif
        if configuration.receiveTimeout > 0 {
            var tv = timeval(tv_sec: Int(configuration.receiveTimeout),
                             tv_usec: 0)
            _ = withUnsafePointer(to: &tv) {
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            }
        }
        let connection = NinePConnection(
            fd: fd,
            session: NinePServerSession(fileSystem: fileSystem, configuration: configuration),
            configuration: configuration)
        connection.run()
        lock.withLock { _ = connections.remove(fd) }
        sysClose(fd)
    }

    /// `liveThreads` is guarded by `quiesced` rather than `lock` so that the
    /// wait in ``stop()`` cannot miss a wakeup.
    private func spawn(_ body: @escaping @Sendable () -> Void) {
        quiesced.lock()
        liveThreads += 1
        quiesced.unlock()
        let thread = Thread { [quiesced] in
            body()
            quiesced.lock()
            self.liveThreads -= 1
            quiesced.broadcast()
            quiesced.unlock()
        }
        thread.stackSize = 512 * 1024
        thread.start()
    }
}
