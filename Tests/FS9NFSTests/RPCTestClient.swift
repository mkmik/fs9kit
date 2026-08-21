// A real ONC RPC client, speaking real XDR over a real TCP socket.
//
// The point of writing one instead of poking at the server's internals is that
// it exercises exactly what macOS's kernel client will: record marking, xid
// matching, out-of-order replies, and the byte-for-byte layout of every reply.

import Foundation
import FS9NFS

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The C functions are wrapped at file scope because the class below has
// methods called `close` and `send`, and an unqualified call inside it would
// resolve to the method instead of the syscall.
private func posixClose(_ fd: Int32) { _ = close(fd) }
private func posixShutdown(_ fd: Int32) { _ = shutdown(fd, Int32(SHUT_RDWR)) }
private func posixSend(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    return write(fd, buffer, count)
    #else
    return send(fd, buffer, count, Int32(MSG_NOSIGNAL))
    #endif
}

enum RPCTestError: Error, CustomStringConvertible {
    case connectFailed(Int32)
    case timedOut
    case closed
    case malformed(String)

    var description: String {
        switch self {
        case let .connectFailed(code): return "connect failed: \(String(cString: strerror(code)))"
        case .timedOut: return "the socket timed out"
        case .closed: return "the peer closed the connection"
        case let .malformed(what): return "malformed reply: \(what)"
        }
    }
}

/// A decoded RPC reply, split into the parts a test wants to assert on.
struct RPCTestReply {
    var xid: UInt32
    /// 0 = MSG_ACCEPTED, 1 = MSG_DENIED.
    var replyStatus: UInt32
    var acceptStatus: UInt32?
    var rejectStatus: UInt32?
    var low: UInt32?
    var high: UInt32?
    var authStatus: UInt32?
    var results: [UInt8]

    var isSuccess: Bool { replyStatus == 0 && acceptStatus == 0 }
    var decoder: XDRDecoder { XDRDecoder(results) }
}

/// One TCP connection to the bridge.
///
/// Every socket operation happens on a private dispatch queue rather than on
/// the caller's task: blocking a cooperative-pool thread while waiting for a
/// server that runs on that same pool is how a test suite deadlocks.
final class RPCTestConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private var leftover: [UInt8] = []
    private let xidLock = NSLock()
    private var nextXID: UInt32 = 0x1000_0000
    private let credentials: AuthSysCredentials?

    // Pipelined mode: one reader thread owns the socket's read side and hands
    // each reply to whoever is waiting on that xid. See `startPipelining()`.
    private let waiterLock = NSLock()
    private var waiters: [UInt32: CheckedContinuation<RPCTestReply, any Error>] = [:]
    private var readerFailure: (any Error)?
    private var pipelining = false

    /// - Parameter receiveBufferSize: when set, shrinks the socket's receive
    ///   buffer. A test that wants the *server's* send to block needs the
    ///   window to fill quickly; the default buffer is megabytes wide.
    init(host: String = "127.0.0.1", port: UInt16,
         credentials: AuthSysCredentials? = AuthSysCredentials(
            stamp: 1, machineName: "fs9kit-test", uid: 501, gid: 20, groups: [20, 12]),
         timeout: TimeInterval = 10, receiveBufferSize: Int32? = nil) throws {
        #if canImport(Darwin)
        let stream = SOCK_STREAM
        #else
        let stream = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_INET, stream, 0)
        guard fd >= 0 else { throw RPCTestError.connectFailed(errno) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        _ = host.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let rc = withUnsafePointer(to: &address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let code = errno
            posixClose(fd)
            throw RPCTestError.connectFailed(code)
        }
        // Every socket operation is bounded so a bug in the server shows up as
        // a failing test rather than a suite that never finishes.
        var tv = timeval()
        tv.tv_sec = Int(timeout)
        tv.tv_usec = 0
        _ = withUnsafePointer(to: &tv) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &tv) {
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        if var size = receiveBufferSize {
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        self.fd = fd
        self.credentials = credentials
        self.queue = DispatchQueue(label: "fs9kit.nfs.test.\(port).\(UInt32.random(in: 0...UInt32.max))")
    }

    deinit { posixClose(fd) }

    func close() {
        posixShutdown(fd)
    }

    // MARK: Framing

    /// Builds a complete `call_body` with the given arguments appended.
    func encodeCall(xid: UInt32, program: UInt32, version: UInt32, procedure: UInt32,
                    arguments: [UInt8]) -> [UInt8] {
        var e = XDREncoder()
        e.uint32(xid)
        e.uint32(0)  // CALL
        e.uint32(2)  // rpcvers
        e.uint32(program)
        e.uint32(version)
        e.uint32(procedure)
        if let credentials {
            var body = XDREncoder()
            body.uint32(credentials.stamp)
            body.string(credentials.machineName)
            body.uint32(credentials.uid)
            body.uint32(credentials.gid)
            body.array(credentials.groups) { $0.uint32($1) }
            e.uint32(1)  // AUTH_SYS
            e.opaqueVariable(body.bytes)
        } else {
            e.uint32(0)  // AUTH_NONE
            e.uint32(0)
        }
        e.uint32(0)  // verifier: AUTH_NONE
        e.uint32(0)
        e.appendRaw(arguments)
        return e.bytes
    }

    func allocateXID() -> UInt32 {
        xidLock.withLock {
            nextXID &+= 1
            return nextXID
        }
    }

    // MARK: Pipelining

    /// Starts a reader thread so many calls can be outstanding at once.
    ///
    /// This is what the kernel's NFS client does — it does not wait for one
    /// reply before sending the next request — and it is the one thing the
    /// request/reply `call` above cannot reproduce, because its reply wait
    /// occupies the same serial queue the next request would need.
    ///
    /// After this, use `pipelinedCall` only: `receive()` would race the reader
    /// thread for the same bytes.
    func startPipelining() {
        waiterLock.lock()
        guard !pipelining else { waiterLock.unlock(); return }
        pipelining = true
        waiterLock.unlock()
        let thread = Thread { [weak self] in
            while true {
                guard let self else { return }
                do {
                    let reply = try Self.decodeReply(self.blockingReadRecord())
                    let waiter = self.waiterLock.withLock { self.waiters.removeValue(forKey: reply.xid) }
                    waiter?.resume(returning: reply)
                } catch {
                    let stranded: [CheckedContinuation<RPCTestReply, any Error>] =
                        self.waiterLock.withLock {
                            self.readerFailure = error
                            let all = Array(self.waiters.values)
                            self.waiters.removeAll()
                            return all
                        }
                    for waiter in stranded { waiter.resume(throwing: error) }
                    return
                }
            }
        }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Sends a call and waits for its reply without holding up other calls.
    func pipelinedCall(program: UInt32, version: UInt32, procedure: UInt32,
                       arguments: [UInt8] = []) async throws -> RPCTestReply {
        let id = allocateXID()
        let payload = encodeCall(xid: id, program: program, version: version,
                                 procedure: procedure, arguments: arguments)
        return try await withCheckedThrowingContinuation { continuation in
            let failure: (any Error)? = waiterLock.withLock {
                if let readerFailure { return readerFailure }
                waiters[id] = continuation
                return nil
            }
            if let failure { continuation.resume(throwing: failure); return }
            queue.async {
                do {
                    try self.blockingWrite(self.frame(payload))
                } catch {
                    let waiter = self.waiterLock.withLock { self.waiters.removeValue(forKey: id) }
                    waiter?.resume(throwing: error)
                }
            }
        }
    }

    /// Writes raw bytes with no framing, for the record-marking tests.
    func sendRaw(_ bytes: [UInt8]) async throws {
        try await onQueue { try self.blockingWrite(bytes) }
    }

    /// Sends one call as a single fragment and does not wait for the reply.
    @discardableResult
    func send(program: UInt32, version: UInt32, procedure: UInt32,
              arguments: [UInt8] = [], xid: UInt32? = nil) async throws -> UInt32 {
        let id = xid ?? allocateXID()
        let payload = encodeCall(xid: id, program: program, version: version,
                                 procedure: procedure, arguments: arguments)
        try await sendRaw(frame(payload))
        return id
    }

    /// Reads and decodes the next reply on the connection.
    func receive() async throws -> RPCTestReply {
        let record = try await onQueue { try self.blockingReadRecord() }
        return try Self.decodeReply(record)
    }

    /// Sends a call and waits for its reply, checking the xid matches.
    func call(program: UInt32, version: UInt32, procedure: UInt32,
              arguments: [UInt8] = []) async throws -> RPCTestReply {
        let id = try await send(program: program, version: version,
                                procedure: procedure, arguments: arguments)
        let reply = try await receive()
        guard reply.xid == id else {
            throw RPCTestError.malformed("xid \(reply.xid) does not echo \(id)")
        }
        return reply
    }

    /// Wraps a payload as a single last-fragment record.
    func frame(_ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        let header = UInt32(payload.count) | 0x8000_0000
        for shift in stride(from: 24, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: header >> UInt32(shift)))
        }
        out.append(contentsOf: payload)
        return out
    }

    /// Wraps a payload as several fragments, only the last of which is marked.
    func fragmented(_ payload: [UInt8], pieces: Int) -> [UInt8] {
        var out: [UInt8] = []
        let size = max(1, payload.count / max(1, pieces))
        var index = 0
        while index < payload.count {
            let end = min(payload.count, index + size)
            let isLast = end == payload.count
            var header = UInt32(end - index)
            if isLast { header |= 0x8000_0000 }
            for shift in stride(from: 24, through: 0, by: -8) {
                out.append(UInt8(truncatingIfNeeded: header >> UInt32(shift)))
            }
            out.append(contentsOf: payload[index..<end])
            index = end
        }
        return out
    }

    static func decodeReply(_ bytes: [UInt8]) throws -> RPCTestReply {
        var d = XDRDecoder(bytes)
        let xid = try d.uint32()
        guard try d.uint32() == 1 else { throw RPCTestError.malformed("not a REPLY") }
        let replyStatus = try d.uint32()
        var reply = RPCTestReply(xid: xid, replyStatus: replyStatus, results: [])
        if replyStatus == 0 {
            _ = try d.uint32()                        // verifier flavor
            _ = try d.opaqueVariable(limit: 400)      // verifier body
            let accept = try d.uint32()
            reply.acceptStatus = accept
            if accept == 2 {                          // PROG_MISMATCH
                reply.low = try d.uint32()
                reply.high = try d.uint32()
            }
        } else {
            let reject = try d.uint32()
            reply.rejectStatus = reject
            if reject == 0 {                          // RPC_MISMATCH
                reply.low = try d.uint32()
                reply.high = try d.uint32()
            } else {
                reply.authStatus = try d.uint32()
            }
        }
        reply.results = Array(bytes[d.index...])
        return reply
    }

    // MARK: Blocking primitives

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func blockingWrite(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written: Int = bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                return posixSend(fd, base + offset, bytes.count - offset)
            }
            if written <= 0 {
                if written < 0 && errno == EINTR { continue }
                if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    throw RPCTestError.timedOut
                }
                throw RPCTestError.closed
            }
            offset += written
        }
    }

    /// Reads one whole RPC message, reassembling fragments.
    private func blockingReadRecord() throws -> [UInt8] {
        var message: [UInt8] = []
        while true {
            let header = try blockingReadExactly(4)
            let value = UInt32(header[0]) << 24 | UInt32(header[1]) << 16
                | UInt32(header[2]) << 8 | UInt32(header[3])
            let isLast = value & 0x8000_0000 != 0
            let length = Int(value & 0x7fff_ffff)
            if length > 0 { message.append(contentsOf: try blockingReadExactly(length)) }
            if isLast { return message }
        }
    }

    private func blockingReadExactly(_ count: Int) throws -> [UInt8] {
        while leftover.count < count {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n: Int = chunk.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, raw.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw RPCTestError.timedOut }
                throw RPCTestError.closed
            }
            if n == 0 { throw RPCTestError.closed }
            leftover.append(contentsOf: chunk[0..<n])
        }
        let head = Array(leftover[0..<count])
        leftover.removeFirst(count)
        return head
    }

    /// True when the peer has closed and nothing more will arrive. Used to
    /// prove an oversized record drops the connection instead of wedging it.
    func expectEOF() async -> Bool {
        (try? await onQueue { _ = try self.blockingReadExactly(1); return false }) ?? true
    }
}
