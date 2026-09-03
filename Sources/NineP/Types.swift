import Foundation

// MARK: - Protocol versions

/// The 9P dialect spoken on a connection, as negotiated by Tversion/Rversion.
public enum NinePVersion: String, Sendable, CaseIterable {
    /// Base 9P2000 as specified in Plan 9 section 5.
    case v9P2000 = "9P2000"
    /// The Unix extension: adds numeric uid/gid and an extension string on create.
    case v9P2000u = "9P2000.u"
    /// The Linux dialect used by Linux/QEMU/diod: POSIX-shaped operations.
    case v9P2000L = "9P2000.L"

    /// True when numeric uid/gid fields are present in stat structures.
    public var hasUnixExtensions: Bool { self == .v9P2000u }

    /// True for the Linux dialect, which replaces stat/wstat with getattr/setattr.
    public var isLinux: Bool { self == .v9P2000L }
}

// MARK: - Qid

/// A server's unique identity for a file: 13 bytes on the wire.
public struct Qid: Sendable, Hashable {
    /// Bit flags describing the kind of file this qid names.
    public struct Kind: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let dir       = Kind(rawValue: 0x80)
        public static let append    = Kind(rawValue: 0x40)
        public static let excl      = Kind(rawValue: 0x20)
        public static let mount     = Kind(rawValue: 0x10)
        public static let auth      = Kind(rawValue: 0x08)
        public static let tmp       = Kind(rawValue: 0x04)
        /// 9P2000.u/.L: the file is a symbolic link.
        public static let symlink   = Kind(rawValue: 0x02)
        /// A plain file: the absence of every other bit.
        public static let file      = Kind([])
    }

    public var kind: Kind
    /// Version counter, bumped by the server whenever the file changes.
    public var version: UInt32
    /// Server-unique file identifier, stable for the life of the file.
    public var path: UInt64

    public init(kind: Kind, version: UInt32, path: UInt64) {
        self.kind = kind
        self.version = version
        self.path = path
    }

    public var isDir: Bool { kind.contains(.dir) }
    public var isSymlink: Bool { kind.contains(.symlink) }

    /// Fixed wire size of a qid.
    public static let wireSize = 13
}

extension ByteReader {
    public mutating func qid() throws -> Qid {
        let kind = Qid.Kind(rawValue: try u8())
        let version = try u32()
        let path = try u64()
        return Qid(kind: kind, version: version, path: path)
    }
}

extension ByteWriter {
    public mutating func qid(_ q: Qid) {
        u8(q.kind.rawValue)
        u32(q.version)
        u64(q.path)
    }
}

// MARK: - File modes and open flags

/// The `mode` field of a 9P2000 stat: permission bits plus type bits.
public struct FileMode: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let dir       = FileMode(rawValue: 0x8000_0000)
    public static let append    = FileMode(rawValue: 0x4000_0000)
    public static let excl      = FileMode(rawValue: 0x2000_0000)
    public static let mount     = FileMode(rawValue: 0x1000_0000)
    public static let auth      = FileMode(rawValue: 0x0800_0000)
    public static let tmp       = FileMode(rawValue: 0x0400_0000)
    /// 9P2000.u: symbolic link.
    public static let symlink   = FileMode(rawValue: 0x0200_0000)
    /// 9P2000.u: named pipe.
    public static let namedPipe = FileMode(rawValue: 0x0020_0000)
    /// 9P2000.u: device file.
    public static let device    = FileMode(rawValue: 0x0080_0000)
    /// 9P2000.u: socket.
    public static let socket    = FileMode(rawValue: 0x0010_0000)
    /// 9P2000.u: setuid.
    public static let setuid    = FileMode(rawValue: 0x0008_0000)
    /// 9P2000.u: setgid.
    public static let setgid    = FileMode(rawValue: 0x0004_0000)

    /// The low nine bits: rwxrwxrwx.
    public static let permMask  = FileMode(rawValue: 0o777)

    public var permissions: UInt16 { UInt16(rawValue & 0o777) }
    public var isDir: Bool { contains(.dir) }
    public var isSymlink: Bool { contains(.symlink) }
}

/// The `mode` byte of Topen/Tcreate in base 9P2000.
public struct OpenMode: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let read   = OpenMode([])
    public static let write  = OpenMode(rawValue: 1)
    public static let rdwr   = OpenMode(rawValue: 2)
    public static let exec   = OpenMode(rawValue: 3)
    /// Truncate the file on open.
    public static let trunc  = OpenMode(rawValue: 0x10)
    /// Remove the file when the fid is clunked.
    public static let rclose = OpenMode(rawValue: 0x40)

    /// The low two bits, which select read/write/rdwr/exec.
    public var access: UInt8 { rawValue & 3 }
}

// MARK: - Stat (9P2000 / 9P2000.u)

/// The 9P2000 stat structure describing one file.
///
/// In Twstat, a field set to its "don't touch" value (all ones for integers,
/// the empty string for strings) asks the server to leave it unchanged.
public struct Stat: Sendable, Hashable {
    /// Server type, "for kernel use".
    public var type: UInt16 = 0
    /// Server subtype, "for kernel use".
    public var dev: UInt32 = 0
    public var qid: Qid
    public var mode: FileMode
    /// Last access time, seconds since the epoch.
    public var atime: UInt32
    /// Last modification time, seconds since the epoch.
    public var mtime: UInt32
    /// File length in bytes; zero for directories on many servers.
    public var length: UInt64
    public var name: String
    /// Owner name.
    public var uid: String
    /// Group name.
    public var gid: String
    /// Name of the user who last modified the file.
    public var muid: String

    // 9P2000.u extension fields. Absent on the wire for plain 9P2000.
    /// Symlink target, device spec, or similar, depending on the file type.
    public var extensionString: String = ""
    public var numericUID: UInt32 = .max
    public var numericGID: UInt32 = .max
    public var numericMUID: UInt32 = .max

    public init(
        type: UInt16 = 0, dev: UInt32 = 0, qid: Qid, mode: FileMode,
        atime: UInt32, mtime: UInt32, length: UInt64,
        name: String, uid: String, gid: String, muid: String,
        extensionString: String = "", numericUID: UInt32 = .max,
        numericGID: UInt32 = .max, numericMUID: UInt32 = .max
    ) {
        self.type = type
        self.dev = dev
        self.qid = qid
        self.mode = mode
        self.atime = atime
        self.mtime = mtime
        self.length = length
        self.name = name
        self.uid = uid
        self.gid = gid
        self.muid = muid
        self.extensionString = extensionString
        self.numericUID = numericUID
        self.numericGID = numericGID
        self.numericMUID = numericMUID
    }

    /// A stat with every field set to "don't touch", ready to be selectively
    /// filled in for a Twstat.
    public static func noTouch(dotu: Bool = false) -> Stat {
        Stat(
            type: .max, dev: .max,
            qid: Qid(kind: Qid.Kind(rawValue: .max), version: .max, path: .max),
            mode: FileMode(rawValue: .max), atime: .max, mtime: .max, length: .max,
            name: "", uid: "", gid: "", muid: "",
            extensionString: "", numericUID: .max, numericGID: .max, numericMUID: .max)
    }
}

extension ByteReader {
    /// Reads a stat structure, including its leading `size[2]`.
    ///
    /// The size field counts the bytes that follow it, so we bound-check the
    /// body and require the decoder to consume exactly that many bytes.
    public mutating func stat(dotu: Bool) throws -> Stat {
        let size = Int(try u16())
        guard remaining >= size else {
            throw NinePWireError.truncated(needed: size, available: remaining)
        }
        var body = ByteReader(try raw(size))
        let type = try body.u16()
        let dev = try body.u32()
        let qid = try body.qid()
        let mode = FileMode(rawValue: try body.u32())
        let atime = try body.u32()
        let mtime = try body.u32()
        let length = try body.u64()
        let name = try body.string()
        let uid = try body.string()
        let gid = try body.string()
        let muid = try body.string()
        var st = Stat(
            type: type, dev: dev, qid: qid, mode: mode, atime: atime, mtime: mtime,
            length: length, name: name, uid: uid, gid: gid, muid: muid)
        if dotu {
            st.extensionString = try body.string()
            st.numericUID = try body.u32()
            st.numericGID = try body.u32()
            st.numericMUID = try body.u32()
        }
        // The size field is exact, so anything left over means we decoded with
        // the wrong dialect (or the server is buggy). Fail loudly.
        try body.expectEmpty()
        return st
    }
}

extension ByteWriter {
    /// Writes a stat structure with its leading `size[2]` backfilled.
    public mutating func stat(_ st: Stat, dotu: Bool) {
        let sizeOffset = count
        u16(0) // placeholder
        let bodyStart = count
        u16(st.type)
        u32(st.dev)
        qid(st.qid)
        u32(st.mode.rawValue)
        u32(st.atime)
        u32(st.mtime)
        u64(st.length)
        string(st.name)
        string(st.uid)
        string(st.gid)
        string(st.muid)
        if dotu {
            string(st.extensionString)
            u32(st.numericUID)
            u32(st.numericGID)
            u32(st.numericMUID)
        }
        patchU16(at: sizeOffset, UInt16(count - bodyStart))
    }
}

// MARK: - 9P2000.L attributes

/// Bits selecting which fields a Tgetattr asks for and which an Rgetattr filled in.
public struct GetattrMask: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let mode        = GetattrMask(rawValue: 0x0000_0001)
    public static let nlink       = GetattrMask(rawValue: 0x0000_0002)
    public static let uid         = GetattrMask(rawValue: 0x0000_0004)
    public static let gid         = GetattrMask(rawValue: 0x0000_0008)
    public static let rdev        = GetattrMask(rawValue: 0x0000_0010)
    public static let atime       = GetattrMask(rawValue: 0x0000_0020)
    public static let mtime       = GetattrMask(rawValue: 0x0000_0040)
    public static let ctime       = GetattrMask(rawValue: 0x0000_0080)
    public static let ino         = GetattrMask(rawValue: 0x0000_0100)
    public static let size        = GetattrMask(rawValue: 0x0000_0200)
    public static let blocks      = GetattrMask(rawValue: 0x0000_0400)
    /// Everything a `stat(2)` needs.
    public static let basic       = GetattrMask(rawValue: 0x0000_07ff)
    public static let btime       = GetattrMask(rawValue: 0x0000_0800)
    public static let gen         = GetattrMask(rawValue: 0x0000_1000)
    public static let dataVersion = GetattrMask(rawValue: 0x0000_2000)
    /// Every defined bit.
    public static let all         = GetattrMask(rawValue: 0x0000_3fff)
}

/// Bits selecting which fields a Tsetattr changes.
public struct SetattrMask: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let mode      = SetattrMask(rawValue: 0x0000_0001)
    public static let uid       = SetattrMask(rawValue: 0x0000_0002)
    public static let gid       = SetattrMask(rawValue: 0x0000_0004)
    public static let size      = SetattrMask(rawValue: 0x0000_0008)
    public static let atime     = SetattrMask(rawValue: 0x0000_0010)
    public static let mtime     = SetattrMask(rawValue: 0x0000_0020)
    public static let ctime     = SetattrMask(rawValue: 0x0000_0040)
    /// Set atime to the value supplied rather than to "now".
    public static let atimeSet  = SetattrMask(rawValue: 0x0000_0080)
    /// Set mtime to the value supplied rather than to "now".
    public static let mtimeSet  = SetattrMask(rawValue: 0x0000_0100)
}

/// The POSIX-shaped attributes returned by Rgetattr.
public struct LinuxAttr: Sendable, Hashable {
    /// Which of the fields below the server actually filled in.
    public var valid: GetattrMask
    public var qid: Qid
    /// POSIX `st_mode`, including the file-type bits.
    public var mode: UInt32
    public var uid: UInt32
    public var gid: UInt32
    public var nlink: UInt64
    public var rdev: UInt64
    public var size: UInt64
    public var blockSize: UInt64
    public var blocks: UInt64
    public var atimeSec: UInt64
    public var atimeNsec: UInt64
    public var mtimeSec: UInt64
    public var mtimeNsec: UInt64
    public var ctimeSec: UInt64
    public var ctimeNsec: UInt64
    public var btimeSec: UInt64
    public var btimeNsec: UInt64
    public var gen: UInt64
    public var dataVersion: UInt64

    public init(
        valid: GetattrMask, qid: Qid, mode: UInt32, uid: UInt32, gid: UInt32,
        nlink: UInt64, rdev: UInt64, size: UInt64, blockSize: UInt64, blocks: UInt64,
        atimeSec: UInt64, atimeNsec: UInt64, mtimeSec: UInt64, mtimeNsec: UInt64,
        ctimeSec: UInt64, ctimeNsec: UInt64, btimeSec: UInt64 = 0, btimeNsec: UInt64 = 0,
        gen: UInt64 = 0, dataVersion: UInt64 = 0
    ) {
        self.valid = valid
        self.qid = qid
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.nlink = nlink
        self.rdev = rdev
        self.size = size
        self.blockSize = blockSize
        self.blocks = blocks
        self.atimeSec = atimeSec
        self.atimeNsec = atimeNsec
        self.mtimeSec = mtimeSec
        self.mtimeNsec = mtimeNsec
        self.ctimeSec = ctimeSec
        self.ctimeNsec = ctimeNsec
        self.btimeSec = btimeSec
        self.btimeNsec = btimeNsec
        self.gen = gen
        self.dataVersion = dataVersion
    }
}

/// POSIX `st_mode` type bits, as carried in `LinuxAttr.mode`.
public enum PosixFileType {
    public static let mask: UInt32   = 0o170000
    public static let fifo: UInt32   = 0o010000
    public static let chr: UInt32    = 0o020000
    public static let dir: UInt32    = 0o040000
    public static let blk: UInt32    = 0o060000
    public static let reg: UInt32    = 0o100000
    public static let lnk: UInt32    = 0o120000
    public static let sock: UInt32   = 0o140000
}

/// One entry of an Rreaddir payload.
public struct Dirent: Sendable, Hashable {
    public var qid: Qid
    /// Opaque cookie: the offset to pass to the *next* Treaddir to resume here.
    public var offset: UInt64
    /// POSIX `d_type` (DT_DIR, DT_REG, ...).
    public var type: UInt8
    public var name: String

    public init(qid: Qid, offset: UInt64, type: UInt8, name: String) {
        self.qid = qid
        self.offset = offset
        self.type = type
        self.name = name
    }
}

/// POSIX `d_type` values used in `Dirent.type`.
public enum DirentType {
    public static let unknown: UInt8 = 0
    public static let fifo: UInt8    = 1
    public static let chr: UInt8     = 2
    public static let dir: UInt8     = 4
    public static let blk: UInt8     = 6
    public static let reg: UInt8     = 8
    public static let lnk: UInt8     = 10
    public static let sock: UInt8    = 12
}

/// The reply to Tstatfs, mirroring `statfs(2)`.
public struct StatFS: Sendable, Hashable {
    public var type: UInt32
    public var bsize: UInt32
    public var blocks: UInt64
    public var bfree: UInt64
    public var bavail: UInt64
    public var files: UInt64
    public var ffree: UInt64
    public var fsid: UInt64
    public var namelen: UInt32

    public init(
        type: UInt32, bsize: UInt32, blocks: UInt64, bfree: UInt64, bavail: UInt64,
        files: UInt64, ffree: UInt64, fsid: UInt64, namelen: UInt32
    ) {
        self.type = type
        self.bsize = bsize
        self.blocks = blocks
        self.bfree = bfree
        self.bavail = bavail
        self.files = files
        self.ffree = ffree
        self.fsid = fsid
        self.namelen = namelen
    }
}

/// Flags for Tlopen and Tlcreate. These are the Linux `O_*` values as they
/// appear on the wire, which are *not* the same as Darwin's `O_*` constants —
/// the client translates.
public struct LinuxOpenFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let rdonly    = LinuxOpenFlags([])
    public static let wronly    = LinuxOpenFlags(rawValue: 0o1)
    public static let rdwr      = LinuxOpenFlags(rawValue: 0o2)
    public static let create    = LinuxOpenFlags(rawValue: 0o100)
    public static let excl      = LinuxOpenFlags(rawValue: 0o200)
    public static let noctty    = LinuxOpenFlags(rawValue: 0o400)
    public static let trunc     = LinuxOpenFlags(rawValue: 0o1000)
    public static let append    = LinuxOpenFlags(rawValue: 0o2000)
    public static let nonblock  = LinuxOpenFlags(rawValue: 0o4000)
    public static let dsync     = LinuxOpenFlags(rawValue: 0o10000)
    public static let directory = LinuxOpenFlags(rawValue: 0o200000)
    public static let nofollow  = LinuxOpenFlags(rawValue: 0o400000)
    public static let noatime   = LinuxOpenFlags(rawValue: 0o1000000)
    public static let cloexec   = LinuxOpenFlags(rawValue: 0o2000000)
    public static let sync      = LinuxOpenFlags(rawValue: 0o4010000)

    public var accessMode: UInt32 { rawValue & 0o3 }
}

/// `flags` for Tunlinkat.
public enum UnlinkAtFlags {
    /// Linux `AT_REMOVEDIR`: the target must be a directory.
    public static let removeDir: UInt32 = 0x200
}

/// Lock types for Tlock/Tgetlock.
public enum LockType {
    public static let read: UInt8  = 0
    public static let write: UInt8 = 1
    public static let unlock: UInt8 = 2
}

/// Status values in Rlock.
public enum LockStatus {
    public static let success: UInt8 = 0
    public static let blocked: UInt8 = 1
    public static let error: UInt8   = 2
    public static let grace: UInt8   = 3
}

/// Flags for Tlock.
public enum LockFlags {
    public static let block: UInt32 = 1
    public static let reclaim: UInt32 = 2
}
