import Foundation
import NineP
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Linux errno values.
///
/// A 9P2000.L server puts a bare errno on the wire and the peer interprets it
/// with *Linux* numbering, so these must not be taken from the host's headers:
/// `ENOTEMPTY` is 39 on Linux but 66 on Darwin, and several others differ too.
public enum LinuxErrno {
    public static let eperm: UInt32 = 1
    public static let enoent: UInt32 = 2
    public static let esrch: UInt32 = 3
    public static let eintr: UInt32 = 4
    public static let eio: UInt32 = 5
    public static let enxio: UInt32 = 6
    public static let ebadf: UInt32 = 9
    public static let eagain: UInt32 = 11
    public static let enomem: UInt32 = 12
    public static let eacces: UInt32 = 13
    public static let efault: UInt32 = 14
    public static let ebusy: UInt32 = 16
    public static let eexist: UInt32 = 17
    public static let exdev: UInt32 = 18
    public static let enodev: UInt32 = 19
    public static let enotdir: UInt32 = 20
    public static let eisdir: UInt32 = 21
    public static let einval: UInt32 = 22
    public static let enfile: UInt32 = 23
    public static let emfile: UInt32 = 24
    public static let efbig: UInt32 = 27
    public static let enospc: UInt32 = 28
    public static let espipe: UInt32 = 29
    public static let erofs: UInt32 = 30
    public static let emlink: UInt32 = 31
    public static let enametoolong: UInt32 = 36
    public static let enosys: UInt32 = 38
    public static let enotempty: UInt32 = 39
    public static let eloop: UInt32 = 40
    public static let enodata: UInt32 = 61
    public static let eproto: UInt32 = 71
    public static let emsgsize: UInt32 = 90
    public static let eopnotsupp: UInt32 = 95
    public static let econnreset: UInt32 = 104
}

/// A failure that can be turned into any of the three 9P error replies.
///
/// The dialects disagree about the shape of an error — 9P2000 carries only a
/// string, 9P2000.u adds an errno, 9P2000.L carries only the errno — so every
/// failure inside the server records both and the session picks the encoding.
public struct NinePServerError: Error, Sendable, Hashable, CustomStringConvertible {
    public var errno: UInt32
    public var message: String

    public init(errno: UInt32, message: String) {
        self.errno = errno
        self.message = message
    }

    public var description: String { "\(message) (errno \(errno))" }

    public static func permissionDenied(_ what: String = "permission denied") -> NinePServerError {
        NinePServerError(errno: LinuxErrno.eacces, message: what)
    }
    public static func noSuchFile(_ what: String = "no such file or directory") -> NinePServerError {
        NinePServerError(errno: LinuxErrno.enoent, message: what)
    }
    public static func notADirectory(_ what: String = "not a directory") -> NinePServerError {
        NinePServerError(errno: LinuxErrno.enotdir, message: what)
    }
    public static func isADirectory(_ what: String = "is a directory") -> NinePServerError {
        NinePServerError(errno: LinuxErrno.eisdir, message: what)
    }
    public static func alreadyExists(_ what: String = "file already exists") -> NinePServerError {
        NinePServerError(errno: LinuxErrno.eexist, message: what)
    }
    public static func notEmpty(_ what: String = "directory not empty") -> NinePServerError {
        NinePServerError(errno: LinuxErrno.enotempty, message: what)
    }
    public static func invalidArgument(_ what: String = "invalid argument") -> NinePServerError {
        NinePServerError(errno: LinuxErrno.einval, message: what)
    }
    public static func badFileDescriptor(_ what: String = "bad file descriptor") -> NinePServerError {
        NinePServerError(errno: LinuxErrno.ebadf, message: what)
    }
    public static func notSupported(_ what: String = "operation not supported") -> NinePServerError {
        NinePServerError(errno: LinuxErrno.eopnotsupp, message: what)
    }
    public static func crossDevice(_ what: String = "cross-device link") -> NinePServerError {
        NinePServerError(errno: LinuxErrno.exdev, message: what)
    }
    public static func io(_ what: String = "input/output error") -> NinePServerError {
        NinePServerError(errno: LinuxErrno.eio, message: what)
    }

    /// Translates a host `errno` into the Linux-numbered equivalent.
    ///
    /// Codes we do not know about are passed through unchanged; that is wrong
    /// on Darwin for exotic values but better than inventing an EIO.
    public static func fromHostErrno(_ code: Int32, while action: String? = nil) -> NinePServerError {
        let text = String(cString: strerror(code))
        let message = action.map { "\($0): \(text)" } ?? text
        return NinePServerError(errno: linuxErrno(forHost: code), message: message)
    }

    static func linuxErrno(forHost code: Int32) -> UInt32 {
        switch code {
        case EPERM: return LinuxErrno.eperm
        case ENOENT: return LinuxErrno.enoent
        case ESRCH: return LinuxErrno.esrch
        case EINTR: return LinuxErrno.eintr
        case EIO: return LinuxErrno.eio
        case ENXIO: return LinuxErrno.enxio
        case EBADF: return LinuxErrno.ebadf
        case EAGAIN: return LinuxErrno.eagain
        case ENOMEM: return LinuxErrno.enomem
        case EACCES: return LinuxErrno.eacces
        case EFAULT: return LinuxErrno.efault
        case EBUSY: return LinuxErrno.ebusy
        case EEXIST: return LinuxErrno.eexist
        case EXDEV: return LinuxErrno.exdev
        case ENODEV: return LinuxErrno.enodev
        case ENOTDIR: return LinuxErrno.enotdir
        case EISDIR: return LinuxErrno.eisdir
        case EINVAL: return LinuxErrno.einval
        case ENFILE: return LinuxErrno.enfile
        case EMFILE: return LinuxErrno.emfile
        case EFBIG: return LinuxErrno.efbig
        case ENOSPC: return LinuxErrno.enospc
        case ESPIPE: return LinuxErrno.espipe
        case EROFS: return LinuxErrno.erofs
        case EMLINK: return LinuxErrno.emlink
        case ENAMETOOLONG: return LinuxErrno.enametoolong
        case ENOSYS: return LinuxErrno.enosys
        case ENOTEMPTY: return LinuxErrno.enotempty
        case ELOOP: return LinuxErrno.eloop
        case EPROTO: return LinuxErrno.eproto
        case EMSGSIZE: return LinuxErrno.emsgsize
        case EOPNOTSUPP: return LinuxErrno.eopnotsupp
        case ECONNRESET: return LinuxErrno.econnreset
        default: return UInt32(bitPattern: code)
        }
    }
}

extension Error {
    /// Normalises any thrown value into something the session can reply with.
    var asNinePServerError: NinePServerError {
        if let e = self as? NinePServerError { return e }
        if let e = self as? NinePWireError {
            return NinePServerError(errno: LinuxErrno.eproto, message: "malformed message: \(e)")
        }
        return NinePServerError(errno: LinuxErrno.eio, message: "\(self)")
    }
}
