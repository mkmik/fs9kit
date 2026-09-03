import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Thin wrappers around the C library.
//
// They exist for two reasons: the two platforms disagree about a handful of
// constants and struct field names, and — more mundanely — several of the
// syscalls we need share a name with a method on ``NinePFileServer``
// (`open`, `create`, `symlink`, `rename`, `link`, `sync`, `statfs`), where an
// unqualified call would resolve to the method and recurse. Every wrapper here
// lives at file scope, where the C function is what a bare name means.

/// Largest path we will hand to the C library.
let sysPathMax = 4096

@inline(__always) func sysErrno() -> Int32 { errno }

func sysOpen(_ path: String, _ flags: Int32, _ mode: mode_t = 0) -> Int32 {
    path.withCString { open($0, flags, mode) }
}

func sysClose(_ fd: Int32) { _ = close(fd) }

func sysPread(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int, _ offset: off_t) -> Int {
    pread(fd, buffer, count, offset)
}

func sysPwrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int, _ offset: off_t) -> Int {
    pwrite(fd, buffer, count, offset)
}

func sysRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    read(fd, buffer, count)
}

/// Plain `write(2)`, for regular files and pipes.
func sysWriteFile(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    write(fd, buffer, count)
}

/// `write(2)` for sockets, with SIGPIPE suppressed.
func sysWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    // SIGPIPE is disabled per-socket with SO_NOSIGPIPE; see PosixSocket.
    return write(fd, buffer, count)
    #else
    // MSG_NOSIGNAL only applies to sockets, and every fd we write to here is
    // one, so a dead peer surfaces as EPIPE instead of killing the process.
    return send(fd, buffer, count, Int32(MSG_NOSIGNAL))
    #endif
}

func sysFsync(_ fd: Int32) -> Int32 { fsync(fd) }
func sysFtruncate(_ fd: Int32, _ length: off_t) -> Int32 { ftruncate(fd, length) }

func sysLstat(_ path: String, _ out: inout stat) -> Int32 {
    var buffer = stat()
    let rc = path.withCString { lstat($0, &buffer) }
    out = buffer
    return rc
}

func sysMkdir(_ path: String, _ mode: mode_t) -> Int32 { path.withCString { mkdir($0, mode) } }
func sysRmdir(_ path: String) -> Int32 { path.withCString { rmdir($0) } }
func sysUnlink(_ path: String) -> Int32 { path.withCString { unlink($0) } }
func sysChmod(_ path: String, _ mode: mode_t) -> Int32 { path.withCString { chmod($0, mode) } }
func sysChown(_ path: String, _ uid: uid_t, _ gid: gid_t) -> Int32 {
    path.withCString { chown($0, uid, gid) }
}
func sysTruncate(_ path: String, _ length: off_t) -> Int32 {
    path.withCString { truncate($0, length) }
}

func sysSymlink(_ target: String, _ path: String) -> Int32 {
    target.withCString { t in path.withCString { p in symlink(t, p) } }
}

func sysLink(_ existing: String, _ path: String) -> Int32 {
    existing.withCString { e in path.withCString { p in link(e, p) } }
}

func sysRename(_ from: String, _ to: String) -> Int32 {
    from.withCString { f in to.withCString { t in rename(f, t) } }
}

func sysReadlink(_ path: String) -> String? {
    var buffer = [UInt8](repeating: 0, count: sysPathMax)
    let n = path.withCString { p in
        buffer.withUnsafeMutableBytes { raw in
            readlink(p, raw.baseAddress!.assumingMemoryBound(to: CChar.self), raw.count - 1)
        }
    }
    guard n >= 0 else { return nil }
    return String(decoding: buffer[0..<n], as: UTF8.self)
}

func sysRealpath(_ path: String) -> String? {
    guard let raw = path.withCString({ realpath($0, nil) }) else { return nil }
    defer { free(raw) }
    return String(cString: raw)
}

/// `UTIME_NOW` / `UTIME_OMIT`. Spelled out because they are macros with casts
/// that neither platform's Swift overlay imports.
let sysUtimeNow = Int((1 << 30) - 1)
let sysUtimeOmit = Int((1 << 30) - 2)

func sysUtimensat(_ path: String, _ times: [timespec]) -> Int32 {
    path.withCString { p in
        times.withUnsafeBufferPointer { utimensat(AT_FDCWD, p, $0.baseAddress, 0) }
    }
}

/// The three timestamps of a `stat`, whose field names differ per platform.
func sysStatTimes(_ st: stat) -> (atime: TimeSpec, mtime: TimeSpec, ctime: TimeSpec) {
    #if canImport(Darwin)
    return (TimeSpec(st.st_atimespec), TimeSpec(st.st_mtimespec), TimeSpec(st.st_ctimespec))
    #else
    return (TimeSpec(st.st_atim), TimeSpec(st.st_mtim), TimeSpec(st.st_ctim))
    #endif
}

extension TimeSpec {
    init(_ ts: timespec) {
        self.init(seconds: UInt64(max(0, ts.tv_sec)), nanoseconds: UInt64(max(0, ts.tv_nsec)))
    }

    var asTimespec: timespec {
        timespec(tv_sec: Int(truncatingIfNeeded: seconds), tv_nsec: Int(truncatingIfNeeded: nanoseconds))
    }
}

/// Every name in a directory, unsorted, without `.` and `..`.
func sysListDirectory(_ path: String) throws -> [String] {
    guard let dir = path.withCString({ opendir($0) }) else {
        throw NinePServerError.fromHostErrno(sysErrno(), while: "opendir \(path)")
    }
    defer { closedir(dir) }
    var names: [String] = []
    while let entry = readdir(dir) {
        var raw = entry.pointee
        let capacity = MemoryLayout.size(ofValue: raw.d_name)
        let name = withUnsafePointer(to: &raw.d_name) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        if name == "." || name == ".." { continue }
        names.append(name)
    }
    return names
}

// MARK: - Sockets

#if canImport(Darwin)
let sysSockStream = SOCK_STREAM
#else
let sysSockStream = Int32(SOCK_STREAM.rawValue)
#endif

func sysSocket(_ domain: Int32, _ type: Int32, _ proto: Int32) -> Int32 {
    socket(domain, type, proto)
}

func sysBind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    bind(fd, addr, len)
}

func sysListen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }

func sysAccept(_ fd: Int32) -> Int32 { accept(fd, nil, nil) }

func sysShutdown(_ fd: Int32) { _ = shutdown(fd, Int32(SHUT_RDWR)) }

func sysSetIntOption(_ fd: Int32, _ level: Int32, _ option: Int32, _ value: Int32) {
    var v = value
    _ = withUnsafePointer(to: &v) {
        setsockopt(fd, level, option, $0, socklen_t(MemoryLayout<Int32>.size))
    }
}

func sysGetSockName(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>, _ len: inout socklen_t) -> Int32 {
    getsockname(fd, addr, &len)
}

// MARK: - Filesystem statistics

/// `statvfs(3)`: the same struct on Linux and Darwin, unlike `statfs`.
func sysStatvfs(_ path: String) -> statvfs? {
    var buffer = statvfs()
    let rc = path.withCString { statvfs($0, &buffer) }
    return rc == 0 ? buffer : nil
}
