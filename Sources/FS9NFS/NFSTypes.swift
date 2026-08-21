// NFSv3 wire types, RFC 1813 §2.5.
//
// The field orders here are load-bearing and unforgiving: a `fattr3` with two
// fields transposed still decodes without error on the client and shows up
// much later as a file with an absurd size or a directory the Finder refuses
// to open. Everything in this file is written straight from the RFC's XDR
// definition, in the RFC's order.

import Foundation
import FS9Core

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Status

/// `nfsstat3`. Mostly errno values, but only *mostly*: NAMETOOLONG is 63 where
/// Linux's ENAMETOOLONG is 36, and the 10000-range codes have no errno at all.
/// Passing errno through therefore corrupts the reply, so the mapping below is
/// written out by hand.
public enum NFSStatus: UInt32, Sendable, Hashable {
    case ok = 0
    case perm = 1
    case noent = 2
    case io = 5
    case nxio = 6
    case acces = 13
    case exist = 17
    case xdev = 18
    case nodev = 19
    case notdir = 20
    case isdir = 21
    case inval = 22
    case fbig = 27
    case nospc = 28
    case rofs = 30
    case mlink = 31
    case nametoolong = 63
    case notempty = 66
    case dquot = 69
    case stale = 70
    case remote = 71
    case badhandle = 10001
    case notSync = 10002
    case badCookie = 10003
    case notsupp = 10004
    case toosmall = 10005
    case serverfault = 10006
    case badtype = 10007
    case jukebox = 10008

    /// Translates a VFS error into the NFS status a client expects.
    public init(_ error: FSError) {
        self.init(errno: error.errno)
    }

    public init(errno code: Int32) {
        switch code {
        case EPERM: self = .perm
        case ENOENT: self = .noent
        case EIO: self = .io
        case ENXIO: self = .nxio
        case EACCES: self = .acces
        case EEXIST: self = .exist
        case EXDEV: self = .xdev
        case ENODEV: self = .nodev
        case ENOTDIR: self = .notdir
        case EISDIR: self = .isdir
        case EINVAL: self = .inval
        case EFBIG: self = .fbig
        case ENOSPC: self = .nospc
        case EROFS: self = .rofs
        case EMLINK: self = .mlink
        case ENAMETOOLONG: self = .nametoolong
        case ENOTEMPTY: self = .notempty
        case EDQUOT: self = .dquot
        case ESTALE: self = .stale
        case EREMOTE: self = .remote
        case ENOTSUP, ENOSYS: self = .notsupp
        // A backend that is momentarily busy is a retry, not a failure: NFS
        // spells that JUKEBOX and the client comes back rather than erroring.
        case EAGAIN, EBUSY: self = .jukebox
        case EINTR: self = .jukebox
        case EBADF: self = .badhandle
        case ELOOP: self = .inval
        case EFAULT, ENOMEM: self = .serverfault
        default: self = .serverfault
        }
    }

    /// Thrown by handlers; the procedure wrapper turns it into a status-only
    /// (or status-plus-wcc) reply.
    public struct Failure: Error, Sendable {
        public var status: NFSStatus
        public init(_ status: NFSStatus) { self.status = status }
    }

    public var failure: Failure { Failure(self) }
}

/// Normalises anything thrown inside a procedure into an `nfsstat3`.
func nfsStatus(for error: any Error) -> NFSStatus {
    switch error {
    case let failure as NFSStatus.Failure: return failure.status
    case let fsError as FSError: return NFSStatus(fsError)
    case is XDRError: return .inval
    default: return NFSStatus(FSError.from(error))
    }
}

// MARK: - Small types

/// `ftype3`. These are *not* the POSIX `S_IF*` values; the numbering is NFS's
/// own and starts at 1.
public enum NFSFileType: UInt32, Sendable {
    case regular = 1
    case directory = 2
    case block = 3
    case character = 4
    case link = 5
    case socket = 6
    case fifo = 7

    public init(_ type: FileType) {
        switch type {
        case .regular: self = .regular
        case .directory: self = .directory
        case .symlink: self = .link
        case .blockDevice: self = .block
        case .characterDevice: self = .character
        case .socket: self = .socket
        case .fifo: self = .fifo
        }
    }
}

/// `nfstime3`: seconds and nanoseconds, both *unsigned 32-bit*. A post-2106
/// timestamp cannot be represented, and a 64-bit seconds value must be
/// truncated rather than wrapped into something nonsensical.
public struct NFSTime: Sendable, Hashable {
    public var seconds: UInt32
    public var nanoseconds: UInt32

    public init(seconds: UInt32, nanoseconds: UInt32) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    public init(_ time: FileTime) {
        self.seconds = UInt32(clamping: time.seconds)
        self.nanoseconds = min(time.nanoseconds, 999_999_999)
    }

    public var fileTime: FileTime {
        FileTime(seconds: UInt64(seconds), nanoseconds: nanoseconds)
    }

    public static func encode(_ e: inout XDREncoder, _ time: NFSTime) {
        e.uint32(time.seconds)
        e.uint32(time.nanoseconds)
    }

    public static func decode(_ d: inout XDRDecoder) throws -> NFSTime {
        NFSTime(seconds: try d.uint32(), nanoseconds: try d.uint32())
    }
}

/// `fattr3`, in RFC order. `used` is bytes occupied, not blocks, and `rdev` is
/// a `specdata3` — two 32-bit halves, major then minor — not a single number.
public struct NFSFileAttributes: Sendable {
    public var type: NFSFileType
    public var mode: UInt32
    public var linkCount: UInt32
    public var uid: UInt32
    public var gid: UInt32
    public var size: UInt64
    public var used: UInt64
    public var rdevMajor: UInt32
    public var rdevMinor: UInt32
    public var fsid: UInt64
    public var fileid: UInt64
    public var accessTime: NFSTime
    public var modifyTime: NFSTime
    public var changeTime: NFSTime

    /// Bytes a `fattr3` occupies on the wire. Fixed, which is what makes
    /// READDIRPLUS budgeting possible without encoding twice.
    public static let encodedSize = 84

    public init(_ attributes: FileAttributes, fsid: UInt64) {
        self.type = NFSFileType(attributes.type)
        // The client wants a full st_mode-shaped value here; the low twelve
        // bits are what it actually uses for permission checks.
        self.mode = UInt32(attributes.permissions)
        self.linkCount = max(1, attributes.linkCount)
        self.uid = attributes.uid
        self.gid = attributes.gid
        self.size = attributes.size
        // A sparse or unreported allocation of zero makes `du` claim the file
        // occupies nothing; fall back to the apparent size rounded up.
        self.used = attributes.allocatedSize == 0
            ? (attributes.size + 511) / 512 * 512
            : attributes.allocatedSize
        self.rdevMajor = (attributes.rdev >> 8) & 0xFFF
        self.rdevMinor = attributes.rdev & 0xFF
        self.fsid = fsid
        self.fileid = attributes.fileID
        self.accessTime = NFSTime(attributes.accessTime)
        self.modifyTime = NFSTime(attributes.modifyTime)
        self.changeTime = NFSTime(attributes.changeTime)
    }

    public func encode(into e: inout XDREncoder) {
        e.uint32(type.rawValue)
        e.uint32(mode)
        e.uint32(linkCount)
        e.uint32(uid)
        e.uint32(gid)
        e.uint64(size)
        e.uint64(used)
        e.uint32(rdevMajor)
        e.uint32(rdevMinor)
        e.uint64(fsid)
        e.uint64(fileid)
        NFSTime.encode(&e, accessTime)
        NFSTime.encode(&e, modifyTime)
        NFSTime.encode(&e, changeTime)
    }
}

/// `post_op_attr`: a boolean, then a `fattr3` if it is true.
///
/// Always sending attributes is not required, but macOS's client caches on
/// them aggressively, and omitting them turns every operation into an extra
/// GETATTR round trip.
func encodePostOpAttributes(_ e: inout XDREncoder, _ attributes: NFSFileAttributes?) {
    guard let attributes else { return e.bool(false) }
    e.bool(true)
    attributes.encode(into: &e)
}

/// `wcc_attr`: the *subset* of attributes a client compares to detect that
/// someone else changed the file — size, mtime, ctime, in that order.
public struct NFSWccAttributes: Sendable {
    public var size: UInt64
    public var modifyTime: NFSTime
    public var changeTime: NFSTime

    public init(_ attributes: FileAttributes) {
        self.size = attributes.size
        self.modifyTime = NFSTime(attributes.modifyTime)
        self.changeTime = NFSTime(attributes.changeTime)
    }

    func encode(into e: inout XDREncoder) {
        e.uint64(size)
        NFSTime.encode(&e, modifyTime)
        NFSTime.encode(&e, changeTime)
    }
}

/// `wcc_data`: what the object looked like before the operation and after it.
///
/// Every modifying procedure returns this, on success *and* on failure. The
/// client uses the before-image to decide whether its cached pages are still
/// valid; a server that omits it (or sends a stale before-image) produces the
/// classic "I wrote the file but reads still show the old bytes" bug.
public struct NFSWccData: Sendable {
    public var before: NFSWccAttributes?
    public var after: NFSFileAttributes?

    public init(before: NFSWccAttributes? = nil, after: NFSFileAttributes? = nil) {
        self.before = before
        self.after = after
    }

    public func encode(into e: inout XDREncoder) {
        if let before {
            e.bool(true)
            before.encode(into: &e)
        } else {
            e.bool(false)
        }
        encodePostOpAttributes(&e, after)
    }
}

// MARK: - sattr3

/// How a SETATTR-style call wants a timestamp changed.
public enum NFSTimeHow: Sendable, Equatable {
    case dontChange
    case setToServerTime
    case setToClientTime(NFSTime)

    static func decode(_ d: inout XDRDecoder) throws -> NFSTimeHow {
        switch try d.uint32() {
        case 0: return .dontChange
        case 1: return .setToServerTime
        case 2: return .setToClientTime(try NFSTime.decode(&d))
        // An unknown discriminant means we no longer know where the next field
        // starts, so the whole request is garbage.
        default: throw XDRError.invalidBoolean(2)
        }
    }
}

/// `sattr3`: six independently optional fields. Each is a boolean followed by
/// the value, except the two timestamps, which are a three-way enum instead —
/// SET_TO_SERVER_TIME carries no payload at all.
public struct NFSSetAttributes: Sendable {
    public var mode: UInt32?
    public var uid: UInt32?
    public var gid: UInt32?
    public var size: UInt64?
    public var accessTime: NFSTimeHow = .dontChange
    public var modifyTime: NFSTimeHow = .dontChange

    public init() {}

    public static func decode(_ d: inout XDRDecoder) throws -> NFSSetAttributes {
        var out = NFSSetAttributes()
        out.mode = try d.optional { try $0.uint32() }
        out.uid = try d.optional { try $0.uint32() }
        out.gid = try d.optional { try $0.uint32() }
        out.size = try d.optional { try $0.uint64() }
        out.accessTime = try NFSTimeHow.decode(&d)
        out.modifyTime = try NFSTimeHow.decode(&d)
        return out
    }

    /// True when nothing at all was requested, which SETATTR is allowed to
    /// treat as a no-op that still returns fresh attributes.
    public var isEmpty: Bool {
        mode == nil && uid == nil && gid == nil && size == nil
            && accessTime == .dontChange && modifyTime == .dontChange
    }

    /// Resolves the timestamps into concrete values, substituting the server
    /// clock for SET_TO_SERVER_TIME.
    public func resolvedTimes(now: FileTime) -> (access: FileTime?, modify: FileTime?) {
        func resolve(_ how: NFSTimeHow) -> FileTime? {
            switch how {
            case .dontChange: return nil
            case .setToServerTime: return now
            case let .setToClientTime(t): return t.fileTime
            }
        }
        return (resolve(accessTime), resolve(modifyTime))
    }
}

// MARK: - ACCESS

/// `ACCESS3` bits. LOOKUP and EXECUTE both come from the execute permission,
/// but on different file types, so they are computed separately.
public struct NFSAccess: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read = NFSAccess(rawValue: 0x0001)
    public static let lookup = NFSAccess(rawValue: 0x0002)
    public static let modify = NFSAccess(rawValue: 0x0004)
    public static let extend = NFSAccess(rawValue: 0x0008)
    public static let delete = NFSAccess(rawValue: 0x0010)
    public static let execute = NFSAccess(rawValue: 0x0020)

    public static let all: NFSAccess = [.read, .lookup, .modify, .extend, .delete, .execute]
}

/// Computes the ACCESS bitmask for `attributes` as seen by `credentials`.
///
/// This is an ordinary POSIX permission check with two NFS-specific twists:
/// DELETE is a property of the *containing directory*, so for a directory it
/// means "entries can be removed from it" and for a plain file it is reported
/// optimistically; and uid 0 is allowed everything, matching what a local
/// filesystem would do for root.
public func nfsAccessMask(
    for attributes: FileAttributes,
    credentials: AuthSysCredentials?,
    readOnly: Bool
) -> NFSAccess {
    let uid = credentials?.uid ?? 65534
    let mode = UInt32(attributes.permissions)

    let readable: Bool
    let writable: Bool
    let executable: Bool
    if uid == 0 {
        readable = true
        writable = true
        // Even root needs at least one execute bit to run a file, though it
        // may traverse any directory.
        executable = attributes.type == .directory || (mode & 0o111) != 0
    } else if uid == attributes.uid {
        readable = mode & 0o400 != 0
        writable = mode & 0o200 != 0
        executable = mode & 0o100 != 0
    } else if credentials?.belongsToGroup(attributes.gid) == true {
        readable = mode & 0o040 != 0
        writable = mode & 0o020 != 0
        executable = mode & 0o010 != 0
    } else {
        readable = mode & 0o004 != 0
        writable = mode & 0o002 != 0
        executable = mode & 0o001 != 0
    }

    var granted: NFSAccess = []
    if readable { granted.insert(.read) }
    if attributes.type == .directory {
        if executable { granted.insert(.lookup) }
        if writable && !readOnly { granted.formUnion([.modify, .extend, .delete]) }
    } else {
        if executable { granted.insert(.execute) }
        if writable && !readOnly { granted.formUnion([.modify, .extend]) }
        // DELETE on a non-directory is governed by the parent directory, which
        // this call does not name; report it and let the REMOVE fail if not.
        if !readOnly { granted.insert(.delete) }
    }
    return granted
}
