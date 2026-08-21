import Foundation
import NineP
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Framing for one connection: reads `size[4]`-prefixed frames off a socket,
/// hands them to a ``NinePServerSession`` and writes the replies back.
///
/// Nothing here interprets a message beyond its type and tag. That split is
/// what lets the session switch dialect mid-stream: the frame boundaries are
/// dialect-independent, so the loop can always recover the tag and answer with
/// an error even when the body is nonsense.
final class NinePConnection {
    private let fd: Int32
    private let session: NinePServerSession
    private let configuration: NinePServerConfiguration

    init(fd: Int32, session: NinePServerSession, configuration: NinePServerConfiguration) {
        self.fd = fd
        self.session = session
        self.configuration = configuration
    }

    func run() {
        defer { session.close() }
        while true {
            guard let sizeBytes = readExactly(4) else { return }
            let size = UInt32(sizeBytes[0]) | UInt32(sizeBytes[1]) << 8
                | UInt32(sizeBytes[2]) << 16 | UInt32(sizeBytes[3]) << 24
            // A frame too short to hold a header carries no tag, so there is
            // nobody to answer: the stream is desynchronised and must end.
            guard size >= UInt32(P9.headerSize) else { return }
            if size > session.msize {
                guard rejectOversized(size: size) else { return }
                continue
            }
            guard let body = readExactly(Int(size) - 4) else { return }
            guard let reply = process(body: body) else { return }
            guard writeAll(reply) else { return }
        }
    }

    /// Turns one frame body (type, tag and payload) into encoded reply bytes.
    /// Returns nil only when the connection cannot be kept in sync.
    private func process(body: [UInt8]) -> [UInt8]? {
        var reader = ByteReader(body)
        guard let typeByte = try? reader.u8(), let tag = try? reader.u16() else { return nil }
        // Capture the codec before dispatch: a Tversion changes it, but its own
        // body must still be read in the dialect that was in force.
        let codec = session.codec

        guard let type = MessageType(rawValue: typeByte) else {
            return encodeReply(session.errorReply(tag: tag, NinePServerError(
                errno: LinuxErrno.eproto, message: "unknown message type \(typeByte)")), tag: tag)
        }
        let frame: Frame
        do {
            let message = try codec.decodeBody(type: type, from: &reader)
            try reader.expectEmpty()
            frame = Frame(tag: tag, message: message)
        } catch {
            return encodeReply(session.errorReply(tag: tag, error.asNinePServerError), tag: tag)
        }
        return encodeReply(session.handle(frame), tag: tag)
    }

    /// Encodes a reply, substituting an error if it would not fit in the
    /// negotiated msize. Read replies are clamped long before this, so hitting
    /// the fallback means a pathological name or symlink target.
    private func encodeReply(_ reply: Frame, tag: Tag) -> [UInt8] {
        let bytes = session.codec.encode(reply)
        guard bytes.count > Int(session.msize) else { return bytes }
        let error = NinePServerError(
            errno: LinuxErrno.emsgsize,
            message: "reply of \(bytes.count) bytes exceeds the negotiated msize")
        return session.codec.encode(session.errorReply(tag: tag, error))
    }

    /// Answers a frame that is larger than msize without losing sync: the
    /// header is read for its tag, the body is discarded, and the client gets
    /// an EMSGSIZE. Absurdly large frames end the connection instead — draining
    /// them is exactly the denial of service the msize limit exists to prevent.
    private func rejectOversized(size: UInt32) -> Bool {
        guard let header = readExactly(3) else { return false }
        let tag = Tag(header[1]) | Tag(header[2]) << 8
        let remaining = Int(size) - P9.headerSize
        guard remaining <= configuration.maxDrainBytes, discard(remaining) else { return false }
        let error = NinePServerError(
            errno: LinuxErrno.emsgsize,
            message: "message of \(size) bytes exceeds the negotiated msize of \(session.msize)")
        return writeAll(encodeReply(session.errorReply(tag: tag, error), tag: tag))
    }

    // MARK: - Socket I/O

    /// Reads exactly `count` bytes, reassembling across however many segments
    /// the network chose to use. Returns nil at EOF or on error.
    private func readExactly(_ count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                sysRead(fd, raw.baseAddress!.advanced(by: filled), count - filled)
            }
            if n > 0 {
                filled += n
                continue
            }
            if n == 0 { return nil }               // orderly shutdown
            if sysErrno() == EINTR { continue }
            return nil
        }
        return buffer
    }

    private func discard(_ count: Int) -> Bool {
        var remaining = count
        var scratch = [UInt8](repeating: 0, count: min(count, 64 * 1024))
        while remaining > 0 {
            let chunk = min(remaining, scratch.count)
            let n = scratch.withUnsafeMutableBytes { sysRead(fd, $0.baseAddress!, chunk) }
            if n > 0 { remaining -= n; continue }
            if n == 0 { return false }
            if sysErrno() == EINTR { continue }
            return false
        }
        return true
    }

    private func writeAll(_ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                sysWrite(fd, raw.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            if n > 0 { sent += n; continue }
            if n < 0 && sysErrno() == EINTR { continue }
            return false
        }
        return true
    }
}
