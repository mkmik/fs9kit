import Foundation
import NineP

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Dialect-neutral open flags.
///
/// Neither the host's `O_*` constants nor 9P2000's `OpenMode` can be put on the
/// wire directly: 9P2000.L carries *Linux's* numeric `O_*` values, which differ
/// from Darwin's, and base 9P2000 has an entirely different two-bit encoding.
/// Callers use this type and the client translates.
public struct OpenFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read      = OpenFlags(rawValue: 1 << 0)
    public static let write     = OpenFlags(rawValue: 1 << 1)
    public static let append    = OpenFlags(rawValue: 1 << 2)
    public static let truncate  = OpenFlags(rawValue: 1 << 3)
    public static let create    = OpenFlags(rawValue: 1 << 4)
    public static let exclusive = OpenFlags(rawValue: 1 << 5)
    public static let directory = OpenFlags(rawValue: 1 << 6)
    /// Remove the file when the fid is clunked (9P2000's ORCLOSE).
    public static let removeOnClose = OpenFlags(rawValue: 1 << 7)
    public static let noFollow  = OpenFlags(rawValue: 1 << 8)
    public static let sync      = OpenFlags(rawValue: 1 << 9)

    public static let readWrite: OpenFlags = [.read, .write]

    /// Builds flags from the host's `O_*` bits, as handed to us by the kernel.
    public init(posix: Int32) {
        var f = OpenFlags()
        switch posix & 0x3 {
        case O_WRONLY: f.insert(.write)
        case O_RDWR: f.formUnion(.readWrite)
        default: f.insert(.read)
        }
        if posix & O_APPEND != 0 { f.insert(.append) }
        if posix & O_TRUNC != 0 { f.insert(.truncate) }
        if posix & O_CREAT != 0 { f.insert(.create) }
        if posix & O_EXCL != 0 { f.insert(.exclusive) }
        if posix & O_NOFOLLOW != 0 { f.insert(.noFollow) }
        if posix & O_SYNC != 0 { f.insert(.sync) }
        #if canImport(Darwin)
        if posix & O_DIRECTORY != 0 { f.insert(.directory) }
        #endif
        self = f
    }

    /// The 9P2000.L representation, using Linux's numeric constants.
    public var linux: LinuxOpenFlags {
        var f = LinuxOpenFlags()
        if contains(.read) && contains(.write) { f.insert(.rdwr) }
        else if contains(.write) { f.insert(.wronly) }
        if contains(.append) { f.insert(.append) }
        if contains(.truncate) { f.insert(.trunc) }
        if contains(.create) { f.insert(.create) }
        if contains(.exclusive) { f.insert(.excl) }
        if contains(.directory) { f.insert(.directory) }
        if contains(.noFollow) { f.insert(.nofollow) }
        if contains(.sync) { f.insert(.sync) }
        return f
    }

    /// The base 9P2000 representation.
    ///
    /// 9P2000 has no create/exclusive bits on Topen — those live in Tcreate —
    /// and no way to say "directory", so they are dropped here.
    public var legacy: OpenMode {
        var m = OpenMode()
        if contains(.read) && contains(.write) { m.insert(.rdwr) }
        else if contains(.write) { m.insert(.write) }
        if contains(.truncate) { m.insert(.trunc) }
        if contains(.removeOnClose) { m.insert(.rclose) }
        return m
    }
}
