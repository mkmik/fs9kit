import Foundation
import NineP

/// An error reported by the server: Rerror in 9P2000/.u, Rlerror in 9P2000.L.
public struct NinePServerError: Error, CustomStringConvertible, Equatable {
    /// The POSIX error number, when the server supplied one. Base 9P2000 sends
    /// only a string, in which case this is inferred from well-known messages.
    public var errno: Int32
    /// The server's message. Synthesised from `errno` for 9P2000.L.
    public var message: String

    public init(errno: Int32, message: String) {
        self.errno = errno
        self.message = message
    }

    public var description: String { message }

    /// Base 9P2000 has no numeric errors, so map the handful of strings that
    /// every server in the wild uses. Anything unrecognised becomes EIO.
    public static func fromLegacy(_ message: String) -> NinePServerError {
        let lower = message.lowercased()
        let table: [(String, Int32)] = [
            // Phrasings seen in the wild: Plan 9 and u9fs say "does not
            // exist", go9p says "No such path", Linux-flavoured servers say
            // "no such file or directory".
            ("does not exist", ENOENT), ("no such file", ENOENT),
            ("no such path", ENOENT), ("not exist", ENOENT),
            ("not found", ENOENT), ("directory entry not found", ENOENT),
            ("unknown file", ENOENT),
            ("permission denied", EACCES), ("access denied", EACCES),
            ("not a directory", ENOTDIR), ("walk in non-directory", ENOTDIR),
            ("is a directory", EISDIR),
            ("already exists", EEXIST), ("file exists", EEXIST),
            ("create/wstat -- file exists", EEXIST),
            ("directory not empty", ENOTEMPTY),
            ("not implemented", ENOSYS), ("unknown message", ENOSYS),
            ("read only", EROFS), ("read-only", EROFS),
            ("permission", EACCES),
            ("file too large", EFBIG),
            ("no space", ENOSPC),
            ("cross-device", EXDEV), ("different file systems", EXDEV),
            ("interrupted", EINTR),
            ("i/o error", EIO),
        ]
        for (needle, code) in table where lower.contains(needle) {
            return NinePServerError(errno: code, message: message)
        }
        return NinePServerError(errno: EIO, message: message)
    }
}

/// Knobs for opening a session.
public struct NinePSessionOptions: Sendable {
    /// Largest message the client is willing to handle, including the header.
    public var msize: UInt32
    /// Dialects to offer, most preferred first.
    public var versions: [NinePVersion]
    /// How long to wait for the TCP connection.
    public var connectTimeout: TimeInterval
    /// How long to wait for each Rversion. Some servers answer an offer they
    /// do not understand with silence rather than "unknown".
    public var handshakeTimeout: TimeInterval
    /// Client identifier reported in Tlock/Tgetlock.
    public var clientID: String

    public init(
        msize: UInt32 = P9.defaultMsize,
        versions: [NinePVersion] = [.v9P2000L, .v9P2000u, .v9P2000],
        connectTimeout: TimeInterval = 30,
        handshakeTimeout: TimeInterval = 5,
        clientID: String = "fs9kit"
    ) {
        self.msize = msize
        self.versions = versions
        self.connectTimeout = connectTimeout
        self.handshakeTimeout = handshakeTimeout
        self.clientID = clientID
    }
}

/// A 9P connection: framing, version negotiation, tag multiplexing and RPC.
///
/// One background thread reads frames and hands each reply to the continuation
/// waiting on its tag, so many `rpc` calls can be in flight at once. Writes are
/// serialised behind a lock because a 9P frame must reach the wire whole.
public final class NinePSession: @unchecked Sendable {
    /// The dialect both ends agreed to speak.
    public let version: NinePVersion
    /// The negotiated maximum frame size, in bytes.
    public let msize: UInt32
    /// The largest payload that fits in one Rread/Twrite at this msize.
    public var maxDataSize: Int { Int(msize) - P9.headerSize - 4 - 8 - 4 }
    public let options: NinePSessionOptions

    private let socket: StreamSocket
    private let codec: MessageCodec
    private let writeLock = NSLock()
    /// Requests are written here, never on the thread that asked for them.
    ///
    /// `socket.writeFully` blocks, and `rpc`'s continuation body runs on
    /// whichever thread called it — a cooperative pool thread, of which there
    /// are roughly as many as there are cores. If the peer's receive window
    /// fills, blocking those threads stops every task in the process, so
    /// nothing is left to read replies and unblock the write. Off the pool it
    /// goes; the queue being serial also preserves frame boundaries.
    private let writeQueue = DispatchQueue(label: "fs9kit.9p.session.write")
    private let lock = NSLock()
    private var reader: Thread?

    private var pending: [Tag: CheckedContinuation<Message, any Error>] = [:]
    /// Tags whose request was cancelled before its continuation was registered.
    private var cancelledTags: Set<Tag> = []
    /// Tflush tag -> the tag it is flushing.
    private var flushing: [Tag: Tag] = [:]
    private var nextTag: Tag = 0
    private var freeTags: [Tag] = []
    private var failure: (any Error)?

    private init(socket: StreamSocket, version: NinePVersion, msize: UInt32,
                 options: NinePSessionOptions) {
        self.socket = socket
        self.version = version
        self.msize = msize
        self.options = options
        self.codec = MessageCodec(version: version)
    }

    // MARK: - Connecting

    /// Dials the endpoint and negotiates a protocol version.
    ///
    /// Version negotiation happens synchronously before the reader thread
    /// starts: Tversion resets the connection, so nothing else may be in
    /// flight while it runs.
    public static func connect(
        to endpoint: NinePEndpoint,
        options: NinePSessionOptions = NinePSessionOptions()
    ) async throws -> NinePSession {
        // Not every server answers an offer it does not understand. `u9fs`
        // downgrades correctly and `p9ufs` replies "unknown", but `export9p`
        // says nothing at all — so an offer that goes unanswered means
        // abandoning that connection and dialing again with a lower one,
        // rather than declaring the server unreachable.
        var offers = options.versions
        var lastError: (any Error)?

        while !offers.isEmpty {
            let socket = try await blocking {
                try StreamSocket.connect(to: endpoint, timeout: options.connectTimeout)
            }
            do {
                let offering = offers
                let (version, msize) = try await blocking {
                    try negotiate(socket: socket, offering: offering, options: options)
                }
                let session = NinePSession(socket: socket, version: version,
                                           msize: msize, options: options)
                session.startReader()
                return session
            } catch let error as NinePClientError {
                socket.close()
                guard case .timedOut = error else { throw error }
                lastError = error
                offers.removeFirst()
                // An inherited file descriptor cannot be redialled.
                if case .fileDescriptor = endpoint { break }
            } catch {
                socket.close()
                throw error
            }
        }
        throw lastError ?? NinePClientError.versionNegotiationFailed(
            offered: options.versions.map(\.rawValue), serverSaid: "no reply")
    }

    /// Offers each version in turn until the server accepts one.
    ///
    /// A server that does not know a version replies "unknown"; Tversion may
    /// then be sent again on the same connection with a lower offer. A server
    /// that replies nothing at all trips the handshake timeout, which the
    /// caller turns into a fresh connection with a shorter list.
    private static func negotiate(
        socket: StreamSocket, offering: [NinePVersion], options: NinePSessionOptions
    ) throws -> (NinePVersion, UInt32) {
        // Any dialect encodes Tversion/Rversion identically, so the codec used
        // here does not matter.
        let codec = MessageCodec(version: .v9P2000)
        var msize = options.msize
        var lastReply = ""
        socket.setReadTimeout(options.handshakeTimeout)
        // Restore blocking reads: the reader thread must wait indefinitely.
        defer { socket.setReadTimeout(0) }

        for candidate in offering {
            let frame = Frame(tag: P9.notag,
                              message: .tversion(msize: msize, version: candidate.rawValue))
            try socket.writeFully(codec.encode(frame))
            let reply = try readFrame(socket: socket, limit: msize, codec: codec)
            guard case let .rversion(serverMsize, serverVersion) = reply.message else {
                throw NinePClientError.protocolViolation(
                    "expected Rversion, got \(reply.message.type)")
            }
            lastReply = serverVersion
            // A server may only shrink msize, never grow it.
            msize = min(msize, serverMsize)
            guard msize > UInt32(P9.headerSize) + 64 else {
                throw NinePClientError.protocolViolation(
                    "server proposed an unusable msize \(serverMsize)")
            }
            if let agreed = NinePVersion(rawValue: serverVersion),
               options.versions.contains(agreed) {
                return (agreed, msize)
            }
            if serverVersion != "unknown" && !serverVersion.hasPrefix("9P") {
                throw NinePClientError.versionNegotiationFailed(
                    offered: offering.map(\.rawValue), serverSaid: serverVersion)
            }
        }
        throw NinePClientError.versionNegotiationFailed(
            offered: offering.map(\.rawValue), serverSaid: lastReply)
    }

    /// Reads one size-prefixed frame.
    private static func readFrame(socket: StreamSocket, limit: UInt32,
                                  codec: MessageCodec) throws -> Frame {
        let sizeBytes = try socket.readFully(4)
        let size = UInt32(sizeBytes[0]) | UInt32(sizeBytes[1]) << 8
            | UInt32(sizeBytes[2]) << 16 | UInt32(sizeBytes[3]) << 24
        guard size >= UInt32(P9.headerSize) else {
            throw NinePWireError.invalidFrameSize(size)
        }
        guard size <= limit else {
            throw NinePClientError.frameTooLarge(size, limit: limit)
        }
        let rest = try socket.readFully(Int(size) - 4)
        return try codec.decode(frame: sizeBytes + rest)
    }

    // MARK: - Reader thread

    private func startReader() {
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "9p-reader"
        thread.stackSize = 512 * 1024
        reader = thread
        thread.start()
    }

    private func readLoop() {
        do {
            while true {
                let frame = try Self.readFrame(socket: socket, limit: msize, codec: codec)
                deliver(frame)
            }
        } catch {
            fail(with: error)
        }
    }

    private func deliver(_ frame: Frame) {
        lock.lock()
        // An Rflush tells us the flushed request will never be answered.
        if case .rflush = frame.message, let original = flushing.removeValue(forKey: frame.tag) {
            recycle(frame.tag)
            let victim = pending.removeValue(forKey: original)
            if victim != nil { recycle(original) }
            lock.unlock()
            victim?.resume(throwing: CancellationError())
            return
        }
        guard let continuation = pending.removeValue(forKey: frame.tag) else {
            // A reply to a request we already gave up on, or a stray tag.
            // Neither is worth tearing the session down for.
            lock.unlock()
            return
        }
        recycle(frame.tag)
        lock.unlock()
        continuation.resume(returning: frame.message)
    }

    private func fail(with error: any Error) {
        lock.lock()
        if failure == nil { failure = error }
        let waiters = pending.values
        pending.removeAll()
        flushing.removeAll()
        lock.unlock()
        for w in waiters { w.resume(throwing: error) }
    }

    /// Closes the connection and fails every outstanding request.
    public func close() {
        socket.close()
        fail(with: NinePClientError.sessionClosed)
    }

    deinit { socket.close() }

    // MARK: - Tags

    /// Must be called with `lock` held.
    private func recycle(_ tag: Tag) {
        cancelledTags.remove(tag)
        freeTags.append(tag)
    }

    private func acquireTag() throws -> Tag {
        lock.lock()
        defer { lock.unlock() }
        if let f = failure { throw f }
        if let t = freeTags.popLast() { return t }
        guard nextTag < P9.notag else {
            throw NinePClientError.protocolViolation("all 65535 tags are in use")
        }
        let t = nextTag
        nextTag += 1
        return t
    }

    // MARK: - RPC

    /// Sends a request and waits for its reply, throwing on Rerror/Rlerror.
    ///
    /// Cancelling the surrounding task sends a Tflush and fails this call with
    /// `CancellationError` once the server acknowledges it.
    @discardableResult
    public func rpc(_ message: Message) async throws -> Message {
        try Task.checkCancellation()
        let tag = try acquireTag()
        let reply: Message = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let f = failure {
                    lock.unlock()
                    continuation.resume(throwing: f)
                    return
                }
                if cancelledTags.contains(tag) {
                    recycle(tag)
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[tag] = continuation
                lock.unlock()

                writeQueue.async { [self] in
                    do {
                        try send(Frame(tag: tag, message: message))
                    } catch {
                        lock.lock()
                        let c = pending.removeValue(forKey: tag)
                        if c != nil { recycle(tag) }
                        lock.unlock()
                        c?.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.requestFlush(of: tag)
        }
        switch reply {
        case let .rerror(message, errno):
            // 9P2000.u numbers come from a Linux-shaped server in practice, so
            // they go through the same translation as Rlerror.
            if let errno {
                throw NinePServerError(
                    errno: LinuxErrno.toHost(Int32(bitPattern: errno)), message: message)
            }
            throw NinePServerError.fromLegacy(message)
        case let .rlerror(errno):
            let code = LinuxErrno.toHost(Int32(bitPattern: errno))
            throw NinePServerError(errno: code, message: String(cString: strerror(code)))
        default:
            return reply
        }
    }

    /// Sends a request and requires a particular reply shape.
    public func rpc<T>(_ message: Message, expecting extract: (Message) -> T?) async throws -> T {
        let reply = try await rpc(message)
        guard let value = extract(reply) else {
            throw NinePClientError.protocolViolation(
                "\(message.type) answered with \(reply.type)")
        }
        return value
    }

    private func send(_ frame: Frame) throws {
        let bytes = codec.encode(frame)
        guard bytes.count <= Int(msize) else {
            throw NinePClientError.frameTooLarge(UInt32(bytes.count), limit: msize)
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        try socket.writeFully(bytes)
    }

    /// Asks the server to abandon `tag`. Best effort: if we cannot even send
    /// the Tflush, fail the request locally.
    private func requestFlush(of tag: Tag) {
        lock.lock()
        if failure != nil || pending[tag] == nil {
            // Either the session is already dead, or the request has not been
            // registered yet — mark it so registration fails immediately.
            cancelledTags.insert(tag)
            lock.unlock()
            return
        }
        lock.unlock()

        guard let flushTag = try? acquireTag() else {
            failLocally(tag)
            return
        }
        lock.lock()
        flushing[flushTag] = tag
        lock.unlock()
        // Enqueued rather than written here for the same reason as `rpc`: this
        // runs as a cancellation handler on a cooperative thread. Ordering
        // behind the request it flushes comes free from the serial queue.
        writeQueue.async { [self] in
            do {
                try send(Frame(tag: flushTag, message: .tflush(oldtag: tag)))
            } catch {
                lock.lock()
                flushing.removeValue(forKey: flushTag)
                recycle(flushTag)
                lock.unlock()
                failLocally(tag)
            }
        }
    }

    private func failLocally(_ tag: Tag) {
        lock.lock()
        let c = pending.removeValue(forKey: tag)
        if c != nil { recycle(tag) }
        lock.unlock()
        c?.resume(throwing: CancellationError())
    }
}

/// Runs a blocking call off the cooperative thread pool.
///
/// The 9P socket layer is blocking by design — it is driven by one dedicated
/// reader thread — but `connect` and the initial handshake are called from
/// async code, and blocking a cooperative thread there can deadlock a small
/// executor.
func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do { continuation.resume(returning: try body()) }
            catch { continuation.resume(throwing: error) }
        }
    }
}
