import Testing
import Foundation
import FS9NFS
import FS9Core

/// `ftype3` values, which are NFS's own numbering rather than POSIX's.
private let ftRegular: UInt32 = 1
private let ftDirectory: UInt32 = 2
private let ftLink: UInt32 = 5

@Suite("MOUNT protocol")
struct MountProtocolTests {
    @Test("MNT returns the root handle and the flavors we accept")
    func mountRoot() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let fresh = try bridge.connect()
        let mounted = try await fresh.mountRoot()
        #expect(mounted.status == 0)
        #expect(mounted.handle.count == NFSFileHandle.encodedSize)
        #expect(mounted.flavors == [1, 0])  // AUTH_SYS then AUTH_NONE

        // The handle really is the root: its fileid is the VFS root node.
        let attributes = try await fresh.getAttributes(mounted.handle)
        #expect(attributes.status == 0)
        #expect(attributes.attributes?.fileID == NineVFS.rootNode)
        #expect(attributes.attributes?.type == ftDirectory)
    }

    @Test("MNT of an unexported path is refused")
    func mountWrongPath() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let mounted = try await bridge.client.mountRoot(path: "/somewhere/else")
        #expect(mounted.status == 2)  // MNT3ERR_NOENT
    }

    @Test("DUMP lists mounts until they are unmounted, and EXPORT names the tree")
    func dumpAndUnmount() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let client = bridge.client
        #expect(try await client.exports() == ["/"])

        // `start` already mounted once on this connection.
        let dumped = try await client.mountDump()
        #expect(dumped.count == 1)
        #expect(dumped.first?.directory == "/")
        #expect(dumped.first?.host == "fs9kit-test")

        try await client.unmount()
        let afterUnmount = try await client.mountDump()
        #expect(afterUnmount.isEmpty)
    }

    @Test("a trailing slash on the export path still mounts")
    func trailingSlash() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let mounted = try await bridge.client.mountRoot(path: "//")
        #expect(mounted.status == 0)
    }
}

@Suite("NFS attributes and lookup")
struct AttributeTests {
    @Test("GETATTR reports the file's real size, mode and type")
    func getattr() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/hello.txt", text: "hello world", mode: 0o640)
        try bridge.fileSystem.addDirectory("/sub", mode: 0o750)
        let client = bridge.client

        let file = try await client.lookup(bridge.root, "hello.txt")
        #expect(file.status == 0)
        let attributes = try #require(file.attributes)
        #expect(attributes.type == ftRegular)
        #expect(attributes.mode == 0o640)
        #expect(attributes.size == 11)
        // `used` must be non-zero for a non-empty file, or `du` reports zero.
        #expect(attributes.used >= 11)
        #expect(attributes.linkCount >= 1)

        let directory = try await client.lookup(bridge.root, "sub")
        #expect(directory.attributes?.type == ftDirectory)
        #expect(directory.attributes?.mode == 0o750)

        // Both live on one filesystem, which is what FSF_HOMOGENEOUS promises.
        #expect(attributes.fsid == directory.attributes?.fsid)
        #expect(attributes.fileID != directory.attributes?.fileID)
    }

    @Test("a repeated LOOKUP returns the same handle and the same fileid")
    func stableIdentity() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/a", text: "a")

        let first = try await bridge.client.lookup(bridge.root, "a")
        let second = try await bridge.client.lookup(bridge.root, "a")
        #expect(first.handle == second.handle)
        #expect(first.attributes?.fileID == second.attributes?.fileID)
    }

    @Test("SETATTR changes the mode, truncates, and sets timestamps")
    func setattr() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/data", text: "0123456789", mode: 0o644)
        let client = bridge.client
        let file = try #require(try await client.lookup(bridge.root, "data").handle)

        let chmod = try await client.setAttributes(file, TestSetAttributes(mode: 0o600))
        #expect(chmod.status == 0)
        #expect(chmod.after?.mode == 0o600)

        let truncate = try await client.setAttributes(file, TestSetAttributes(size: 4))
        #expect(truncate.status == 0)
        #expect(truncate.after?.size == 4)
        let contents = try await client.read(file, offset: 0, count: 100)
        #expect(contents.data == Array("0123".utf8))

        let stamp = TestTime(seconds: 1_600_000_000, nanoseconds: 123_456_789)
        let utimes = try await client.setAttributes(
            file, TestSetAttributes(accessTime: .some(stamp), modifyTime: .some(stamp)))
        #expect(utimes.status == 0)
        #expect(utimes.after?.accessTime == stamp)
        #expect(utimes.after?.modifyTime == stamp)

        // An empty sattr3 is legal and must not fail.
        let empty = try await client.setAttributes(file, TestSetAttributes())
        #expect(empty.status == 0)
    }

    @Test("a SETATTR guard that does not match the ctime gives NFS3ERR_NOT_SYNC")
    func setattrGuard() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/guarded", text: "x")
        let client = bridge.client
        let file = try #require(try await client.lookup(bridge.root, "guarded").handle)
        let current = try #require(try await client.getAttributes(file).attributes)

        let matching = try await client.setAttributes(
            file, TestSetAttributes(mode: 0o600), guardTime: current.changeTime)
        #expect(matching.status == 0)

        let stale = TestTime(seconds: current.changeTime.seconds &- 1, nanoseconds: 0)
        let mismatched = try await client.setAttributes(
            file, TestSetAttributes(mode: 0o444), guardTime: stale)
        #expect(mismatched.status == NFSStatus.notSync.rawValue)

        // And nothing changed.
        let unchanged = try await client.getAttributes(file)
        #expect(unchanged.attributes?.mode == 0o600)
    }

    @Test("ACCESS reports only the bits that were asked about")
    func access() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/readable", text: "x", mode: 0o444)
        let client = bridge.client
        let file = try #require(try await client.lookup(bridge.root, "readable").handle)

        let all = NFSAccess.all.rawValue
        let granted = try await client.access(file, all)
        #expect(granted.status == 0)
        #expect(granted.granted & NFSAccess.read.rawValue != 0)

        // Asking about a single bit must never return more than that bit.
        let narrow = try await client.access(file, NFSAccess.read.rawValue)
        #expect(narrow.granted == NFSAccess.read.rawValue)

        // A directory grants LOOKUP rather than EXECUTE.
        let directory = try await client.access(bridge.root, all)
        #expect(directory.granted & NFSAccess.lookup.rawValue != 0)
        #expect(directory.granted & NFSAccess.execute.rawValue == 0)
    }

    @Test("an unprivileged caller gets nothing on a root-owned private file")
    func accessRespectsCredentials() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/rootonly", text: "x", mode: 0o600)

        let stranger = try bridge.connect(credentials: AuthSysCredentials(
            stamp: 1, machineName: "other", uid: 4242, gid: 4242, groups: [4242]))
        let mounted = try await stranger.mountRoot()
        let file = try #require(try await stranger.lookup(mounted.handle, "rootonly").handle)
        let granted = try await stranger.access(file, NFSAccess.all.rawValue)
        // MemoryFileSystem owns everything as uid 0 with mode 0600, so uid 4242
        // falls into the "other" class and gets nothing.
        #expect(granted.granted & NFSAccess.read.rawValue == 0)
        #expect(granted.granted & NFSAccess.modify.rawValue == 0)
    }
}

@Suite("NFS data operations")
struct DataTests {
    @Test("a file created, written and read back yields exactly the bytes written")
    func writeAndReadBack() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let client = bridge.client

        let created = try await client.create(
            bridge.root, "new.bin", how: 0, attributes: TestSetAttributes(mode: 0o644))
        #expect(created.status == 0)
        let file = try #require(created.handle)
        #expect(created.attributes?.type == ftRegular)
        #expect(created.attributes?.size == 0)

        let payload = (0..<4096).map { UInt8($0 & 0xFF) }
        let written = try await client.write(file, offset: 0, data: payload, stable: 2)
        #expect(written.status == 0)
        #expect(written.count == UInt32(payload.count))
        #expect(written.committed == 2)  // FILE_SYNC, because we asked for it
        #expect(written.verifier.count == 8)

        let readBack = try await client.read(file, offset: 0, count: 4096)
        #expect(readBack.status == 0)
        #expect(readBack.data == payload)
        #expect(readBack.eof)

        // A partial read in the middle of the file is not EOF.
        let middle = try await client.read(file, offset: 100, count: 16)
        #expect(middle.data == Array(payload[100..<116]))
        #expect(!middle.eof)

        // A read past the end returns nothing and is EOF.
        let past = try await client.read(file, offset: 8192, count: 16)
        #expect(past.data.isEmpty)
        #expect(past.eof)
    }

    @Test("an unstable write reports UNSTABLE and COMMIT returns the same verifier")
    func unstableWriteThenCommit() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let client = bridge.client
        let file = try #require(try await client.create(bridge.root, "buffered").handle)

        let written = try await client.write(file, offset: 0, data: Array("abc".utf8), stable: 0)
        #expect(written.status == 0)
        #expect(written.committed == 0)

        let committed = try await client.commit(file)
        #expect(committed.status == 0)
        // The verifier is constant for the server's lifetime; a change is how a
        // client learns it must replay its unstable writes.
        #expect(committed.verifier == written.verifier)
    }

    @Test("a sparse write extends the file and the gap reads as zeros")
    func sparseWrite() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let client = bridge.client
        let file = try #require(try await client.create(bridge.root, "sparse").handle)

        _ = try await client.write(file, offset: 8, data: Array("tail".utf8))
        let attributes = try await client.getAttributes(file)
        #expect(attributes.attributes?.size == 12)
        let all = try await client.read(file, offset: 0, count: 32)
        #expect(all.data == [0, 0, 0, 0, 0, 0, 0, 0] + Array("tail".utf8))
    }
}

@Suite("NFS namespace operations")
struct NamespaceTests {
    @Test("MKDIR, RENAME, REMOVE and RMDIR do what they say")
    func namespaceLifecycle() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let client = bridge.client
        let root = bridge.root

        let made = try await client.mkdir(root, "dir", attributes: TestSetAttributes(mode: 0o700))
        #expect(made.status == 0)
        #expect(made.attributes?.type == ftDirectory)
        #expect(made.attributes?.mode == 0o700)
        let directory = try #require(made.handle)

        let file = try #require(try await client.create(directory, "inner").handle)
        _ = try await client.write(file, offset: 0, data: Array("payload".utf8))

        let renamed = try await client.rename(directory, "inner", root, "moved")
        #expect(renamed == 0)
        let gone = try await client.lookup(directory, "inner")
        #expect(gone.status == NFSStatus.noent.rawValue)
        let moved = try #require(try await client.lookup(root, "moved").handle)
        let contents = try await client.read(moved, offset: 0, count: 64)
        #expect(contents.data == Array("payload".utf8))

        let removedDirectory = try await client.rmdir(root, "dir")
        #expect(removedDirectory == 0)
        let removedFile = try await client.remove(root, "moved")
        #expect(removedFile == 0)
        let afterRemoval = try await client.lookup(root, "moved")
        #expect(afterRemoval.status == NFSStatus.noent.rawValue)
        #expect(bridge.fileSystem.exists("/moved") == false)
    }

    @Test("SYMLINK and READLINK round-trip a target")
    func symlinks() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/target.txt", text: "linked")
        let client = bridge.client

        let made = try await client.symlink(bridge.root, "link", target: "target.txt")
        #expect(made.status == 0)
        #expect(made.attributes?.type == ftLink)
        let link = try #require(made.handle)

        let target = try await client.readlink(link)
        #expect(target.status == 0)
        #expect(target.target == "target.txt")

        // READLINK on a regular file is an error, not an empty string.
        let file = try #require(try await client.lookup(bridge.root, "target.txt").handle)
        let refused = try await client.readlink(file)
        #expect(refused.status == NFSStatus.inval.rawValue)
    }

    @Test("LINK creates a second name for the same file")
    func hardLinks() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/original", text: "shared")
        let client = bridge.client

        let file = try #require(try await client.lookup(bridge.root, "original").handle)
        let status = try await client.link(file, to: bridge.root, name: "second")
        #expect(status == 0)
        let second = try #require(try await client.lookup(bridge.root, "second").handle)
        let contents = try await client.read(second, offset: 0, count: 64)
        #expect(contents.data == Array("shared".utf8))
    }

    @Test("MKNOD is declined with NFS3ERR_NOTSUPP rather than failing obscurely")
    func mknodIsNotSupported() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let made = try await bridge.client.mknod(bridge.root, "device")
        #expect(made.status == NFSStatus.notsupp.rawValue)
    }

    @Test("CREATE honours UNCHECKED, GUARDED and EXCLUSIVE")
    func createModes() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let client = bridge.client
        let root = bridge.root

        let first = try await client.create(root, "once", how: 1)  // GUARDED
        #expect(first.status == 0)
        let again = try await client.create(root, "once", how: 1)
        #expect(again.status == NFSStatus.exist.rawValue)

        // UNCHECKED over an existing file succeeds and can truncate it, which
        // is how a client implements O_CREAT|O_TRUNC.
        let file = try #require(first.handle)
        _ = try await client.write(file, offset: 0, data: Array("content".utf8))
        let unchecked = try await client.create(
            root, "once", how: 0, attributes: TestSetAttributes(size: 0))
        #expect(unchecked.status == 0)
        #expect(unchecked.attributes?.size == 0)

        // EXCLUSIVE: the first call creates; a retransmit with the same verifier
        // is recognised as a duplicate; a different verifier is EEXIST.
        let verifier = [UInt8](repeating: 0xA5, count: 8)
        let exclusive = try await client.create(root, "excl", how: 2, verifier: verifier)
        #expect(exclusive.status == 0)
        let retry = try await client.create(root, "excl", how: 2, verifier: verifier)
        #expect(retry.status == 0)
        #expect(retry.handle == exclusive.handle)
        let other = try await client.create(
            root, "excl", how: 2, verifier: [UInt8](repeating: 0x5A, count: 8))
        #expect(other.status == NFSStatus.exist.rawValue)
    }
}

@Suite("NFS volume information")
struct VolumeTests {
    @Test("FSSTAT reports a non-empty volume")
    func fsstat() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/a", text: "x")

        let stats = try await bridge.client.fsstat(bridge.root)
        #expect(stats.status == 0)
        #expect(stats.totalBytes > 0)
        #expect(stats.freeBytes <= stats.totalBytes)
        #expect(stats.availableBytes <= stats.freeBytes)
        #expect(stats.totalFiles > 0)
        #expect(stats.invariantSeconds == 0)
    }

    @Test("FSINFO advertises power-of-two transfer sizes and the right properties")
    func fsinfo() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }

        let reply = try await bridge.client.fsinfo(bridge.root)
        #expect(reply.status == 0)
        let info = try #require(reply.info)

        let size = info.readPreferred
        #expect(size == info.writePreferred)
        #expect(size == UInt32(bridge.bridge.transferSize))
        #expect(size > 0 && size & (size - 1) == 0, "\(size) is not a power of two")
        #expect(size <= 64 * 1024)
        #expect(info.readMaximum >= size)
        #expect(info.writeMaximum >= size)
        #expect(info.readMultiple == 512)
        #expect(info.writeMultiple == 512)
        #expect(info.directoryPreferred > 0)
        #expect(info.maximumFileSize > 1 << 40)
        #expect(info.timeDelta == TestTime(seconds: 0, nanoseconds: 1))

        // 9P2000.L is negotiated by default, so links and symlinks are real.
        #expect(info.properties & NFSConstants.fsfHomogeneous != 0)
        #expect(info.properties & NFSConstants.fsfCanSetTime != 0)
        #expect(info.properties & NFSConstants.fsfLink != 0)
        #expect(info.properties & NFSConstants.fsfSymlink != 0)
    }

    @Test("PATHCONF reports the name limit and case behaviour")
    func pathconf() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }

        let reply = try await bridge.client.pathconf(bridge.root)
        #expect(reply.status == 0)
        #expect(reply.nameMaximum == 255)
        #expect(reply.linkMaximum > 1)
        #expect(reply.noTruncate)
        #expect(reply.chownRestricted)
        #expect(!reply.caseInsensitive)
        #expect(reply.casePreserving)
    }
}
