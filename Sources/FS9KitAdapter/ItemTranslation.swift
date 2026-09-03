import Foundation
import NinePClient
import FS9Core

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Item kind

/// A mirror of `FSItem.ItemType`, with the same cases and no FSKit dependency.
///
/// The mapping from `FileType` is the interesting part and it is worth testing
/// on Linux; the last hop to `FSItem.ItemType` is a `switch` in the FSKit shim,
/// so the enum's real raw values never have to be guessed at here.
public enum FS9ItemKind: UInt32, Sendable, Hashable, CaseIterable {
    case unknown = 0
    case file = 1
    case directory = 2
    case symlink = 3
    case fifo = 4
    case charDevice = 5
    case blockDevice = 6
    case socket = 7

    public init(_ type: FileType) {
        switch type {
        case .regular: self = .file
        case .directory: self = .directory
        case .symlink: self = .symlink
        case .fifo: self = .fifo
        case .socket: self = .socket
        case .blockDevice: self = .blockDevice
        case .characterDevice: self = .charDevice
        }
    }

    /// The `FileType` this kind stands for, or `nil` for `.unknown` — 9P has no
    /// way to express "I don't know what this is", so the caller must decide.
    public var fileType: FileType? {
        switch self {
        case .unknown: nil
        case .file: .regular
        case .directory: .directory
        case .symlink: .symlink
        case .fifo: .fifo
        case .charDevice: .characterDevice
        case .blockDevice: .blockDevice
        case .socket: .socket
        }
    }
}

// MARK: - Identifiers

/// Translation between VFS node numbers and FSKit item identifiers.
///
/// FSKit reserves the low identifiers: `FSItem.Identifier.invalid`,
/// `.parentOfRoot` and `.rootDirectory`. `NineVFS` numbers its root 1, which is
/// very likely `.parentOfRoot`, so handing node numbers straight to FSKit would
/// collide. The map below keeps the root on FSKit's root identifier and shifts
/// everything else clear of the reserved range.
///
/// UNCONFIRMED: the raw values of the three reserved identifiers. They follow
/// the HFS convention (root 2, parent-of-root 1) and Apple does not document
/// them. Only the constants change if that is wrong — the shim asks FSKit for
/// `.rootDirectory` rather than hard-coding 2.
public enum FS9ItemIdentifier {
    public static let invalid: UInt64 = 0
    public static let parentOfRoot: UInt64 = 1
    public static let rootDirectory: UInt64 = 2
    /// The first identifier that is ours to hand out.
    public static let firstFree: UInt64 = 4

    /// Maps a VFS node onto an FSKit item identifier.
    public static func itemID(for node: NodeID) -> UInt64 {
        node == NineVFS.rootNode ? rootDirectory : node &+ 2
    }

    /// The inverse. `nil` for anything we could not have issued.
    public static func node(for itemID: UInt64) -> NodeID? {
        switch itemID {
        case rootDirectory: NineVFS.rootNode
        case let value where value >= firstFree: value &- 2
        default: nil
        }
    }
}

// MARK: - Time

/// Converts to the `timespec` FSKit's attribute objects carry.
///
/// `FileTime.seconds` is unsigned and `tv_sec` is signed, so a server reporting
/// a nonsense far-future time would otherwise wrap into the past. Clamp instead:
/// a clamped timestamp is wrong, a negative one makes `ls` print garbage and can
/// upset Finder.
public func fs9Timespec(_ time: FileTime) -> timespec {
    let seconds = time.seconds > UInt64(Int.max) ? Int.max : Int(time.seconds)
    let nanoseconds = Int(min(time.nanoseconds, 999_999_999))
    return timespec(tv_sec: seconds, tv_nsec: nanoseconds)
}

/// The inverse, for `setAttributes`. Times before the epoch are not
/// representable in `FileTime` and become the epoch.
public func fs9FileTime(_ ts: timespec) -> FileTime {
    let seconds = ts.tv_sec < 0 ? 0 : UInt64(ts.tv_sec)
    let nanoseconds = ts.tv_nsec < 0 ? 0 : UInt32(min(ts.tv_nsec, 999_999_999))
    return FileTime(seconds: seconds, nanoseconds: nanoseconds)
}

// MARK: - Attributes

/// Every field the FSKit shim copies onto an `FSItem.Attributes`, as plain
/// values so the arithmetic can be tested without FSKit.
///
/// FSKit will not show a volume in Finder unless the attributes it asked for
/// are all populated — a missing `modifyTime` in particular makes the mount
/// invisible — so this struct deliberately has no optionals: every field always
/// gets an answer.
public struct FS9ItemAttributes: Sendable, Hashable {
    public var kind: FS9ItemKind
    public var itemID: UInt64
    public var parentID: UInt64
    /// Full `st_mode`: type bits, then setuid/setgid/sticky, then permissions.
    public var mode: UInt32
    public var uid: UInt32
    public var gid: UInt32
    public var linkCount: UInt32
    public var size: UInt64
    public var allocSize: UInt64
    public var accessTime: FileTime
    public var modifyTime: FileTime
    public var changeTime: FileTime
    public var birthTime: FileTime
    /// BSD `st_flags`. 9P carries nothing that maps onto it, so it is always 0;
    /// FSKit still asks for it and an unanswered attribute is worse.
    public var flags: UInt32

    public init(
        kind: FS9ItemKind, itemID: UInt64, parentID: UInt64, mode: UInt32,
        uid: UInt32, gid: UInt32, linkCount: UInt32, size: UInt64, allocSize: UInt64,
        accessTime: FileTime, modifyTime: FileTime, changeTime: FileTime, birthTime: FileTime,
        flags: UInt32 = 0
    ) {
        self.kind = kind
        self.itemID = itemID
        self.parentID = parentID
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.linkCount = linkCount
        self.size = size
        self.allocSize = allocSize
        self.accessTime = accessTime
        self.modifyTime = modifyTime
        self.changeTime = changeTime
        self.birthTime = birthTime
        self.flags = flags
    }

    /// Builds the FSKit-shaped attributes for one file.
    ///
    /// `parent` is `nil` only for the root, which FSKit expects to report
    /// `.parentOfRoot` as its parent rather than itself.
    public init(_ attributes: FileAttributes, parent: NodeID?) {
        let node = attributes.fileID
        self.init(
            kind: FS9ItemKind(attributes.type),
            itemID: FS9ItemIdentifier.itemID(for: node),
            parentID: parent.map(FS9ItemIdentifier.itemID(for:)) ?? FS9ItemIdentifier.parentOfRoot,
            mode: attributes.posixMode,
            uid: attributes.uid,
            gid: attributes.gid,
            // A directory with a zero link count reads as unlinked; 9P servers
            // that do not track nlink report zero.
            linkCount: max(attributes.linkCount, 1),
            size: attributes.size,
            // Servers that do not report block counts leave this zero, which
            // makes `du` claim a full disk is empty; round the size up instead.
            allocSize: attributes.allocatedSize == 0
                ? (attributes.size + 511) / 512 * 512
                : attributes.allocatedSize,
            accessTime: attributes.accessTime,
            modifyTime: attributes.modifyTime,
            changeTime: attributes.changeTime,
            birthTime: attributes.birthTime)
    }

    public var accessTimespec: timespec { fs9Timespec(accessTime) }
    public var modifyTimespec: timespec { fs9Timespec(modifyTime) }
    public var changeTimespec: timespec { fs9Timespec(changeTime) }
    public var birthTimespec: timespec { fs9Timespec(birthTime) }
}

/// Splits an `st_mode` into the permission half `FS9Core` stores.
public func fs9PermissionBits(_ mode: UInt32) -> UInt16 { UInt16(mode & 0o7777) }

/// The file kind an `st_mode` describes.
public func fs9ItemKind(mode: UInt32) -> FS9ItemKind { FS9ItemKind(FileType(posixMode: mode)) }

// MARK: - Set-attribute requests

/// The subset of an `FSItem.SetAttributesRequest` that 9P can act on.
///
/// FSKit hands over a request object that reports which fields the caller set;
/// the shim reads those and fills this in, and the pure code below decides what
/// the VFS call should be. Splitting it this way is not ceremony: FSKit never
/// observes `consumedAttributes` (FB24419894), so deciding what we can honour
/// is entirely our problem and worth testing.
public struct FS9SetAttributes: Sendable, Hashable {
    public var mode: UInt32?
    public var uid: UInt32?
    public var gid: UInt32?
    public var size: UInt64?
    public var accessTime: FileTime?
    public var modifyTime: FileTime?

    public init(
        mode: UInt32? = nil, uid: UInt32? = nil, gid: UInt32? = nil, size: UInt64? = nil,
        accessTime: FileTime? = nil, modifyTime: FileTime? = nil
    ) {
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.size = size
        self.accessTime = accessTime
        self.modifyTime = modifyTime
    }

    public var isEmpty: Bool {
        mode == nil && uid == nil && gid == nil && size == nil
            && accessTime == nil && modifyTime == nil
    }

    /// The arguments for `NineVFS.setAttributes`.
    ///
    /// `restrictsOwnershipChanges` is advertised but FSKit does not enforce it
    /// (FB24419911), so an ownership change by a non-root caller has to be
    /// refused here. `isPrivileged` is what the shim knows about the caller —
    /// which, before macOS 27's `FSContext`, is nothing, so it passes `false`.
    public func validated(readOnly: Bool, isPrivileged: Bool) throws -> FS9SetAttributes {
        if readOnly { throw FSError(EROFS, "volume mounted read-only") }
        if !isPrivileged && (uid != nil || gid != nil) {
            throw FSError(EPERM, "changing ownership needs privilege")
        }
        return self
    }
}

// MARK: - Open modes

/// A mirror of `FSVolume.OpenModes`.
///
/// UNCONFIRMED: whether FSKit's set has members beyond read and write. The shim
/// only reads `.read` and `.write`, which are the two the sample code uses;
/// anything else it cannot see and this type carries so the pure translation
/// can still express it.
public struct FS9OpenModes: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read = FS9OpenModes(rawValue: 1 << 0)
    public static let write = FS9OpenModes(rawValue: 1 << 1)
    public static let append = FS9OpenModes(rawValue: 1 << 2)
    public static let truncate = FS9OpenModes(rawValue: 1 << 3)
}

/// Translates an FSKit open into the flags the 9P client wants.
///
/// A mode with neither read nor write set means read: FSKit opens a vnode for
/// metadata with an empty mode set and a 9P server has no equivalent of
/// `O_PATH`, so asking for read is the only thing that works.
public func ninePOpenFlags(
    for modes: FS9OpenModes, isDirectory: Bool, readOnly: Bool
) throws -> OpenFlags {
    if readOnly && modes.contains(.write) {
        throw FSError(EROFS, "volume mounted read-only")
    }
    if isDirectory && modes.contains(.write) {
        throw FSError.isDirectory
    }
    var flags = OpenFlags()
    if modes.contains(.write) { flags.insert(.write) }
    if modes.contains(.read) || !modes.contains(.write) { flags.insert(.read) }
    if modes.contains(.append) { flags.insert(.append) }
    if modes.contains(.truncate) && !isDirectory { flags.insert(.truncate) }
    if isDirectory { flags.insert(.directory) }
    return flags
}
