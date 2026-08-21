import Foundation
import NineP
@testable import NinePClient

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A stand-in 9P server driven by a closure, connected to the client over a
/// socketpair.
///
/// This exists to test the session machinery — framing, tag multiplexing,
/// flush, error mapping — without depending on a real server implementation,
/// and to let a test inject replies that a well-behaved server would never
/// send.
final class ScriptedPeer: @unchecked Sendable {
    /// Called for each request frame; returns zero or more frames to write back.
    /// Runs on the peer's own thread, so it must not touch the test's state
    /// without synchronisation.
    typealias Handler = @Sendable (Frame, MessageCodec) -> [Frame]

    private let peerFD: Int32
    let clientFD: Int32
    private let handler: Handler
    private var thread: Thread?
    private let stopped = ManagedAtomicFlag()

    /// Set once Tversion has been answered, so later frames decode in the
    /// negotiated dialect.
    private var codec = MessageCodec(version: .v9P2000)

    init(handler: @escaping Handler) throws {
        var fds: [Int32] = [0, 0]
        #if canImport(Darwin)
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        #else
        let rc = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
        #endif
        guard rc == 0 else { throw NinePClientError.io(errno: errno, operation: "socketpair") }
        clientFD = fds[0]
        peerFD = fds[1]
        self.handler = handler
    }

    func start() {
        let t = Thread { [self] in loop() }
        t.name = "scripted-9p-peer"
        thread = t
        t.start()
    }

    /// Switches the dialect used to decode subsequent requests.
    func setVersion(_ v: NinePVersion) { codec = MessageCodec(version: v) }

    private func loop() {
        while !stopped.isSet {
            guard let header = readExactly(4) else { break }
            let size = UInt32(header[0]) | UInt32(header[1]) << 8
                | UInt32(header[2]) << 16 | UInt32(header[3]) << 24
            guard size >= 7, size < 8 * 1024 * 1024,
                  let rest = readExactly(Int(size) - 4) else { break }
            guard let frame = try? codec.decode(frame: header + rest) else { break }
            for reply in handler(frame, codec) {
                let bytes = codec.encode(reply)
                guard writeAll(bytes) else { return }
            }
        }
    }

    private func readExactly(_ n: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes {
                read(peerFD, $0.baseAddress!.advanced(by: got), n - got)
            }
            if r > 0 { got += r; continue }
            if r < 0 && errno == EINTR { continue }
            return nil
        }
        return buf
    }

    @discardableResult
    private func writeAll(_ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let w = bytes.withUnsafeBytes {
                write(peerFD, $0.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            if w > 0 { sent += w; continue }
            if w < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }

    /// Writes raw bytes, bypassing the framing — for malformed-input tests.
    func writeRaw(_ bytes: [UInt8]) { writeAll(bytes) }

    func stop() {
        guard !stopped.testAndSet() else { return }
        shutdown(peerFD, Int32(SHUT_RDWR))
        close(peerFD)
    }

    deinit { stop() }
}

/// Convenience: replies that a minimal well-behaved server would send.
enum Reply {
    static func version(_ frame: Frame, agreeing version: String, msize: UInt32 = 65536) -> Frame {
        Frame(tag: frame.tag, message: .rversion(msize: msize, version: version))
    }
}
