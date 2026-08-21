import Testing
import Foundation
import NineP
import NinePClient
import FS9Core
@testable import FS9KitAdapter

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite("File-kind translation")
struct ItemKindTests {

    @Test("every file type has a distinct FSKit kind", arguments: [
        (FileType.regular, FS9ItemKind.file),
        (.directory, .directory),
        (.symlink, .symlink),
        (.fifo, .fifo),
        (.socket, .socket),
        (.blockDevice, .blockDevice),
        (.characterDevice, .charDevice),
    ])
    func mapping(type: FileType, kind: FS9ItemKind) {
        #expect(FS9ItemKind(type) == kind)
        #expect(kind.fileType == type)
    }

    @Test("the mapping is total and injective")
    func totalAndInjective() {
        let kinds = Set([FileType.regular, .directory, .symlink, .fifo, .socket,
                         .blockDevice, .characterDevice].map(FS9ItemKind.init))
        #expect(kinds.count == 7)
        #expect(kinds.contains(.unknown) == false)
    }

    /// 9P cannot say "I don't know what this is", so nothing maps back out of
    /// `.unknown` — a caller has to decide for itself.
    @Test("unknown has no file type")
    func unknownHasNoFileType() {
        #expect(FS9ItemKind.unknown.fileType == nil)
    }

    @Test("the kind can be read straight out of an st_mode")
    func fromMode() {
        #expect(fs9ItemKind(mode: 0o040755) == .directory)
        #expect(fs9ItemKind(mode: 0o100644) == .file)
        #expect(fs9ItemKind(mode: 0o120777) == .symlink)
        #expect(fs9ItemKind(mode: 0o010644) == .fifo)
        #expect(fs9ItemKind(mode: 0o140755) == .socket)
        #expect(fs9ItemKind(mode: 0o060660) == .blockDevice)
        #expect(fs9ItemKind(mode: 0o020666) == .charDevice)
    }
}

@Suite("Item identifiers")
struct ItemIdentifierTests {

    /// `NineVFS` numbers its root 1, which is almost certainly FSKit's
    /// `.parentOfRoot`. Handing node numbers over unshifted would make the root
    /// collide with the identifier the kernel uses for "above the mount point".
    @Test("the VFS root lands on FSKit's root identifier")
    func rootMapsToRoot() {
        #expect(FS9ItemIdentifier.itemID(for: NineVFS.rootNode) == FS9ItemIdentifier.rootDirectory)
        #expect(FS9ItemIdentifier.node(for: FS9ItemIdentifier.rootDirectory) == NineVFS.rootNode)
    }

    @Test("no ordinary node lands on a reserved identifier")
    func reservedIdentifiersAreClear() {
        for node in NodeID(2)...200 {
            let id = FS9ItemIdentifier.itemID(for: node)
            #expect(id != FS9ItemIdentifier.invalid)
            #expect(id != FS9ItemIdentifier.parentOfRoot)
            #expect(id != FS9ItemIdentifier.rootDirectory)
            #expect(FS9ItemIdentifier.node(for: id) == node)
        }
    }

    @Test("identifiers we could never have issued do not map back")
    func rejectsForeignIdentifiers() {
        #expect(FS9ItemIdentifier.node(for: 0) == nil)
        #expect(FS9ItemIdentifier.node(for: 1) == nil)
        #expect(FS9ItemIdentifier.node(for: 3) == nil)
        #expect(FS9ItemIdentifier.node(for: 4) == 2)
    }
}

@Suite("Timestamp translation")
struct TimeTests {

    @Test("the epoch is zero in both directions")
    func epoch() {
        let ts = fs9Timespec(.epoch)
        #expect(ts.tv_sec == 0)
        #expect(ts.tv_nsec == 0)
        #expect(fs9FileTime(ts) == .epoch)
    }

    @Test("an ordinary time round-trips exactly")
    func roundTrip() {
        let time = FileTime(seconds: 1_755_000_000, nanoseconds: 123_456_789)
        let ts = fs9Timespec(time)
        #expect(ts.tv_sec == 1_755_000_000)
        #expect(ts.tv_nsec == 123_456_789)
        #expect(fs9FileTime(ts) == time)
    }

    /// `FileTime.seconds` is unsigned and `tv_sec` is signed. A server reporting
    /// nonsense must not wrap the timestamp into the past, where `ls` prints
    /// garbage and Finder sorts it before the epoch.
    @Test("an impossibly large time clamps forward, never wrapping negative")
    func clampsRatherThanWraps() {
        let ts = fs9Timespec(FileTime(seconds: UInt64.max, nanoseconds: 999_999_999))
        #expect(ts.tv_sec == Int.max)
        #expect(ts.tv_sec > 0)
    }

    @Test("the largest representable second is not clamped")
    func largestRepresentable() {
        let ts = fs9Timespec(FileTime(seconds: UInt64(Int.max)))
        #expect(ts.tv_sec == Int.max)
    }

    @Test("nanoseconds are clamped at construction, so a timespec is always valid")
    func nanosecondClamping() {
        #expect(FileTime(seconds: 1, nanoseconds: 4_000_000_000).nanoseconds == 999_999_999)
        #expect(fs9Timespec(FileTime(seconds: 1, nanoseconds: 4_000_000_000)).tv_nsec == 999_999_999)
    }

    /// The other direction has to defend too: FSKit hands over whatever the
    /// caller of `utimes(2)` supplied.
    @Test("a negative or over-large timespec is brought back into range")
    func inboundClamping() {
        #expect(fs9FileTime(timespec(tv_sec: -5, tv_nsec: 0)) == .epoch)
        #expect(fs9FileTime(timespec(tv_sec: 10, tv_nsec: -1)).nanoseconds == 0)
        #expect(fs9FileTime(timespec(tv_sec: 10, tv_nsec: 2_000_000_000)).nanoseconds == 999_999_999)
    }
}

@Suite("Attribute translation")
struct AttributeTests {

    private func attributes(
        type: FileType = .regular, permissions: UInt16 = 0o644,
        linkCount: UInt32 = 1, size: UInt64 = 0, allocatedSize: UInt64 = 0
    ) -> FileAttributes {
        FileAttributes(
            fileID: 42, type: type, permissions: permissions, uid: 501, gid: 20,
            linkCount: linkCount, size: size, allocatedSize: allocatedSize,
            accessTime: FileTime(seconds: 100), modifyTime: FileTime(seconds: 200),
            changeTime: FileTime(seconds: 300), birthTime: FileTime(seconds: 400))
    }

    @Test("the plain case")
    func plain() {
        let a = FS9ItemAttributes(attributes(size: 1234), parent: 7)
        #expect(a.kind == .file)
        #expect(a.itemID == FS9ItemIdentifier.itemID(for: 42))
        #expect(a.parentID == FS9ItemIdentifier.itemID(for: 7))
        #expect(a.mode == 0o100644)
        #expect(a.uid == 501)
        #expect(a.gid == 20)
        #expect(a.size == 1234)
        #expect(a.flags == 0)
        #expect(a.modifyTimespec.tv_sec == 200)
        #expect(a.birthTimespec.tv_sec == 400)
    }

    /// The root has no parent node; FSKit expects `.parentOfRoot` there rather
    /// than the root pointing at itself.
    @Test("the root reports parentOfRoot")
    func rootParent() {
        let a = FS9ItemAttributes(attributes(type: .directory), parent: nil)
        #expect(a.parentID == FS9ItemIdentifier.parentOfRoot)
    }

    @Test("setuid, setgid and sticky survive into the mode", arguments: [
        (UInt16(0o4755), UInt32(0o104755)),
        (0o2755, 0o102755),
        (0o1777, 0o101777),
        (0o7777, 0o107777),
    ])
    func specialBits(permissions: UInt16, mode: UInt32) {
        let a = FS9ItemAttributes(attributes(permissions: permissions), parent: 1)
        #expect(a.mode == mode)
        #expect(fs9PermissionBits(a.mode) == permissions)
    }

    @Test("the type bits and the permission bits do not bleed into each other")
    func modeSplit() {
        for type in [FileType.regular, .directory, .symlink, .fifo, .socket,
                     .blockDevice, .characterDevice] {
            let a = FS9ItemAttributes(attributes(type: type, permissions: 0o7777), parent: 1)
            #expect(fs9PermissionBits(a.mode) == 0o7777)
            #expect(fs9ItemKind(mode: a.mode) == FS9ItemKind(type))
        }
    }

    /// A directory whose link count reads zero looks unlinked to the kernel, and
    /// plenty of 9P servers simply do not track `nlink`.
    @Test("a zero link count is raised to one")
    func linkCountFloor() {
        #expect(FS9ItemAttributes(attributes(linkCount: 0), parent: 1).linkCount == 1)
        #expect(FS9ItemAttributes(attributes(linkCount: 5), parent: 1).linkCount == 5)
    }

    /// Servers that report no block count would otherwise make `du` claim every
    /// file occupies nothing.
    @Test("a missing allocated size is rounded up from the size")
    func allocatedSizeFallback() {
        #expect(FS9ItemAttributes(attributes(size: 0), parent: 1).allocSize == 0)
        #expect(FS9ItemAttributes(attributes(size: 1), parent: 1).allocSize == 512)
        #expect(FS9ItemAttributes(attributes(size: 512), parent: 1).allocSize == 512)
        #expect(FS9ItemAttributes(attributes(size: 513), parent: 1).allocSize == 1024)
        // A reported value is always preferred, even a sparse one below the size.
        #expect(FS9ItemAttributes(attributes(size: 4096, allocatedSize: 512), parent: 1).allocSize == 512)
    }
}

@Suite("Set-attribute requests")
struct SetAttributeTests {

    @Test("an empty request is recognised as a no-op")
    func empty() {
        #expect(FS9SetAttributes().isEmpty)
        #expect(FS9SetAttributes(mode: 0o644).isEmpty == false)
        #expect(FS9SetAttributes(modifyTime: .epoch).isEmpty == false)
    }

    @Test("a read-only volume refuses every change with EROFS")
    func readOnly() {
        #expect(throws: FSError(EROFS, "volume mounted read-only")) {
            try FS9SetAttributes(size: 0).validated(readOnly: true, isPrivileged: false)
        }
    }

    /// FSKit does not act on `restrictsOwnershipChanges` (FB24419911), so a
    /// module that only advertises it lets any user chown any file.
    @Test("an unprivileged chown is refused here, because FSKit will not refuse it")
    func ownershipChange() {
        #expect(throws: FSError(EPERM, "changing ownership needs privilege")) {
            try FS9SetAttributes(uid: 0).validated(readOnly: false, isPrivileged: false)
        }
        #expect(throws: FSError(EPERM, "changing ownership needs privilege")) {
            try FS9SetAttributes(gid: 0).validated(readOnly: false, isPrivileged: false)
        }
        #expect(throws: Never.self) {
            try FS9SetAttributes(uid: 0).validated(readOnly: false, isPrivileged: true)
        }
    }

    @Test("everything else passes through untouched")
    func passThrough() throws {
        let request = FS9SetAttributes(
            mode: 0o100600, size: 99, accessTime: FileTime(seconds: 5), modifyTime: FileTime(seconds: 6))
        let validated = try request.validated(readOnly: false, isPrivileged: false)
        #expect(validated == request)
        #expect(fs9PermissionBits(validated.mode ?? 0) == 0o600)
    }
}

@Suite("Open-mode translation")
struct OpenModeTests {

    @Test("read and write map straight across")
    func plain() throws {
        #expect(try ninePOpenFlags(for: .read, isDirectory: false, readOnly: false) == [.read])
        #expect(try ninePOpenFlags(for: .write, isDirectory: false, readOnly: false) == [.write])
        #expect(try ninePOpenFlags(for: [.read, .write], isDirectory: false, readOnly: false)
                == [.read, .write])
    }

    /// FSKit opens a vnode for metadata with no mode bits at all, and 9P has no
    /// equivalent of `O_PATH`, so asking for read is the only thing that works.
    @Test("an empty mode set means read")
    func emptyMeansRead() throws {
        #expect(try ninePOpenFlags(for: [], isDirectory: false, readOnly: false) == [.read])
    }

    @Test("append and truncate come along when asked for")
    func extras() throws {
        let flags = try ninePOpenFlags(
            for: [.write, .append, .truncate], isDirectory: false, readOnly: false)
        #expect(flags.contains(.append))
        #expect(flags.contains(.truncate))
        #expect(flags.contains(.write))
    }

    @Test("a directory is opened as a directory and never truncated")
    func directory() throws {
        let flags = try ninePOpenFlags(for: [.read, .truncate], isDirectory: true, readOnly: false)
        #expect(flags.contains(.directory))
        #expect(flags.contains(.read))
        #expect(flags.contains(.truncate) == false)
    }

    @Test("opening a directory for writing is EISDIR")
    func directoryWrite() {
        #expect(throws: FSError.isDirectory) {
            try ninePOpenFlags(for: .write, isDirectory: true, readOnly: false)
        }
    }

    @Test("a write to a read-only volume is EROFS, not EPERM")
    func readOnlyVolume() throws {
        // EROFS makes the kernel stop asking; EPERM makes it retry as root.
        #expect(throws: FSError(EROFS, "volume mounted read-only")) {
            try ninePOpenFlags(for: .write, isDirectory: false, readOnly: true)
        }
        #expect(try ninePOpenFlags(for: .read, isDirectory: false, readOnly: true) == [.read])
    }
}
