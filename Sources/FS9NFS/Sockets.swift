// Thin socket wrappers.
//
// FS9NFS deliberately depends on nothing outside Foundation and the C library,
// and the equivalent helpers in NinePServer are internal to that target, so
// the handful we need are repeated here. The two platforms disagree about the
// type of `SOCK_STREAM` and about `SO_NOSIGPIPE` versus `MSG_NOSIGNAL`, which
// is what most of this file is for.

import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if canImport(Darwin)
let nfsSockStream = SOCK_STREAM
#else
let nfsSockStream = Int32(SOCK_STREAM.rawValue)
#endif

@inline(__always) func nfsErrno() -> Int32 { errno }

func nfsClose(_ fd: Int32) { _ = close(fd) }

func nfsShutdown(_ fd: Int32) { _ = shutdown(fd, Int32(SHUT_RDWR)) }

func nfsSetIntOption(_ fd: Int32, _ level: Int32, _ option: Int32, _ value: Int32) {
    var v = value
    _ = withUnsafePointer(to: &v) {
        setsockopt(fd, level, option, $0, socklen_t(MemoryLayout<Int32>.size))
    }
}

/// Sets a receive or send timeout so no socket operation can block forever.
func nfsSetTimeout(_ fd: Int32, _ option: Int32, seconds: TimeInterval) {
    guard seconds > 0 else { return }
    let whole = seconds.rounded(.down)
    var tv = timeval()
    tv.tv_sec = Int(whole)
    // `tv_usec` is Int32 on Darwin and Int on Linux; assigning through the
    // struct's own type avoids naming either.
    tv.tv_usec = .init((seconds - whole) * 1_000_000)
    _ = withUnsafePointer(to: &tv) {
        setsockopt(fd, SOL_SOCKET, option, $0, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// `write(2)` on a socket with SIGPIPE suppressed: a dead peer must surface as
/// EPIPE, not as a signal that kills the whole process.
func nfsSend(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    return write(fd, buffer, count)
    #else
    return send(fd, buffer, count, Int32(MSG_NOSIGNAL))
    #endif
}

func nfsReceive(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    read(fd, buffer, count)
}

/// Fills a `sockaddr_in` for an IPv4 loopback-style address.
func nfsMakeAddress(host: String, port: UInt16) -> sockaddr_in? {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else { return nil }
    #if canImport(Darwin)
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    return addr
}

func nfsBind(_ fd: Int32, _ addr: sockaddr_in) -> Int32 {
    var a = addr
    return withUnsafePointer(to: &a) { raw in
        raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}

func nfsConnect(_ fd: Int32, _ addr: sockaddr_in) -> Int32 {
    var a = addr
    return withUnsafePointer(to: &a) { raw in
        raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}

/// The port actually assigned, which is the point of binding to port 0.
func nfsBoundPort(_ fd: Int32) -> UInt16? {
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let rc = withUnsafeMutablePointer(to: &actual) { raw in
        raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard rc == 0 else { return nil }
    return UInt16(bigEndian: actual.sin_port)
}
