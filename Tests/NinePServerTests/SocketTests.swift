import Testing
import Foundation
import NineP
@testable import NinePServer
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A hand-rolled 9P client: just enough socket to prove the server's framing
/// and accept loop work against something that is not itself.
final class RawClient {
    enum Failure: Error { case connect(Int32), send, closed, timedOut }

    private var fd: Int32

    init(port: UInt16, host: String = "127.0.0.1", timeout: TimeInterval = 5) throws {
        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        #endif
        fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw Failure.connect(errno) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw Failure.connect(EINVAL)
        }
        let rc = withUnsafePointer(to: &address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let code = errno
            close(fd)
            fd = -1
            throw Failure.connect(code)
        }
        // Every read is bounded so a broken server fails the test instead of
        // hanging the whole suite.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        _ = withUnsafePointer(to: &tv) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    deinit { shut() }

    func shut() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    func send(_ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                #if canImport(Darwin)
                return Darwin.send(fd, raw.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                #else
                return Glibc.send(fd, raw.baseAddress!.advanced(by: sent), bytes.count - sent,
                                  Int32(MSG_NOSIGNAL))
                #endif
            }
            guard n > 0 else { throw Failure.send }
            sent += n
        }
    }

    func receive(_ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress!.advanced(by: filled), count - filled)
            }
            if n > 0 { filled += n; continue }
            if n == 0 { throw Failure.closed }
            throw Failure.timedOut
        }
        return buffer
    }

    /// Reads one size-prefixed frame and decodes it with `codec`.
    func receiveFrame(_ codec: MessageCodec) throws -> Frame {
        let header = try receive(4)
        let size = UInt32(header[0]) | UInt32(header[1]) << 8
            | UInt32(header[2]) << 16 | UInt32(header[3]) << 24
        let body = try receive(Int(size) - 4)
        return try codec.decode(frame: header + body)
    }

    func request(_ frame: Frame, codec: MessageCodec) throws -> Message {
        try send(codec.encode(frame))
        return try receiveFrame(codec).message
    }
}

/// Starts a server on an ephemeral loopback port and hands its port to `body`.
func withServer<T>(
    _ fileSystem: any NinePFileServer,
    configure: ((inout NinePServerConfiguration) -> Void)? = nil,
    _ body: (NinePServer, UInt16) throws -> T
) throws -> T {
    var configuration = NinePServerConfiguration()
    configure?(&configuration)
    let server = NinePServer(fileSystem: fileSystem, configuration: configuration)
    let endpoints = try server.start()
    defer { server.stop() }
    guard let port = endpoints.compactMap(\.port).first else {
        Issue.record("the server did not report a TCP port")
        throw RawClient.Failure.closed
    }
    return try body(server, UInt16(port))
}

@Suite("Sockets and framing")
struct SocketTests {
    @Test("a real client can attach, walk and read over TCP")
    func roundTrip() throws {
        try withServer(try sampleTree()) { server, port in
            #expect(port != 0)
            #expect(server.boundPort == Int(port))
            let client = try RawClient(port: port)
            defer { client.shut() }

            var codec = MessageCodec(version: .v9P2000)
            let version = try client.request(
                Frame(tag: P9.notag, message: .tversion(msize: 8192, version: "9P2000.L")),
                codec: codec)
            #expect(version == .rversion(msize: 8192, version: "9P2000.L"))
            codec = MessageCodec(version: .v9P2000L)

            let attach = try client.request(
                Frame(tag: 1, message: .tattach(fid: 0, afid: P9.nofid, uname: "u",
                                                aname: "", numericUID: 1000)),
                codec: codec)
            guard case let .rattach(qid) = attach else { Issue.record("got \(attach)"); return }
            #expect(qid.isDir)

            let walk = try client.request(
                Frame(tag: 2, message: .twalk(fid: 0, newfid: 1, names: ["docs", "a.txt"])),
                codec: codec)
            guard case let .rwalk(qids) = walk else { Issue.record("got \(walk)"); return }
            #expect(qids.count == 2)

            _ = try client.request(Frame(tag: 3, message: .tlopen(fid: 1, flags: .rdonly)), codec: codec)
            let read = try client.request(
                Frame(tag: 4, message: .tread(fid: 1, offset: 0, count: 1024)), codec: codec)
            #expect(read == .rread(data: Array("alpha".utf8)))
            #expect(try client.request(Frame(tag: 5, message: .tclunk(fid: 1)), codec: codec) == .rclunk)
        }
    }

    @Test("a frame split across TCP segments is reassembled")
    func splitFrame() throws {
        try withServer(try sampleTree()) { _, port in
            let client = try RawClient(port: port)
            defer { client.shut() }
            let codec = MessageCodec(version: .v9P2000)
            let bytes = codec.encode(
                Frame(tag: P9.notag, message: .tversion(msize: 8192, version: "9P2000.L")))
            // Split inside the header, so even the size field arrives in pieces.
            try client.send(Array(bytes.prefix(3)))
            Thread.sleep(forTimeInterval: 0.05)
            try client.send(Array(bytes.dropFirst(3)))
            #expect(try client.receiveFrame(codec).message == .rversion(msize: 8192, version: "9P2000.L"))
        }
    }

    @Test("a frame larger than msize is refused and the connection survives")
    func oversizedFrame() throws {
        try withServer(try sampleTree()) { _, port in
            let client = try RawClient(port: port)
            defer { client.shut() }
            var codec = MessageCodec(version: .v9P2000)
            _ = try client.request(
                Frame(tag: P9.notag, message: .tversion(msize: 512, version: "9P2000.L")), codec: codec)
            codec = MessageCodec(version: .v9P2000L)

            var oversized = [UInt8](repeating: 0, count: 4096)
            oversized[0] = 0x00; oversized[1] = 0x10   // size = 4096
            oversized[4] = MessageType.tread.rawValue
            oversized[5] = 0x2A                        // tag = 42
            try client.send(oversized)
            let reply = try client.receiveFrame(codec)
            #expect(reply.tag == 42)
            #expect(reply.message == .rlerror(errno: LinuxErrno.emsgsize))

            // The stream is still in sync afterwards.
            let attach = try client.request(
                Frame(tag: 7, message: .tattach(fid: 0, afid: P9.nofid, uname: "u",
                                                aname: "", numericUID: 0)),
                codec: codec)
            if case .rattach = attach {} else { Issue.record("got \(attach)") }
        }
    }

    @Test("a frame too large to drain closes the connection instead")
    func absurdlyOversizedFrame() throws {
        try withServer(try sampleTree(), configure: { $0.maxDrainBytes = 4096 }) { _, port in
            let client = try RawClient(port: port)
            defer { client.shut() }
            let codec = MessageCodec(version: .v9P2000)
            _ = try client.request(
                Frame(tag: P9.notag, message: .tversion(msize: 512, version: "9P2000.L")), codec: codec)
            // Declare 64 MiB and send only the header: the server must not try
            // to read it all.
            try client.send([0x00, 0x00, 0x00, 0x04, MessageType.tread.rawValue, 0x01, 0x00])
            #expect(throws: RawClient.Failure.self) { _ = try client.receiveFrame(codec) }
        }
    }

    @Test("a garbage message type is answered, not fatal")
    func unknownMessageType() throws {
        try withServer(try sampleTree()) { _, port in
            let client = try RawClient(port: port)
            defer { client.shut() }
            var codec = MessageCodec(version: .v9P2000)
            _ = try client.request(
                Frame(tag: P9.notag, message: .tversion(msize: 4096, version: "9P2000.L")), codec: codec)
            codec = MessageCodec(version: .v9P2000L)
            try client.send([0x07, 0x00, 0x00, 0x00, 200, 0x05, 0x00])
            let reply = try client.receiveFrame(codec)
            #expect(reply.tag == 5)
            #expect(replyErrno(reply.message) == LinuxErrno.eproto)
        }
    }

    @Test("a truncated body is answered with an error")
    func truncatedBody() throws {
        try withServer(try sampleTree()) { _, port in
            let client = try RawClient(port: port)
            defer { client.shut() }
            var codec = MessageCodec(version: .v9P2000)
            _ = try client.request(
                Frame(tag: P9.notag, message: .tversion(msize: 4096, version: "9P2000.L")), codec: codec)
            codec = MessageCodec(version: .v9P2000L)
            // Tclunk with no fid field at all.
            try client.send([0x07, 0x00, 0x00, 0x00, MessageType.tclunk.rawValue, 0x09, 0x00])
            let reply = try client.receiveFrame(codec)
            #expect(reply.tag == 9)
            #expect(isError(reply.message))
        }
    }

    @Test("several connections are served at once, each with its own fids")
    func concurrentConnections() throws {
        try withServer(try sampleTree()) { _, port in
            let codec = MessageCodec(version: .v9P2000L)
            var clients: [RawClient] = []
            for _ in 0..<4 {
                let client = try RawClient(port: port)
                _ = try client.request(
                    Frame(tag: P9.notag, message: .tversion(msize: 8192, version: "9P2000.L")),
                    codec: MessageCodec(version: .v9P2000))
                _ = try client.request(
                    Frame(tag: 1, message: .tattach(fid: 0, afid: P9.nofid, uname: "u",
                                                    aname: "", numericUID: 0)),
                    codec: codec)
                clients.append(client)
            }
            // Fid 1 in one session must not exist in another.
            _ = try clients[0].request(
                Frame(tag: 2, message: .twalk(fid: 0, newfid: 1, names: ["docs"])), codec: codec)
            let other = try clients[1].request(Frame(tag: 2, message: .tstat(fid: 1)), codec: codec)
            #expect(replyErrno(other) == LinuxErrno.ebadf)
            for client in clients { client.shut() }
        }
    }

    @Test("a Unix domain socket endpoint works the same way")
    func unixSocket() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/9p.sock"
            var configuration = NinePServerConfiguration()
            configuration.endpoints = [.unix(path: path)]
            let server = NinePServer(fileSystem: try sampleTree(), configuration: configuration)
            #expect(try server.start() == [.unix(path: path)])
            defer { server.stop() }

            #if canImport(Darwin)
            let streamType = SOCK_STREAM
            #else
            let streamType = Int32(SOCK_STREAM.rawValue)
            #endif
            let fd = socket(AF_UNIX, streamType, 0)
            #expect(fd >= 0)
            defer { close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            withUnsafeMutablePointer(to: &address.sun_path) { raw in
                raw.withMemoryRebound(to: CChar.self, capacity: capacity) { slot in
                    for (i, byte) in Array(path.utf8).enumerated() { slot[i] = CChar(bitPattern: byte) }
                    slot[path.utf8.count] = 0
                }
            }
            let rc = withUnsafePointer(to: &address) { raw in
                raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            #expect(rc == 0)

            let codec = MessageCodec(version: .v9P2000)
            let request = codec.encode(
                Frame(tag: P9.notag, message: .tversion(msize: 4096, version: "9P2000.L")))
            _ = request.withUnsafeBytes { write(fd, $0.baseAddress!, request.count) }
            var buffer = [UInt8](repeating: 0, count: 64)
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, 64) }
            #expect(n > 0)
            let reply = try codec.decode(frame: Array(buffer.prefix(max(0, n))))
            #expect(reply.message == .rversion(msize: 4096, version: "9P2000.L"))
        }
    }

    @Test("stopping the server releases its port and drops connections")
    func cleanShutdown() throws {
        var configuration = NinePServerConfiguration()
        configuration.endpoints = [.tcp(host: "127.0.0.1", port: 0)]
        let server = NinePServer(fileSystem: MemoryFileSystem(), configuration: configuration)
        let port = try server.start().compactMap(\.port).first
        #expect(port != nil)
        let client = try RawClient(port: UInt16(port ?? 0))
        defer { client.shut() }
        _ = try client.request(
            Frame(tag: P9.notag, message: .tversion(msize: 4096, version: "9P2000.L")),
            codec: MessageCodec(version: .v9P2000))

        server.stop()
        #expect(server.boundEndpoints.isEmpty)
        // The live connection is gone, and the port is free again.
        #expect(throws: RawClient.Failure.self) {
            _ = try client.receiveFrame(MessageCodec(version: .v9P2000L))
        }
        server.stop()   // idempotent
    }
}
