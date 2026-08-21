import Foundation
import NineP
import NinePClient

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The kind of a file, independent of any one protocol's encoding.
public enum FileType: Sendable, Hashable {
    case regular
    case directory
    case symlink
    case fifo
    case socket
    case blockDevice
    case characterDevice

    /// The POSIX `st_mode` type bits for this kind.
    public var posixBits: UInt32 {
        switch self {
        case .regular: PosixFileType.reg
        case .directory: PosixFileType.dir
        case .symlink: PosixFileType.lnk
        case .fifo: PosixFileType.fifo
        case .socket: PosixFileType.sock
        case .blockDevice: PosixFileType.blk
        case .characterDevice: PosixFileType.chr
        }
    }

    public init(posixMode: UInt32) {
        switch posixMode & PosixFileType.mask {
        case PosixFileType.dir: self = .directory
        case PosixFileType.lnk: self = .symlink
        case PosixFileType.fifo: self = .fifo
        case PosixFileType.sock: self = .socket
        case PosixFileType.blk: self = .blockDevice
        case PosixFileType.chr: self = .characterDevice
        default: self = .regular
        }
    }

    /// The `d_type` value a readdir reports for this kind.
    public var direntType: UInt8 {
        switch self {
        case .regular: DirentType.reg
        case .directory: DirentType.dir
        case .symlink: DirentType.lnk
        case .fifo: DirentType.fifo
        case .socket: DirentType.sock
        case .blockDevice: DirentType.blk
        case .characterDevice: DirentType.chr
        }
    }

    public init(direntType: UInt8) {
        switch direntType {
        case DirentType.dir: self = .directory
        case DirentType.lnk: self = .symlink
        case DirentType.fifo: self = .fifo
        case DirentType.sock: self = .socket
        case DirentType.blk: self = .blockDevice
        case DirentType.chr: self = .characterDevice
        default: self = .regular
        }
    }
}

/// A timestamp with nanosecond resolution.
public struct FileTime: Sendable, Hashable {
    public var seconds: UInt64
    public var nanoseconds: UInt32

    public init(seconds: UInt64, nanoseconds: UInt32 = 0) {
        self.seconds = seconds
        // Servers occasionally report out-of-range nanoseconds; clamp rather
        // than propagate a value that would make a timespec invalid.
        self.nanoseconds = min(nanoseconds, 999_999_999)
    }

    public static let epoch = FileTime(seconds: 0)

    public static func now() -> FileTime {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return FileTime(seconds: UInt64(ts.tv_sec), nanoseconds: UInt32(ts.tv_nsec))
    }

    public var timeIntervalSince1970: Double {
        Double(seconds) + Double(nanoseconds) / 1e9
    }
}

/// One file's metadata, in the shape both mount backends want.
public struct FileAttributes: Sendable, Hashable {
    /// Stable identifier for the file; used as the inode number.
    public var fileID: UInt64
    public var type: FileType
    /// Permission and setuid/setgid/sticky bits only — no type bits.
    public var permissions: UInt16
    public var uid: UInt32
    public var gid: UInt32
    public var linkCount: UInt32
    public var size: UInt64
    /// Bytes actually occupied; may exceed `size` for a preallocated file, or
    /// be smaller for a sparse one.
    public var allocatedSize: UInt64
    public var accessTime: FileTime
    public var modifyTime: FileTime
    public var changeTime: FileTime
    public var birthTime: FileTime
    /// Device number for block and character devices.
    public var rdev: UInt32

    public init(
        fileID: UInt64, type: FileType, permissions: UInt16, uid: UInt32, gid: UInt32,
        linkCount: UInt32 = 1, size: UInt64 = 0, allocatedSize: UInt64 = 0,
        accessTime: FileTime = .epoch, modifyTime: FileTime = .epoch,
        changeTime: FileTime = .epoch, birthTime: FileTime = .epoch, rdev: UInt32 = 0
    ) {
        self.fileID = fileID
        self.type = type
        self.permissions = permissions
        self.uid = uid
        self.gid = gid
        self.linkCount = linkCount
        self.size = size
        self.allocatedSize = allocatedSize
        self.accessTime = accessTime
        self.modifyTime = modifyTime
        self.changeTime = changeTime
        self.birthTime = birthTime
        self.rdev = rdev
    }

    /// The full POSIX `st_mode`, type bits included.
    public var posixMode: UInt32 { type.posixBits | UInt32(permissions) }

    /// Builds attributes from a 9P2000.L getattr reply.
    ///
    /// `fileID` is supplied by the caller rather than taken from the server:
    /// 9P promises qid paths are unique within a server, but not every server
    /// keeps that promise across a whole tree, and the mount layers need an
    /// identifier they control.
    public init(fileID: UInt64, attr: LinuxAttr) {
        self.init(
            fileID: fileID,
            type: FileType(posixMode: attr.mode),
            permissions: UInt16(attr.mode & 0o7777),
            uid: attr.uid, gid: attr.gid,
            linkCount: UInt32(clamping: attr.nlink),
            size: attr.size,
            allocatedSize: attr.blocks * 512,
            accessTime: FileTime(seconds: attr.atimeSec, nanoseconds: UInt32(clamping: attr.atimeNsec)),
            modifyTime: FileTime(seconds: attr.mtimeSec, nanoseconds: UInt32(clamping: attr.mtimeNsec)),
            changeTime: FileTime(seconds: attr.ctimeSec, nanoseconds: UInt32(clamping: attr.ctimeNsec)),
            birthTime: attr.valid.contains(.btime)
                ? FileTime(seconds: attr.btimeSec, nanoseconds: UInt32(clamping: attr.btimeNsec))
                : FileTime(seconds: attr.ctimeSec, nanoseconds: UInt32(clamping: attr.ctimeNsec)),
            rdev: UInt32(clamping: attr.rdev))
    }
}

/// Free-space and limit reporting for a whole volume.
public struct FilesystemStats: Sendable, Hashable {
    public var blockSize: UInt32
    public var totalBlocks: UInt64
    public var freeBlocks: UInt64
    public var availableBlocks: UInt64
    public var totalFiles: UInt64
    public var freeFiles: UInt64
    public var maximumNameLength: UInt32

    public init(
        blockSize: UInt32, totalBlocks: UInt64, freeBlocks: UInt64, availableBlocks: UInt64,
        totalFiles: UInt64, freeFiles: UInt64, maximumNameLength: UInt32
    ) {
        self.blockSize = blockSize
        self.totalBlocks = totalBlocks
        self.freeBlocks = freeBlocks
        self.availableBlocks = availableBlocks
        self.totalFiles = totalFiles
        self.freeFiles = freeFiles
        self.maximumNameLength = maximumNameLength
    }

    public init(_ s: StatFS) {
        // A server that reports a zero block size would make every caller
        // divide by zero; substitute something sane.
        let bsize = s.bsize == 0 ? 4096 : s.bsize
        self.init(
            blockSize: bsize, totalBlocks: s.blocks, freeBlocks: s.bfree,
            availableBlocks: s.bavail, totalFiles: s.files, freeFiles: s.ffree,
            maximumNameLength: s.namelen == 0 ? 255 : s.namelen)
    }
}

/// An error with a POSIX errno, which is what both mount backends must report.
public struct FSError: Error, CustomStringConvertible, Equatable {
    public var errno: Int32
    public var detail: String

    public init(_ errno: Int32, _ detail: String = "") {
        self.errno = errno
        self.detail = detail
    }

    public var description: String {
        let base = String(cString: strerror(errno))
        return detail.isEmpty ? base : "\(base): \(detail)"
    }

    public static let notFound = FSError(ENOENT)
    public static let notDirectory = FSError(ENOTDIR)
    public static let isDirectory = FSError(EISDIR)
    public static let exists = FSError(EEXIST)
    public static let notEmpty = FSError(ENOTEMPTY)
    public static let permissionDenied = FSError(EACCES)
    public static let notSupported = FSError(ENOTSUP)
    public static let staleHandle = FSError(ESTALE)
    public static let invalidArgument = FSError(EINVAL)
    public static let nameTooLong = FSError(ENAMETOOLONG)

    /// Normalises anything thrown by the 9P layers into an errno.
    public static func from(_ error: any Error) -> FSError {
        switch error {
        case let e as FSError: return e
        case let e as NinePServerError: return FSError(e.errno, e.message)
        case is CancellationError: return FSError(EINTR, "cancelled")
        default: break
        }
        return FSError(EIO, String(describing: error))
    }
}
