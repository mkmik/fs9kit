import Testing
import Foundation
import FS9NFS
import FS9Core

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite("Error mapping")
struct ErrorMappingTests {
    @Test("errno values become nfsstat3 values, not themselves")
    func errnoTranslation() {
        // The interesting ones are where NFS and errno disagree.
        #expect(NFSStatus(errno: ENAMETOOLONG) == .nametoolong)
        #expect(NFSStatus(FSError.nameTooLong).rawValue == 63)
        #expect(NFSStatus(errno: ENOTSUP) == .notsupp)
        #expect(NFSStatus(errno: ENOSYS) == .notsupp)
        #expect(NFSStatus(FSError.staleHandle) == .stale)

        // And the ones that happen to line up must still be explicit.
        #expect(NFSStatus(FSError.notFound) == .noent)
        #expect(NFSStatus(FSError.notDirectory) == .notdir)
        #expect(NFSStatus(FSError.isDirectory) == .isdir)
        #expect(NFSStatus(FSError.exists) == .exist)
        #expect(NFSStatus(FSError.notEmpty) == .notempty)
        #expect(NFSStatus(FSError.permissionDenied) == .acces)
        #expect(NFSStatus(FSError.invalidArgument) == .inval)
        #expect(NFSStatus(FSError(EROFS)) == .rofs)

        // Anything unrecognised must be a server fault, never a leaked errno.
        #expect(NFSStatus(FSError(9999)) == .serverfault)
    }

    @Test("looking up a name that is not there is NFS3ERR_NOENT")
    func missingName() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let absent = try await bridge.client.lookup(bridge.root, "absent")
        #expect(absent.status == NFSStatus.noent.rawValue)
    }

    @Test("removing a non-empty directory is NFS3ERR_NOTEMPTY")
    func rmdirNotEmpty() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/full/inside", text: "x")

        let status = try await bridge.client.rmdir(bridge.root, "full")
        #expect(status == NFSStatus.notempty.rawValue)
        // The directory is still there afterwards.
        let survived = try await bridge.client.lookup(bridge.root, "full")
        #expect(survived.status == 0)
    }

    @Test("a GUARDED create over an existing name is NFS3ERR_EXIST")
    func guardedCreateExists() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/taken", text: "x")

        let result = try await bridge.client.create(bridge.root, "taken", how: 1)
        #expect(result.status == NFSStatus.exist.rawValue)
    }

    @Test("a name longer than 255 bytes is NFS3ERR_NAMETOOLONG")
    func nameTooLong() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let long = String(repeating: "z", count: 300)

        let lookedUp = try await bridge.client.lookup(bridge.root, long)
        #expect(lookedUp.status == NFSStatus.nametoolong.rawValue)
        let created = try await bridge.client.create(bridge.root, long)
        #expect(created.status == NFSStatus.nametoolong.rawValue)
    }

    @Test("a read-only export refuses every modifying procedure with NFS3ERR_ROFS")
    func readOnlyExport() async throws {
        let bridge = try await TestBridge.start(readOnly: true)
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/data", text: "readable")
        try bridge.fileSystem.addDirectory("/dir")
        let client = bridge.client
        let root = bridge.root
        let file = try #require(try await client.lookup(root, "data").handle)

        // Reads still work.
        let contents = try await client.read(file, offset: 0, count: 64)
        #expect(contents.data == Array("readable".utf8))
        let attributes = try await client.getAttributes(file)
        #expect(attributes.status == 0)

        let rofs = NFSStatus.rofs.rawValue
        let written = try await client.write(file, offset: 0, data: [1, 2, 3])
        #expect(written.status == rofs)
        let chmod = try await client.setAttributes(file, TestSetAttributes(mode: 0o600))
        #expect(chmod.status == rofs)
        let created = try await client.create(root, "nope")
        #expect(created.status == rofs)
        let made = try await client.mkdir(root, "nope")
        #expect(made.status == rofs)
        let linked = try await client.symlink(root, "nope", target: "data")
        #expect(linked.status == rofs)
        let removed = try await client.remove(root, "data")
        #expect(removed == rofs)
        let removedDirectory = try await client.rmdir(root, "dir")
        #expect(removedDirectory == rofs)
        let renamed = try await client.rename(root, "data", root, "other")
        #expect(renamed == rofs)
        let hardLinked = try await client.link(file, to: root, name: "other")
        #expect(hardLinked == rofs)

        // Nothing actually changed.
        let stillThere = try await client.lookup(root, "data")
        #expect(stillThere.status == 0)
        let neverMade = try await client.lookup(root, "nope")
        #expect(neverMade.status == NFSStatus.noent.rawValue)
    }

    @Test("ACCESS on a read-only export withholds the write bits")
    func readOnlyAccessBits() async throws {
        let bridge = try await TestBridge.start(readOnly: true)
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/data", text: "x", mode: 0o666)

        let file = try #require(try await bridge.client.lookup(bridge.root, "data").handle)
        let granted = try await bridge.client.access(file, NFSAccess.all.rawValue)
        #expect(granted.granted & NFSAccess.read.rawValue != 0)
        #expect(granted.granted & NFSAccess.modify.rawValue == 0)
        #expect(granted.granted & NFSAccess.extend.rawValue == 0)
        #expect(granted.granted & NFSAccess.delete.rawValue == 0)
    }

    @Test("reading a directory as a file is NFS3ERR_ISDIR")
    func readDirectoryAsFile() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let attempt = try await bridge.client.read(bridge.root, offset: 0, count: 16)
        #expect(attempt.status == NFSStatus.isdir.rawValue)
    }

    @Test("an empty name is rejected rather than resolving to the directory")
    func emptyName() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let empty = try await bridge.client.lookup(bridge.root, "")
        #expect(empty.status == NFSStatus.inval.rawValue)
    }

    @Test("a failed modifying call still returns wcc data")
    func failuresCarryWccData() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/full/inside", text: "x")

        // RMDIR of a non-empty directory: the reply must still parse as
        // status + wcc_data, or the client cannot resynchronise.
        let reply = try await bridge.client.connection.call(
            program: NFSConstants.program, version: 3,
            procedure: NFSConstants.procedureRmdir,
            arguments: NFSTestClient.directoryOperation(bridge.root, "full"))
        var d = reply.decoder
        #expect(try d.uint32() == NFSStatus.notempty.rawValue)
        let wcc = try TestAttributes.skipWcc(&d)
        #expect(wcc.after != nil, "the directory's attributes should follow the failure")
        try d.expectEnd()
    }
}

@Suite("Mount options")
struct MountOptionTests {
    @Test("the option list names the port twice and disables locking")
    func options() {
        let options = NFSMountCommand.options(port: 12049, transferSize: 65536, readOnly: false)
        #expect(options.contains("vers=3"))
        #expect(options.contains("tcp"))
        #expect(options.contains("port=12049"))
        // Both programs live on one port and there is no rpcbind to ask.
        #expect(options.contains("mountport=12049"))
        #expect(options.contains("soft"))
        // We implement no NLM, so the client must not look for one.
        #expect(options.contains("nolocks"))
        #expect(options.contains("locallocks"))
        #expect(options.contains("rsize=65536"))
        #expect(options.contains("wsize=65536"))
        #expect(options.contains("nobrowse"))
        #expect(options.contains("noresvport"))
        #expect(!options.contains("rdonly"))
    }

    @Test("a read-only export adds rdonly")
    func readOnlyOption() {
        let options = NFSMountCommand.options(port: 1, transferSize: 4096, readOnly: true)
        #expect(options.contains("rdonly"))
    }

    @Test("the argument list ends with the export and the mount point")
    func arguments() {
        let arguments = NFSMountCommand.arguments(
            host: "127.0.0.1", port: 2049, exportPath: "/", mountPoint: "/Volumes/nine",
            transferSize: 32768, readOnly: false)
        #expect(arguments.first == "-o")
        #expect(arguments[arguments.count - 2] == "127.0.0.1:/")
        #expect(arguments.last == "/Volumes/nine")
        #expect(arguments[1].contains("port=2049"))

        let full = NFSMountCommand.commandLine(
            host: "127.0.0.1", port: 2049, exportPath: "/", mountPoint: "/m",
            transferSize: 32768, readOnly: false)
        #expect(full.first == "/sbin/mount_nfs")
    }

    @Test("a bridge reports the port it bound and builds matching arguments")
    func bridgeArguments() async throws {
        let harness = try await TestBridge.start()
        defer { harness.tearDown() }
        let port = try #require(harness.bridge.port)
        #expect(port != 0)
        let arguments = harness.bridge.mountArguments(mountPoint: "/tmp/mnt", extraOptions: ["intr"])
        #expect(arguments[1].contains("port=\(port)"))
        #expect(arguments[1].contains("mountport=\(port)"))
        #expect(arguments[1].contains("rsize=\(harness.bridge.transferSize)"))
        #expect(arguments[1].contains("intr"))
        #expect(arguments.last == "/tmp/mnt")
    }

    @Test("transfer sizes are rounded down to a power of two and capped")
    func transferSizes() {
        #expect(NFSExport.preferredTransferSize(preferred: 100_000, cap: 65536) == 65536)
        #expect(NFSExport.preferredTransferSize(preferred: 65535, cap: 65536) == 32768)
        #expect(NFSExport.preferredTransferSize(preferred: 8192, cap: 65536) == 8192)
        #expect(NFSExport.preferredTransferSize(preferred: 8191, cap: 65536) == 4096)
        // Never below a page, however small the negotiated 9P msize.
        #expect(NFSExport.preferredTransferSize(preferred: 100, cap: 65536) == 4096)
    }

    @Test("stopping the bridge twice is harmless")
    func doubleStop() async throws {
        let harness = try await TestBridge.start()
        defer { harness.tearDown() }
        harness.bridge.stop()
        harness.bridge.stop()
        #expect(harness.bridge.port == nil)
    }
}

@Suite("Resource hygiene")
struct ResourceTests {
    /// The lowest free descriptor, used as a portable proxy for "how many are
    /// open". `/proc` is not available on Darwin and counting threads portably
    /// is worse, so this is what we have.
    private func lowestFreeDescriptor() -> Int32 {
        let probe = dup(0)
        guard probe >= 0 else { return -1 }
        close(probe)
        return probe
    }

    @Test("starting and stopping bridges does not leak descriptors")
    func noDescriptorLeak() async throws {
        // One warm-up cycle first: the first bridge allocates thread-local and
        // runtime descriptors that are not a leak.
        let warmUp = try await TestBridge.start()
        warmUp.tearDown()
        let before = lowestFreeDescriptor()

        for _ in 0..<8 {
            let bridge = try await TestBridge.start()
            try bridge.fileSystem.addFile("/f", text: "x")
            let file = try #require(try await bridge.client.lookup(bridge.root, "f").handle)
            let contents = try await bridge.client.read(file, offset: 0, count: 8)
            #expect(contents.data == Array("x".utf8))
            _ = try bridge.connect()
            bridge.tearDown()
        }

        let after = lowestFreeDescriptor()
        // Sockets are closed asynchronously by the peer, so allow a little
        // slack; a genuine leak would be eight or more per cycle.
        #expect(after - before < 8, "descriptors grew from \(before) to \(after)")
    }
}
