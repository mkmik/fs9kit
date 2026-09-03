import Foundation
import NineP

/// A wall-clock timestamp with nanosecond resolution.
public struct TimeSpec: Sendable, Hashable {
    public var seconds: UInt64
    public var nanoseconds: UInt64

    public init(seconds: UInt64, nanoseconds: UInt64 = 0) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    public static func now() -> TimeSpec {
        let t = Date().timeIntervalSince1970
        let secs = t.rounded(.down)
        return TimeSpec(seconds: UInt64(max(0, secs)),
                        nanoseconds: UInt64(max(0, (t - secs) * 1_000_000_000)))
    }
}

/// A path inside an exported tree, as a list of name components.
///
/// The root is the empty component list. Components never contain `/`, `.` or
/// `..`: ``NinePServerSession`` resolves those while walking, so a provider never has
/// to think about traversal (and cannot be tricked by it).
public struct FilePath: Sendable, Hashable {
    public private(set) var components: [String]

    public init(_ components: [String] = []) {
        self.components = components
    }

    /// Splits a slash-separated path. Empty, `.` and `..` elements are folded
    /// away, so `"/a/../b"` and `"b"` name the same file.
    public init(posix string: String) {
        var out: [String] = []
        for part in string.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !out.isEmpty { out.removeLast() }
            default: out.append(String(part))
            }
        }
        self.components = out
    }

    public var isRoot: Bool { components.isEmpty }

    /// The final component, or `/` for the root.
    public var name: String { components.last ?? "/" }

    public var parent: FilePath? {
        components.isEmpty ? nil : FilePath(components.dropLast().map { $0 })
    }

    public func appending(_ name: String) -> FilePath {
        FilePath(components + [name])
    }

    /// Slash-separated rendering, always absolute. Used for diagnostics and by
    /// providers that address files by string path.
    public var posixString: String {
        components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    /// True when `self` is `other` or lives underneath it.
    public func isInside(_ other: FilePath) -> Bool {
        guard components.count >= other.components.count else { return false }
        return Array(components.prefix(other.components.count)) == other.components
    }
}

/// Everything the server needs to know about one file.
///
/// This is deliberately POSIX-shaped: `mode` is a `st_mode` including the type
/// bits. The session derives both the 9P2000 ``Stat`` and the 9P2000.L
/// ``LinuxAttr`` from it, so providers implement one model instead of two.
public struct FileEntry: Sendable, Hashable {
    public var name: String
    public var qid: Qid
    public var mode: UInt32
    public var uid: UInt32
    public var gid: UInt32
    /// Textual owner, used by 9P2000 stat which has no numeric ids.
    public var ownerName: String
    public var groupName: String
    public var nlink: UInt64
    public var size: UInt64
    public var rdev: UInt64
    public var blockSize: UInt64
    public var blocks: UInt64
    public var atime: TimeSpec
    public var mtime: TimeSpec
    public var ctime: TimeSpec
    /// Target of a symbolic link; `nil` for every other kind of file. 9P2000.u
    /// puts this in the stat extension field.
    public var symlinkTarget: String?

    public init(
        name: String, qid: Qid, mode: UInt32, uid: UInt32 = 0, gid: UInt32 = 0,
        ownerName: String = "nobody", groupName: String = "nobody",
        nlink: UInt64 = 1, size: UInt64 = 0, rdev: UInt64 = 0,
        blockSize: UInt64 = 4096, blocks: UInt64? = nil,
        atime: TimeSpec, mtime: TimeSpec, ctime: TimeSpec,
        symlinkTarget: String? = nil
    ) {
        self.name = name
        self.qid = qid
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.ownerName = ownerName
        self.groupName = groupName
        self.nlink = nlink
        self.size = size
        self.rdev = rdev
        self.blockSize = blockSize
        self.blocks = blocks ?? ((size + 511) / 512)
        self.atime = atime
        self.mtime = mtime
        self.ctime = ctime
        self.symlinkTarget = symlinkTarget
    }

    public var fileType: UInt32 { mode & PosixFileType.mask }
    public var isDirectory: Bool { fileType == PosixFileType.dir }
    public var isSymlink: Bool { fileType == PosixFileType.lnk }
    public var isRegularFile: Bool { fileType == PosixFileType.reg }

    /// POSIX `d_type`, for Rreaddir entries.
    public var direntType: UInt8 {
        switch fileType {
        case PosixFileType.dir: return DirentType.dir
        case PosixFileType.lnk: return DirentType.lnk
        case PosixFileType.reg: return DirentType.reg
        case PosixFileType.fifo: return DirentType.fifo
        case PosixFileType.chr: return DirentType.chr
        case PosixFileType.blk: return DirentType.blk
        case PosixFileType.sock: return DirentType.sock
        default: return DirentType.unknown
        }
    }

    /// The qid flags implied by a POSIX mode.
    public static func qidKind(forMode mode: UInt32) -> Qid.Kind {
        switch mode & PosixFileType.mask {
        case PosixFileType.dir: return .dir
        case PosixFileType.lnk: return .symlink
        default: return .file
        }
    }
}

/// How a timestamp should be updated by ``NinePFileServer/setattr(_:_:)``.
public enum TimeUpdate: Sendable, Hashable {
    /// Set the field to the server's current time.
    case now
    /// Set the field to an explicit value.
    case set(TimeSpec)
}

/// The subset of attributes a Tsetattr (or a Twstat) asks to change. A `nil`
/// field means "leave alone".
public struct SetattrRequest: Sendable, Hashable {
    public var mode: UInt32?
    public var uid: UInt32?
    public var gid: UInt32?
    public var size: UInt64?
    public var atime: TimeUpdate?
    public var mtime: TimeUpdate?
    /// 9P2000 Twstat can change the owner by name; ignored by providers that
    /// have no name database.
    public var ownerName: String?
    public var groupName: String?

    public init(
        mode: UInt32? = nil, uid: UInt32? = nil, gid: UInt32? = nil, size: UInt64? = nil,
        atime: TimeUpdate? = nil, mtime: TimeUpdate? = nil,
        ownerName: String? = nil, groupName: String? = nil
    ) {
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.size = size
        self.atime = atime
        self.mtime = mtime
        self.ownerName = ownerName
        self.groupName = groupName
    }

    public var isEmpty: Bool {
        mode == nil && uid == nil && gid == nil && size == nil
            && atime == nil && mtime == nil && ownerName == nil && groupName == nil
    }
}

/// An open regular file.
///
/// Directories never get one of these: the session snapshots the listing at
/// open time (see ``NinePFileServer/list(_:)``) because both dialects need to
/// hand the listing out in resumable chunks, and a snapshot is the only way to
/// make the resumption offsets mean anything.
public protocol NinePFileHandle: AnyObject, Sendable {
    /// Reads up to `count` bytes. A short result (including empty) means EOF.
    func read(offset: UInt64, count: Int) throws -> [UInt8]
    /// Writes `bytes` and returns how many were stored.
    func write(offset: UInt64, bytes: [UInt8]) throws -> Int
    /// Flushes to stable storage; a no-op for volatile providers.
    func sync() throws
    /// Releases the handle. Must tolerate being called more than once.
    func close()
}

/// The backend behind a 9P server: a tree of files addressed by path.
///
/// Fids live in the session, not here — the session maps each fid to a
/// ``FilePath`` and, once opened, to a ``NinePFileHandle``. That split keeps
/// providers small: they never see walk cloning, tag handling or dialect
/// differences, and a provider is a plain file tree with POSIX-shaped
/// operations.
///
/// Implementations must be safe to call from several connection threads at
/// once.
public protocol NinePFileServer: AnyObject, Sendable {
    /// Resolves a Tattach. `aname` selects the subtree to export; the returned
    /// path becomes the root that `..` cannot climb above.
    func attach(uname: String, aname: String, uid: UInt32) throws -> (path: FilePath, entry: FileEntry)

    /// Metadata for one file. Symbolic links are *not* followed for the final
    /// component: 9P reports the link itself and lets the client resolve it.
    func entry(at path: FilePath) throws -> FileEntry

    /// Children of a directory, in a stable order. `.` and `..` are added by
    /// the session and must not appear here.
    func list(_ path: FilePath) throws -> [FileEntry]

    func open(_ path: FilePath, flags: LinuxOpenFlags) throws -> NinePFileHandle

    /// Creates a regular file and opens it. `mode` is a POSIX permission mask.
    func create(in directory: FilePath, name: String, mode: UInt32,
                flags: LinuxOpenFlags, gid: UInt32) throws -> (entry: FileEntry, handle: NinePFileHandle)

    func mkdir(in directory: FilePath, name: String, mode: UInt32, gid: UInt32) throws -> FileEntry
    func symlink(in directory: FilePath, name: String, target: String, gid: UInt32) throws -> FileEntry
    func readlink(_ path: FilePath) throws -> String
    func link(_ existing: FilePath, in directory: FilePath, name: String) throws

    /// Removes one name. `isDirectory` mirrors `AT_REMOVEDIR`: when true only a
    /// directory may be removed, when false only a non-directory.
    func unlink(in directory: FilePath, name: String, isDirectory: Bool) throws

    func rename(from: FilePath, name: String, to: FilePath, newName: String) throws
    func setattr(_ path: FilePath, _ request: SetattrRequest) throws
    func statfs(_ path: FilePath) throws -> StatFS
    func sync(_ path: FilePath) throws
}

extension NinePFileServer {
    /// Convenience used by the session when it only needs to know the type of
    /// a path's parent.
    func requireDirectory(_ path: FilePath) throws -> FileEntry {
        let e = try entry(at: path)
        guard e.isDirectory else { throw NinePServerError.notADirectory(path.posixString) }
        return e
    }
}
