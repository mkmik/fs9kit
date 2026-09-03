// ONC RPC version 2 (RFC 5531) over TCP, including the record-marking layer
// of RFC 5531 §11.
//
// Two things here are easy to get wrong and expensive to debug against a real
// kernel client:
//
//  * **Record marking.** A message is a chain of fragments, each with a
//    four-byte big-endian header whose top bit means "last fragment" and whose
//    low 31 bits are the fragment's length. A client is free to split one call
//    across several fragments, so a reader that assumes one fragment per
//    message will silently mis-frame under load.
//  * **Reply ordering.** macOS keeps many calls outstanding on a single
//    connection and matches replies by xid, not by arrival order. So requests
//    are handled concurrently and only the *writes* are serialised; making the
//    whole connection serial would turn every slow 9P round trip into a stall
//    for every other request on the mount.

import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Constants

public enum RPCConstants {
    public static let version: UInt32 = 2

    public static let call: UInt32 = 0
    public static let reply: UInt32 = 1

    public static let messageAccepted: UInt32 = 0
    public static let messageDenied: UInt32 = 1

    public static let authNone: UInt32 = 0
    public static let authSys: UInt32 = 1

    /// Largest AUTH_SYS credential body RFC 5531 allows.
    public static let maximumAuthBodySize = 400
    /// AUTH_SYS carries at most 16 supplementary groups.
    public static let maximumSupplementaryGroups = 16
}

/// `accept_stat`, the outcome of a call the server was willing to look at.
public enum RPCAcceptStatus: UInt32, Sendable {
    case success = 0
    case programUnavailable = 1
    case programMismatch = 2
    case procedureUnavailable = 3
    case garbageArguments = 4
    case systemError = 5
}

/// `auth_stat`, the reason an authentication was refused.
public enum RPCAuthStatus: UInt32, Sendable {
    case ok = 0
    case badCredential = 1
    case rejectedCredential = 2
    case badVerifier = 3
    case rejectedVerifier = 4
    case tooWeak = 5
    case invalidResponse = 6
    case failed = 7
}

// MARK: - Credentials

/// AUTH_SYS (a.k.a. AUTH_UNIX) credentials, RFC 5531 appendix A.
///
/// These are advisory — anyone who can reach the port can claim any uid — but
/// the NFS layer needs them to answer ACCESS and to decide permission bits, so
/// they are recorded per request.
public struct AuthSysCredentials: Sendable, Hashable {
    public var stamp: UInt32
    public var machineName: String
    public var uid: UInt32
    public var gid: UInt32
    public var groups: [UInt32]

    public init(stamp: UInt32 = 0, machineName: String = "", uid: UInt32 = 0,
                gid: UInt32 = 0, groups: [UInt32] = []) {
        self.stamp = stamp
        self.machineName = machineName
        self.uid = uid
        self.gid = gid
        self.groups = groups
    }

    /// True when `gid` or any supplementary group matches.
    public func belongsToGroup(_ candidate: UInt32) -> Bool {
        gid == candidate || groups.contains(candidate)
    }

    static func decode(_ body: [UInt8]) throws -> AuthSysCredentials {
        var d = XDRDecoder(body, defaultLimit: RPCConstants.maximumAuthBodySize)
        let stamp = try d.uint32()
        let machine = try d.string(limit: 255)
        let uid = try d.uint32()
        let gid = try d.uint32()
        let groups = try d.array(limit: RPCConstants.maximumSupplementaryGroups) { try $0.uint32() }
        return AuthSysCredentials(stamp: stamp, machineName: machine, uid: uid, gid: gid, groups: groups)
    }
}

/// Everything a program handler knows about the call it is answering.
public struct RPCContext: Sendable {
    public var xid: UInt32
    public var program: UInt32
    public var version: UInt32
    public var procedure: UInt32
    /// Present only for AUTH_SYS; AUTH_NONE calls (NULL pings, and MOUNT from
    /// some clients) carry nothing.
    public var credentials: AuthSysCredentials?
    public var credentialFlavor: UInt32

    public init(xid: UInt32, program: UInt32, version: UInt32, procedure: UInt32,
                credentials: AuthSysCredentials? = nil,
                credentialFlavor: UInt32 = RPCConstants.authNone) {
        self.xid = xid
        self.program = program
        self.version = version
        self.procedure = procedure
        self.credentials = credentials
        self.credentialFlavor = credentialFlavor
    }

    /// The uid to attribute the call to; unauthenticated calls are nobody.
    public var uid: UInt32 { credentials?.uid ?? 65534 }
    public var gid: UInt32 { credentials?.gid ?? 65534 }
}

// MARK: - Call decoding

/// A decoded `call_body` plus a cursor positioned at the procedure arguments.
public struct RPCCall: Sendable {
    public var context: RPCContext
    public var arguments: XDRDecoder
}

/// Failures that stop a call from being dispatched at all.
public enum RPCDecodeError: Error, Equatable, Sendable {
    /// The message was a reply, or the type field was nonsense.
    case notACall(UInt32)
    /// `rpcvers` was not 2. The xid is carried so a RPC_MISMATCH reply can
    /// still be addressed correctly.
    case versionMismatch(xid: UInt32, offered: UInt32)
    /// The header was truncated or otherwise unusable.
    case malformedHeader
}

public enum RPCMessage {
    /// Decodes a call header and leaves the decoder on the arguments.
    public static func decodeCall(_ bytes: [UInt8], argumentLimit: Int) throws -> RPCCall {
        var d = XDRDecoder(bytes, defaultLimit: argumentLimit)
        let xid: UInt32
        let type: UInt32
        do {
            xid = try d.uint32()
            type = try d.uint32()
        } catch {
            throw RPCDecodeError.malformedHeader
        }
        guard type == RPCConstants.call else { throw RPCDecodeError.notACall(type) }
        let rpcVersion: UInt32
        do { rpcVersion = try d.uint32() } catch { throw RPCDecodeError.malformedHeader }
        guard rpcVersion == RPCConstants.version else {
            throw RPCDecodeError.versionMismatch(xid: xid, offered: rpcVersion)
        }

        do {
            let program = try d.uint32()
            let version = try d.uint32()
            let procedure = try d.uint32()

            let credentialFlavor = try d.uint32()
            let credentialBody = try d.opaqueVariable(limit: RPCConstants.maximumAuthBodySize)
            // The verifier is ignored: AUTH_SYS defines none, and we accept
            // AUTH_NONE, so there is nothing to check. It still has to be
            // consumed to reach the arguments.
            _ = try d.uint32()
            _ = try d.opaqueVariable(limit: RPCConstants.maximumAuthBodySize)

            // A malformed AUTH_SYS body is not fatal: treat the call as
            // unauthenticated rather than dropping a mount over it.
            let credentials = credentialFlavor == RPCConstants.authSys
                ? try? AuthSysCredentials.decode(credentialBody)
                : nil

            let context = RPCContext(
                xid: xid, program: program, version: version, procedure: procedure,
                credentials: credentials, credentialFlavor: credentialFlavor)
            return RPCCall(context: context, arguments: d)
        } catch {
            throw RPCDecodeError.malformedHeader
        }
    }

    // MARK: Reply encoding

    private static func acceptedHeader(xid: UInt32, status: RPCAcceptStatus) -> XDREncoder {
        var e = XDREncoder()
        e.uint32(xid)
        e.uint32(RPCConstants.reply)
        e.uint32(RPCConstants.messageAccepted)
        // Reply verifier: AUTH_NONE with an empty body, which is what every
        // flavor we accept calls for.
        e.uint32(RPCConstants.authNone)
        e.uint32(0)
        e.uint32(status.rawValue)
        return e
    }

    public static func success(xid: UInt32, results: [UInt8]) -> [UInt8] {
        var e = acceptedHeader(xid: xid, status: .success)
        e.appendRaw(results)
        return e.bytes
    }

    public static func programUnavailable(xid: UInt32) -> [UInt8] {
        acceptedHeader(xid: xid, status: .programUnavailable).bytes
    }

    /// PROG_MISMATCH carries the version range the server does support, so the
    /// client can retry instead of giving up.
    public static func programMismatch(xid: UInt32, low: UInt32, high: UInt32) -> [UInt8] {
        var e = acceptedHeader(xid: xid, status: .programMismatch)
        e.uint32(low)
        e.uint32(high)
        return e.bytes
    }

    public static func procedureUnavailable(xid: UInt32) -> [UInt8] {
        acceptedHeader(xid: xid, status: .procedureUnavailable).bytes
    }

    public static func garbageArguments(xid: UInt32) -> [UInt8] {
        acceptedHeader(xid: xid, status: .garbageArguments).bytes
    }

    public static func systemError(xid: UInt32) -> [UInt8] {
        acceptedHeader(xid: xid, status: .systemError).bytes
    }

    public static func rpcMismatch(xid: UInt32, low: UInt32, high: UInt32) -> [UInt8] {
        var e = XDREncoder()
        e.uint32(xid)
        e.uint32(RPCConstants.reply)
        e.uint32(RPCConstants.messageDenied)
        e.uint32(0)  // RPC_MISMATCH
        e.uint32(low)
        e.uint32(high)
        return e.bytes
    }

    public static func authError(xid: UInt32, status: RPCAuthStatus) -> [UInt8] {
        var e = XDREncoder()
        e.uint32(xid)
        e.uint32(RPCConstants.reply)
        e.uint32(RPCConstants.messageDenied)
        e.uint32(1)  // AUTH_ERROR
        e.uint32(status.rawValue)
        return e.bytes
    }
}

// MARK: - Record marking

public enum RPCFramingError: Error, Equatable, Sendable {
    /// The reassembled message would exceed the configured ceiling. The
    /// connection is dropped rather than continuing to buffer.
    case recordTooLarge(limit: Int)
}

/// Wraps a payload as a single last-fragment record.
///
/// Replies are always one fragment: there is no benefit to splitting them, and
/// every client accepts a single fragment.
public func rpcFrame(_ payload: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(payload.count + 4)
    let header = UInt32(truncatingIfNeeded: payload.count) | 0x8000_0000
    out.append(UInt8(truncatingIfNeeded: header >> 24))
    out.append(UInt8(truncatingIfNeeded: header >> 16))
    out.append(UInt8(truncatingIfNeeded: header >> 8))
    out.append(UInt8(truncatingIfNeeded: header))
    out.append(contentsOf: payload)
    return out
}

/// Reassembles record-marked fragments into whole RPC messages.
///
/// Kept as a value type with no I/O so the framing rules can be tested without
/// a socket, which is where the fiddly cases (a header split across two reads,
/// a message split across three fragments) actually live.
public struct RPCRecordAssembler: Sendable {
    public let maximumRecordSize: Int
    /// Bytes received but not yet forming a complete fragment.
    private var pending: [UInt8] = []
    /// Fragments of the message being assembled.
    private var message: [UInt8] = []

    public init(maximumRecordSize: Int = 1 << 21) {
        self.maximumRecordSize = maximumRecordSize
    }

    /// Feeds freshly read bytes in and returns every message completed by them.
    public mutating func push<C: Collection>(_ incoming: C) throws -> [[UInt8]]
    where C.Element == UInt8 {
        pending.append(contentsOf: incoming)
        var completed: [[UInt8]] = []
        while true {
            guard pending.count >= 4 else { break }
            let header = UInt32(pending[0]) << 24 | UInt32(pending[1]) << 16
                | UInt32(pending[2]) << 8 | UInt32(pending[3])
            let isLast = header & 0x8000_0000 != 0
            let length = Int(header & 0x7fff_ffff)
            guard length <= maximumRecordSize, message.count + length <= maximumRecordSize else {
                throw RPCFramingError.recordTooLarge(limit: maximumRecordSize)
            }
            guard pending.count >= 4 + length else { break }
            message.append(contentsOf: pending[4..<(4 + length)])
            pending.removeFirst(4 + length)
            if isLast {
                completed.append(message)
                message = []
            }
        }
        return completed
    }
}

// MARK: - Programs

/// A failure a program handler can raise that maps onto an RPC accept status.
public enum RPCProgramError: Error, Equatable, Sendable {
    case procedureUnavailable
    case garbageArguments
    case systemError(String)
}

/// One RPC program: a program number, the versions it answers, and a
/// dispatcher.
///
/// The handler returns the encoded *results* only; the accepted-reply header is
/// added by the server.
public protocol RPCProgram: Sendable {
    var program: UInt32 { get }
    var versions: ClosedRange<UInt32> { get }
    func call(procedure: UInt32, arguments: XDRDecoder, context: RPCContext) async throws -> [UInt8]
}

// MARK: - Server

public struct RPCServerOptions: Sendable {
    public var host: String
    /// 0 asks the kernel for an ephemeral port; ``RPCServer/boundPort`` reports
    /// what it chose.
    public var port: UInt16
    public var backlog: Int32
    /// Ceiling on a reassembled request. NFS WRITEs are bounded by the wsize
    /// we advertise, so anything far above that is a peer misbehaving.
    public var maximumRecordSize: Int
    /// Applied to accepted connections so a stalled peer cannot pin a thread
    /// forever. Zero blocks; ``RPCServer/stop()`` still wakes the read by
    /// shutting the socket down.
    public var receiveTimeout: TimeInterval
    public var sendTimeout: TimeInterval

    public init(host: String = "127.0.0.1", port: UInt16 = 0, backlog: Int32 = 64,
                maximumRecordSize: Int = 1 << 21,
                receiveTimeout: TimeInterval = 0, sendTimeout: TimeInterval = 30) {
        self.host = host
        self.port = port
        self.backlog = backlog
        self.maximumRecordSize = maximumRecordSize
        self.receiveTimeout = receiveTimeout
        self.sendTimeout = sendTimeout
    }
}

public enum RPCServerError: Error, Sendable, CustomStringConvertible {
    case socket(String, Int32)
    case badHost(String)
    case alreadyRunning
    case notRunning

    public var description: String {
        switch self {
        case let .socket(what, code): return "\(what) failed: \(String(cString: strerror(code)))"
        case let .badHost(host): return "not an IPv4 address: \(host)"
        case .alreadyRunning: return "the RPC server is already running"
        case .notRunning: return "the RPC server is not running"
        }
    }
}

/// A TCP ONC RPC server.
///
/// One thread accepts, one thread reads each connection, and each request is
/// handled in its own task. Writes are serialised per connection by a lock;
/// nothing else is.
public final class RPCServer: @unchecked Sendable {
    public let options: RPCServerOptions
    private let programs: [any RPCProgram]

    private let lock = NSLock()
    private var running = false
    private var listener: Int32 = -1
    private var assignedPort: UInt16?
    private var connections: [ObjectIdentifier: Connection] = [:]

    private let quiesced = NSCondition()
    private var liveThreads = 0

    public init(programs: [any RPCProgram], options: RPCServerOptions = RPCServerOptions()) {
        self.programs = programs
        self.options = options
    }

    deinit { stop() }

    /// The port in use once ``start()`` has returned.
    public var boundPort: UInt16? { lock.withLock { assignedPort } }

    @discardableResult
    public func start() throws -> UInt16 {
        try lock.withLock {
            guard !running else { throw RPCServerError.alreadyRunning }
            guard let address = nfsMakeAddress(host: options.host, port: options.port) else {
                throw RPCServerError.badHost(options.host)
            }
            let fd = socket(AF_INET, nfsSockStream, 0)
            guard fd >= 0 else { throw RPCServerError.socket("socket", nfsErrno()) }
            nfsSetIntOption(fd, SOL_SOCKET, SO_REUSEADDR, 1)
            guard nfsBind(fd, address) == 0 else {
                let code = nfsErrno()
                nfsClose(fd)
                throw RPCServerError.socket("bind", code)
            }
            guard listen(fd, options.backlog) == 0 else {
                let code = nfsErrno()
                nfsClose(fd)
                throw RPCServerError.socket("listen", code)
            }
            guard let port = nfsBoundPort(fd) else {
                nfsClose(fd)
                throw RPCServerError.socket("getsockname", nfsErrno())
            }
            listener = fd
            assignedPort = port
            running = true
            spawn { [weak self] in self?.acceptLoop(fd) }
            return port
        }
    }

    /// Stops accepting, drops live connections and waits for the threads.
    ///
    /// Sockets are shut down before they are closed: another thread is blocked
    /// in `read` on the same descriptor, and only a shutdown wakes it.
    public func stop() {
        let victims: [Connection] = lock.withLock {
            guard running else { return [] }
            running = false
            if listener >= 0 {
                nfsShutdown(listener)
                nfsClose(listener)
                listener = -1
            }
            assignedPort = nil
            let all = Array(connections.values)
            connections.removeAll()
            return all
        }
        for connection in victims { connection.shutdown() }

        quiesced.lock()
        let deadline = Date().addingTimeInterval(5)
        while liveThreads > 0, quiesced.wait(until: deadline) {}
        quiesced.unlock()
    }

    private func acceptLoop(_ listenerFD: Int32) {
        while lock.withLock({ running }) {
            let fd = accept(listenerFD, nil, nil)
            if fd < 0 {
                if nfsErrno() == EINTR { continue }
                break
            }
            #if canImport(Darwin)
            nfsSetIntOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
            #endif
            nfsSetIntOption(fd, Int32(IPPROTO_TCP), TCP_NODELAY, 1)
            nfsSetTimeout(fd, SO_RCVTIMEO, seconds: options.receiveTimeout)
            nfsSetTimeout(fd, SO_SNDTIMEO, seconds: options.sendTimeout)

            let connection = Connection(fd: fd, server: self)
            let accepted: Bool = lock.withLock {
                guard running else { return false }
                connections[ObjectIdentifier(connection)] = connection
                return true
            }
            guard accepted else {
                nfsShutdown(fd)
                nfsClose(fd)
                break
            }
            spawn { [weak self] in
                connection.run()
                self?.forget(connection)
            }
        }
    }

    private func forget(_ connection: Connection) {
        lock.withLock { _ = connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    /// Runs one call against the matching program and encodes a complete reply.
    fileprivate func dispatch(_ call: RPCCall) async -> [UInt8] {
        let xid = call.context.xid
        let matching = programs.filter { $0.program == call.context.program }
        guard !matching.isEmpty else { return RPCMessage.programUnavailable(xid: xid) }
        guard let program = matching.first(where: { $0.versions.contains(call.context.version) }) else {
            let low = matching.map(\.versions.lowerBound).min() ?? 0
            let high = matching.map(\.versions.upperBound).max() ?? 0
            return RPCMessage.programMismatch(xid: xid, low: low, high: high)
        }
        do {
            let results = try await program.call(
                procedure: call.context.procedure,
                arguments: call.arguments,
                context: call.context)
            return RPCMessage.success(xid: xid, results: results)
        } catch RPCProgramError.procedureUnavailable {
            return RPCMessage.procedureUnavailable(xid: xid)
        } catch RPCProgramError.garbageArguments {
            return RPCMessage.garbageArguments(xid: xid)
        } catch is XDRError {
            // Anything that failed to decode is the client's fault, not ours.
            return RPCMessage.garbageArguments(xid: xid)
        } catch {
            return RPCMessage.systemError(xid: xid)
        }
    }

    /// `liveThreads` is guarded by `quiesced` rather than `lock` so the wait in
    /// ``stop()`` cannot miss a wakeup.
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

    // MARK: One connection

    fileprivate final class Connection: @unchecked Sendable {
        private let fd: Int32
        private unowned let server: RPCServer
        /// Every reply is written here, never on the thread that produced it.
        ///
        /// A reply write is a blocking `send`, and it blocks for real once the
        /// peer stops draining — a kernel NFS client with several large READs
        /// outstanding does exactly that. The handler that produces a reply
        /// runs in a `Task`, so it is on a cooperative pool thread, and that
        /// pool has about one thread per core. Blocking a few of them at once
        /// wedges the entire Swift concurrency runtime: no task anywhere can
        /// run, so nothing ever drains the socket, so the writes never finish.
        /// Handing the write to a queue of its own keeps the pool free, and
        /// being serial it also keeps two replies from being spliced together
        /// on the wire.
        private let writeQueue: DispatchQueue
        private let state = NSCondition()
        private var inFlight = 0
        private var closed = false

        init(fd: Int32, server: RPCServer) {
            self.fd = fd
            self.server = server
            self.writeQueue = DispatchQueue(label: "fs9kit.nfs.rpc.write.\(fd)")
        }

        func shutdown() {
            state.lock()
            let alreadyClosed = closed
            closed = true
            state.unlock()
            if !alreadyClosed { nfsShutdown(fd) }
        }

        func run() {
            var assembler = RPCRecordAssembler(maximumRecordSize: server.options.maximumRecordSize)
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            readLoop: while true {
                let n = buffer.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return nfsReceive(fd, base, raw.count)
                }
                if n < 0 {
                    let code = nfsErrno()
                    if code == EINTR { continue }
                    break
                }
                if n == 0 { break }
                let messages: [[UInt8]]
                do {
                    messages = try assembler.push(buffer[0..<n])
                } catch {
                    // An oversized record cannot be answered — we do not even
                    // trust the xid — so the connection goes away. The peer
                    // sees a clean EOF rather than a hang.
                    break readLoop
                }
                for message in messages { handle(message) }
            }

            // Wait for in-flight handlers before closing: they still hold the
            // descriptor number, and closing it early could hand it to another
            // thread's fresh socket.
            shutdown()
            state.lock()
            while inFlight > 0 { state.wait() }
            state.unlock()
            nfsClose(fd)
        }

        private func handle(_ message: [UInt8]) {
            let call: RPCCall
            do {
                call = try RPCMessage.decodeCall(
                    message, argumentLimit: server.options.maximumRecordSize)
            } catch let RPCDecodeError.versionMismatch(xid, _) {
                beginRequest()
                enqueue(RPCMessage.rpcMismatch(xid: xid, low: RPCConstants.version,
                                               high: RPCConstants.version))
                return
            } catch {
                // No usable xid, so no reply is possible; ignore the message
                // and keep the connection for whatever comes next.
                return
            }

            beginRequest()
            Task { [weak self] in
                guard let self else { return }
                let reply = await self.server.dispatch(call)
                self.enqueue(reply)
            }
        }

        /// Hands a finished reply to the writer queue.
        ///
        /// The request stays counted as in flight until the bytes are gone, so
        /// ``run()`` still cannot close the descriptor out from under a write.
        private func enqueue(_ payload: [UInt8]) {
            writeQueue.async { [self] in
                send(payload)
                endRequest()
            }
        }

        private func beginRequest() {
            state.lock()
            inFlight += 1
            state.unlock()
        }

        private func endRequest() {
            state.lock()
            inFlight -= 1
            state.broadcast()
            state.unlock()
        }

        /// Writes one framed reply. Only ever called on ``writeQueue``, which
        /// is what keeps two of them from being spliced together on the wire.
        private func send(_ payload: [UInt8]) {
            let framed = rpcFrame(payload)
            state.lock()
            let isClosed = closed
            state.unlock()
            guard !isClosed else { return }
            var offset = 0
            framed.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                while offset < framed.count {
                    let written = nfsSend(fd, base + offset, framed.count - offset)
                    if written <= 0 {
                        if written < 0 && nfsErrno() == EINTR { continue }
                        return
                    }
                    offset += written
                }
            }
        }
    }
}
