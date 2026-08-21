import Testing
import Foundation
import NineP
@testable import NinePClient

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Builds a session talking to a scripted peer. The peer answers Tversion
/// itself so callers only script the interesting part.
@MainActor
func withScriptedSession(
    agreeing version: NinePVersion = .v9P2000L,
    msize: UInt32 = 65536,
    options: NinePSessionOptions? = nil,
    handler: @escaping @Sendable (Frame, MessageCodec) -> [Frame],
    body: (NinePSession, ScriptedPeer) async throws -> Void
) async throws {
    let peer = try ScriptedPeer { frame, codec in
        if case .tversion = frame.message {
            return [Frame(tag: frame.tag, message: .rversion(msize: msize, version: version.rawValue))]
        }
        return handler(frame, codec)
    }
    peer.start()
    let session = try await NinePSession.connect(
        to: .fileDescriptor(peer.clientFD),
        options: options ?? NinePSessionOptions(msize: msize, versions: [version]))
    peer.setVersion(version)
    defer { session.close(); peer.stop() }
    try await body(session, peer)
}

@Suite("Version negotiation")
struct NegotiationTests {
    @Test("the agreed version is the one the server names")
    func agrees() async throws {
        try await withScriptedSession(agreeing: .v9P2000L, handler: { _, _ in [] }) { session, _ in
            #expect(session.version == .v9P2000L)
        }
    }

    @Test("msize is clamped to the smaller of the two proposals")
    func msizeClamp() async throws {
        try await withScriptedSession(agreeing: .v9P2000L, msize: 8192, handler: { _, _ in [] }) { session, _ in
            #expect(session.msize == 8192)
        }
    }

    @Test("a server may not raise the client's msize")
    func msizeCannotGrow() async throws {
        let peer = try ScriptedPeer { frame, _ in
            guard case .tversion = frame.message else { return [] }
            // Answer with a larger msize than offered; the client must ignore it.
            return [Frame(tag: frame.tag, message: .rversion(msize: 1 << 20, version: "9P2000.L"))]
        }
        peer.start()
        let session = try await NinePSession.connect(
            to: .fileDescriptor(peer.clientFD),
            options: NinePSessionOptions(msize: 4096, versions: [.v9P2000L]))
        defer { session.close(); peer.stop() }
        #expect(session.msize == 4096)
    }

    @Test("the client falls back when the server does not know a version")
    func fallback() async throws {
        let seen = Locked<[String]>([])
        let peer = try ScriptedPeer { frame, _ in
            guard case let .tversion(_, v) = frame.message else { return [] }
            seen.withLock { $0.append(v) }
            // Reject .L, accept .u.
            let answer = v == "9P2000.L" ? "unknown" : v
            return [Frame(tag: frame.tag, message: .rversion(msize: 65536, version: answer))]
        }
        peer.start()
        let session = try await NinePSession.connect(
            to: .fileDescriptor(peer.clientFD),
            options: NinePSessionOptions(versions: [.v9P2000L, .v9P2000u, .v9P2000]))
        defer { session.close(); peer.stop() }
        #expect(session.version == .v9P2000u)
        #expect(seen.value == ["9P2000.L", "9P2000.u"])
    }

    @Test("a server that knows nothing we speak is an error, not a hang")
    func noCommonVersion() async throws {
        let peer = try ScriptedPeer { frame, _ in
            guard case .tversion = frame.message else { return [] }
            return [Frame(tag: frame.tag, message: .rversion(msize: 65536, version: "unknown"))]
        }
        peer.start()
        defer { peer.stop() }
        await #expect(throws: NinePClientError.self) {
            _ = try await NinePSession.connect(to: .fileDescriptor(peer.clientFD))
        }
    }

    @Test("a reply that is not Rversion is rejected")
    func wrongReply() async throws {
        let peer = try ScriptedPeer { frame, _ in
            [Frame(tag: frame.tag, message: .rclunk)]
        }
        peer.start()
        defer { peer.stop() }
        await #expect(throws: NinePClientError.self) {
            _ = try await NinePSession.connect(to: .fileDescriptor(peer.clientFD))
        }
    }
}

@Suite("RPC and tag multiplexing")
struct RPCTests {
    @Test("a request gets its own reply")
    func simpleRPC() async throws {
        try await withScriptedSession(handler: { frame, _ in
            guard case .tclunk = frame.message else { return [] }
            return [Frame(tag: frame.tag, message: .rclunk)]
        }) { session, _ in
            let reply = try await session.rpc(.tclunk(fid: 3))
            #expect(reply == .rclunk)
        }
    }

    @Test("replies that arrive out of order still reach the right caller")
    func outOfOrder() async throws {
        // The peer answers Tread by echoing the fid number as the payload, but
        // holds the first request until the second has arrived, so the replies
        // come back reversed.
        let held = Locked<[Frame]>([])
        try await withScriptedSession(handler: { frame, _ in
            guard case let .tread(fid, _, _) = frame.message else { return [] }
            let reply = Frame(tag: frame.tag, message: .rread(data: [UInt8(fid)]))
            let flush: [Frame] = held.withLock { pending in
                pending.append(reply)
                guard pending.count == 3 else { return [] }
                let out = pending.reversed().map { $0 }
                pending.removeAll()
                return out
            }
            return flush
        }) { session, _ in
            async let a = session.rpc(.tread(fid: 1, offset: 0, count: 1))
            async let b = session.rpc(.tread(fid: 2, offset: 0, count: 1))
            async let c = session.rpc(.tread(fid: 3, offset: 0, count: 1))
            let results = try await [a, b, c]
            #expect(results[0] == .rread(data: [1]))
            #expect(results[1] == .rread(data: [2]))
            #expect(results[2] == .rread(data: [3]))
        }
    }

    @Test("every in-flight request uses a distinct tag")
    func distinctTags() async throws {
        let tags = Locked<Set<UInt16>>([])
        let gate = Locked<[Frame]>([])
        try await withScriptedSession(handler: { frame, _ in
            guard case .tread = frame.message else { return [] }
            tags.withLock { _ = $0.insert(frame.tag) }
            return gate.withLock { pending in
                pending.append(Frame(tag: frame.tag, message: .rread(data: [])))
                guard pending.count == 8 else { return [] }
                let out = pending
                pending.removeAll()
                return out
            }
        }) { session, _ in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<8 {
                    group.addTask {
                        _ = try await session.rpc(.tread(fid: Fid(i), offset: 0, count: 1))
                    }
                }
                try await group.waitForAll()
            }
            #expect(tags.value.count == 8)
        }
    }

    @Test("tags are recycled once a reply arrives")
    func tagReuse() async throws {
        let tags = Locked<[UInt16]>([])
        try await withScriptedSession(handler: { frame, _ in
            tags.withLock { $0.append(frame.tag) }
            return [Frame(tag: frame.tag, message: .rclunk)]
        }) { session, _ in
            for _ in 0..<50 { _ = try await session.rpc(.tclunk(fid: 1)) }
            // Sequential requests never overlap, so one tag should serve them all.
            #expect(Set(tags.value).count == 1)
        }
    }

    @Test("Rerror becomes a thrown server error carrying an errno")
    func errorMapping() async throws {
        try await withScriptedSession(agreeing: .v9P2000u, handler: { frame, _ in
            [Frame(tag: frame.tag, message: .rerror(message: "no such file", errno: UInt32(ENOENT)))]
        }) { session, _ in
            do {
                _ = try await session.rpc(.tclunk(fid: 1))
                Issue.record("expected a server error")
            } catch let e as NinePServerError {
                #expect(e.errno == ENOENT)
                #expect(e.message == "no such file")
            }
        }
    }

    @Test("Rlerror becomes a server error with the numeric code")
    func lerrorMapping() async throws {
        try await withScriptedSession(handler: { frame, _ in
            [Frame(tag: frame.tag, message: .rlerror(errno: UInt32(ENOTDIR)))]
        }) { session, _ in
            do {
                _ = try await session.rpc(.tclunk(fid: 1))
                Issue.record("expected a server error")
            } catch let e as NinePServerError {
                #expect(e.errno == ENOTDIR)
                #expect(!e.message.isEmpty)
            }
        }
    }

    @Test("plain 9P2000 error strings are mapped to plausible errnos")
    func legacyErrorMapping() {
        #expect(NinePServerError.fromLegacy("file does not exist").errno == ENOENT)
        #expect(NinePServerError.fromLegacy("permission denied").errno == EACCES)
        #expect(NinePServerError.fromLegacy("directory not empty").errno == ENOTEMPTY)
        #expect(NinePServerError.fromLegacy("something odd").errno == EIO)
    }

    @Test("a reply of the wrong type is a protocol violation, not a crash")
    func wrongReplyType() async throws {
        try await withScriptedSession(handler: { frame, _ in
            [Frame(tag: frame.tag, message: .rwstat)]
        }) { session, _ in
            await #expect(throws: NinePClientError.self) {
                _ = try await session.rpc(.tread(fid: 1, offset: 0, count: 1)) {
                    if case let .rread(d) = $0 { d } else { nil }
                }
            }
        }
    }

    @Test("a reply for an unknown tag is ignored rather than fatal")
    func strayTag() async throws {
        try await withScriptedSession(handler: { frame, _ in
            guard case .tclunk = frame.message else { return [] }
            return [
                Frame(tag: 999, message: .rclunk),      // nobody is waiting on 999
                Frame(tag: frame.tag, message: .rclunk),
            ]
        }) { session, _ in
            _ = try await session.rpc(.tclunk(fid: 1))
            // The session survives and can still be used.
            _ = try await session.rpc(.tclunk(fid: 2))
        }
    }
}

@Suite("Cancellation and teardown")
struct TeardownTests {
    @Test("cancelling a request sends Tflush and fails with CancellationError")
    func flushOnCancel() async throws {
        let sawFlush = Locked(false)
        try await withScriptedSession(handler: { frame, _ in
            switch frame.message {
            case .tread:
                return []   // never answer
            case let .tflush(oldtag):
                sawFlush.withLock { $0 = true }
                _ = oldtag
                return [Frame(tag: frame.tag, message: .rflush)]
            default:
                return []
            }
        }) { session, _ in
            let task = Task { try await session.rpc(.tread(fid: 1, offset: 0, count: 1)) }
            // Give the request time to reach the peer before cancelling.
            try await Task.sleep(nanoseconds: 50_000_000)
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            #expect(sawFlush.value)
        }
    }

    @Test("a request started in an already-cancelled task fails immediately")
    func cancelledBeforeStart() async throws {
        try await withScriptedSession(handler: { _, _ in [] }) { session, _ in
            let task = Task {
                try await Task.sleep(nanoseconds: 100_000_000)
                return try await session.rpc(.tclunk(fid: 1))
            }
            task.cancel()
            await #expect(throws: (any Error).self) { _ = try await task.value }
        }
    }

    @Test("closing the peer fails every waiting request")
    func peerHangsUp() async throws {
        let peer = try ScriptedPeer { frame, _ in
            if case .tversion = frame.message {
                return [Frame(tag: frame.tag, message: .rversion(msize: 65536, version: "9P2000.L"))]
            }
            return []
        }
        peer.start()
        let session = try await NinePSession.connect(
            to: .fileDescriptor(peer.clientFD),
            options: NinePSessionOptions(versions: [.v9P2000L]))
        defer { session.close() }

        let pending = Task { try await session.rpc(.tread(fid: 1, offset: 0, count: 1)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        peer.stop()
        await #expect(throws: (any Error).self) { _ = try await pending.value }
    }

    @Test("using a closed session throws instead of hanging")
    func useAfterClose() async throws {
        try await withScriptedSession(handler: { _, _ in [] }) { session, _ in
            session.close()
            await #expect(throws: (any Error).self) { _ = try await session.rpc(.tclunk(fid: 1)) }
        }
    }

    @Test("an oversized frame from the server is rejected")
    func oversizedFrame() async throws {
        let peer = try ScriptedPeer { frame, _ in
            if case .tversion = frame.message {
                return [Frame(tag: frame.tag, message: .rversion(msize: 8192, version: "9P2000.L"))]
            }
            return []
        }
        peer.start()
        let session = try await NinePSession.connect(
            to: .fileDescriptor(peer.clientFD),
            options: NinePSessionOptions(msize: 8192, versions: [.v9P2000L]))
        defer { session.close(); peer.stop() }

        let pending = Task { try await session.rpc(.tread(fid: 1, offset: 0, count: 1)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        // Claim a 1 MiB frame, well over the 8 KiB msize.
        peer.writeRaw([0x00, 0x00, 0x10, 0x00, MessageType.rread.rawValue, 0x00, 0x00])
        await #expect(throws: (any Error).self) { _ = try await pending.value }
    }
}

@Suite("Endpoint parsing")
struct EndpointTests {
    @Test("dial strings and shorthands")
    func parsing() throws {
        #expect(try NinePEndpoint.parse("tcp!localhost!5640") == .tcp(host: "localhost", port: 5640))
        #expect(try NinePEndpoint.parse("tcp!example.com") == .tcp(host: "example.com", port: 564))
        #expect(try NinePEndpoint.parse("unix!/tmp/ns/9p") == .unix(path: "/tmp/ns/9p"))
        #expect(try NinePEndpoint.parse("/tmp/ns/9p") == .unix(path: "/tmp/ns/9p"))
        #expect(try NinePEndpoint.parse("127.0.0.1:1234") == .tcp(host: "127.0.0.1", port: 1234))
        #expect(try NinePEndpoint.parse("myhost") == .tcp(host: "myhost", port: 564))
        #expect(try NinePEndpoint.parse("[::1]:9999") == .tcp(host: "::1", port: 9999))
        #expect(throws: NinePClientError.self) { _ = try NinePEndpoint.parse("bogus!x!1") }
    }
}

/// A minimal mutex-guarded box, so test handlers running on the peer thread can
/// record what they saw.
final class Locked<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) { storage = value }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}
