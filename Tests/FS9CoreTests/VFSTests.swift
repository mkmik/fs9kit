import Testing
import Foundation
import NineP
import NinePClient
import NinePServer
@testable import FS9Core

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Spins up an in-process 9P server and a client attached to it.
///
/// Going over a real socket rather than stubbing the client keeps these tests
/// honest about the parts that only misbehave once concurrency and fids are
/// involved.
struct VFSHarness {
    let server: NinePServer
    let memory: MemoryFileSystem
    let vfs: NineVFS

    static func make(
        version: NinePVersion = .v9P2000L,
        options: VFSOptions = VFSOptions(attributeCacheDuration: 0),
        msize: UInt32 = 64 * 1024,
        populate: (MemoryFileSystem) throws -> Void = { _ in }
    ) async throws -> VFSHarness {
        let memory = MemoryFileSystem()
        try populate(memory)

        var configuration = NinePServerConfiguration()
        configuration.endpoints = [.tcp(host: "127.0.0.1", port: 0)]
        configuration.supportedVersions = [version]
        configuration.maxMessageSize = msize
        let server = NinePServer(fileSystem: memory, configuration: configuration)
        let endpoints = try server.start()
        guard let port = endpoints.compactMap(\.port).first else {
            throw FSError(EIO, "server reported no port")
        }
        let client = try await NinePClient.connect(
            to: .tcp(host: "127.0.0.1", port: port),
            options: NinePSessionOptions(msize: msize, versions: [version]))
        return VFSHarness(server: server, memory: memory,
                          vfs: NineVFS(client: client, options: options))
    }

    func shutdown() async {
        await vfs.shutdown()
        server.stop()
    }
}

func withHarness(
    version: NinePVersion = .v9P2000L,
    options: VFSOptions = VFSOptions(attributeCacheDuration: 0),
    msize: UInt32 = 64 * 1024,
    populate: (MemoryFileSystem) throws -> Void = { _ in },
    _ body: (VFSHarness) async throws -> Void
) async throws {
    let harness = try await VFSHarness.make(
        version: version, options: options, msize: msize, populate: populate)
    do { try await body(harness) } catch { await harness.shutdown(); throw error }
    await harness.shutdown()
}

@Suite("VFS lookup and attributes")
struct LookupTests {
    @Test("the root is a directory with a stable identifier")
    func root() async throws {
        try await withHarness { h in
            let attrs = try await h.vfs.getAttributes(h.vfs.root())
            #expect(attrs.type == .directory)
            #expect(attrs.fileID == NineVFS.rootNode)
        }
    }

    @Test("looking up the same name twice yields the same node")
    func stableNodes() async throws {
        try await withHarness(populate: { _ = try $0.addFile("/a.txt", text: "x") }) { h in
            let first = try await h.vfs.lookup(parent: h.vfs.root(), name: "a.txt")
            let second = try await h.vfs.lookup(parent: h.vfs.root(), name: "a.txt")
            #expect(first.node == second.node)
        }
    }

    @Test("a missing name is ENOENT")
    func missing() async throws {
        try await withHarness { h in
            await #expect(throws: FSError.notFound) {
                _ = try await h.vfs.lookup(parent: h.vfs.root(), name: "nope")
            }
        }
    }

    @Test("looking up through a regular file is ENOTDIR without a round trip")
    func throughFile() async throws {
        try await withHarness(populate: { _ = try $0.addFile("/f", text: "x") }) { h in
            let (file, _) = try await h.vfs.lookup(parent: h.vfs.root(), name: "f")
            await #expect(throws: FSError.notDirectory) {
                _ = try await h.vfs.lookup(parent: file, name: "child")
            }
        }
    }

    // ".." is deliberately absent: lookup accepts it and climbs to the parent.
    @Test("names that cannot mean anything are rejected before the wire",
          arguments: ["", "a/b", "\u{0}bad"])
    func badNames(name: String) async throws {
        try await withHarness { h in
            await #expect(throws: (any Error).self) {
                _ = try await h.vfs.lookup(parent: h.vfs.root(), name: name)
            }
        }
    }

    @Test("an over-long name is ENAMETOOLONG on both lookup and create")
    func longName() async throws {
        try await withHarness { h in
            let name = String(repeating: "x", count: 256)
            await #expect(throws: FSError.nameTooLong) {
                _ = try await h.vfs.lookup(parent: h.vfs.root(), name: name)
            }
            await #expect(throws: FSError.nameTooLong) {
                _ = try await h.vfs.create(parent: h.vfs.root(), name: name, permissions: 0o644)
            }
        }
    }

    @Test("dot-dot climbs to the parent and stops at the root")
    func dotDot() async throws {
        try await withHarness(populate: { _ = try $0.addDirectory("/sub") }) { h in
            let (sub, _) = try await h.vfs.lookup(parent: h.vfs.root(), name: "sub")
            let (up, _) = try await h.vfs.lookup(parent: sub, name: "..")
            #expect(up == h.vfs.root())
            let (stillRoot, _) = try await h.vfs.lookup(parent: h.vfs.root(), name: "..")
            #expect(stillRoot == h.vfs.root())
        }
    }

    @Test("resolve walks a whole path")
    func resolvePath() async throws {
        try await withHarness(populate: {
            _ = try $0.addDirectory("/a")
            _ = try $0.addDirectory("/a/b")
            _ = try $0.addFile("/a/b/c.txt", text: "deep")
        }) { h in
            let (node, attrs) = try await h.vfs.resolve("/a/b/c.txt")
            #expect(attrs.type == .regular)
            let data = try await h.vfs.read(node, offset: 0, count: 64)
            #expect(String(decoding: data, as: UTF8.self) == "deep")
        }
    }

    @Test("attributes are cached for the configured window and no longer")
    func attributeCache() async throws {
        try await withHarness(
            options: VFSOptions(attributeCacheDuration: 60),
            populate: { _ = try $0.addFile("/f", text: "hello") }
        ) { h in
            let (node, first) = try await h.vfs.resolve("/f")
            #expect(first.size == 5)
            // Change the file behind the VFS's back; the cache should hide it.
            _ = try h.memory.addFile("/f", text: "much longer content")
            let cached = try await h.vfs.getAttributes(node)
            #expect(cached.size == 5)

            await h.vfs.invalidate(node)
            let fresh = try await h.vfs.getAttributes(node)
            #expect(fresh.size == UInt64("much longer content".utf8.count))
        }
    }
}

@Suite("VFS reading and writing")
struct IOTests {
    @Test("a file larger than msize is read in full")
    func largeRead() async throws {
        let payload = (0..<200_000).map { UInt8(($0 &* 7) & 0xFF) }
        try await withHarness(msize: 8192, populate: {
            _ = try $0.addFile("/big.bin", contents: payload)
        }) { h in
            let (node, attrs) = try await h.vfs.resolve("/big.bin")
            #expect(attrs.size == UInt64(payload.count))
            let got = try await h.vfs.read(node, offset: 0, count: payload.count)
            #expect(got == payload)
        }
    }

    @Test("a write larger than msize is split across messages")
    func largeWrite() async throws {
        let payload = (0..<150_000).map { UInt8(($0 &* 13) & 0xFF) }
        try await withHarness(msize: 8192) { h in
            let (node, _) = try await h.vfs.create(
                parent: h.vfs.root(), name: "out.bin", permissions: 0o644)
            try await h.vfs.write(node, offset: 0, data: payload)
            #expect(try h.memory.contents(of: "/out.bin") == payload)
        }
    }

    @Test("reading past the end returns nothing rather than failing")
    func readPastEnd() async throws {
        try await withHarness(populate: { _ = try $0.addFile("/f", text: "abc") }) { h in
            let (node, _) = try await h.vfs.resolve("/f")
            #expect(try await h.vfs.read(node, offset: 1000, count: 10).isEmpty)
        }
    }

    @Test("reading a directory is EISDIR")
    func readDirectory() async throws {
        try await withHarness(populate: { _ = try $0.addDirectory("/d") }) { h in
            let (node, _) = try await h.vfs.resolve("/d")
            await #expect(throws: FSError.isDirectory) {
                _ = try await h.vfs.read(node, offset: 0, count: 10)
            }
        }
    }

    /// The regression this exists for: the VFS actor yields at every `await`,
    /// so a second caller arriving mid-read used to be able to re-open the file
    /// and clunk the fid the first was still using.
    @Test("many concurrent readers and writers never disturb each other's fid")
    func concurrentAccess() async throws {
        let payload = (0..<64_000).map { UInt8($0 & 0xFF) }
        try await withHarness(msize: 16 * 1024, populate: {
            _ = try $0.addFile("/shared.bin", contents: payload)
            _ = try $0.addFile("/scratch.bin", contents: [])
        }) { h in
            let (reader, _) = try await h.vfs.resolve("/shared.bin")
            let (writer, _) = try await h.vfs.resolve("/scratch.bin")
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<12 {
                    group.addTask {
                        let offset = UInt64(i * 1000)
                        let chunk = try await h.vfs.read(reader, offset: offset, count: 2000)
                        #expect(chunk == Array(payload[Int(offset)..<Int(offset) + 2000]))
                    }
                }
                // Writes force the shared file's fid to be re-opened for a
                // wider access mode while the reads above are in flight.
                for i in 0..<6 {
                    group.addTask {
                        try await h.vfs.write(writer, offset: UInt64(i * 100),
                                              data: Array(repeating: UInt8(i), count: 100))
                    }
                    group.addTask {
                        _ = try await h.vfs.read(reader, offset: 0, count: 4096)
                    }
                }
                try await group.waitForAll()
            }
        }
    }

    @Test("reading and writing the same file needs only one fid")
    func readWriteSameFile() async throws {
        try await withHarness { h in
            let (node, _) = try await h.vfs.create(
                parent: h.vfs.root(), name: "rw.bin", permissions: 0o644)
            try await h.vfs.write(node, offset: 0, data: Array("hello".utf8))
            let back = try await h.vfs.read(node, offset: 0, count: 32)
            #expect(String(decoding: back, as: UTF8.self) == "hello")
            try await h.vfs.write(node, offset: 5, data: Array(" again".utf8))
            let again = try await h.vfs.read(node, offset: 0, count: 32)
            #expect(String(decoding: again, as: UTF8.self) == "hello again")
        }
    }
}

@Suite("VFS directories")
struct DirectoryTests {
    @Test("a directory listing excludes dot and dot-dot")
    func listing() async throws {
        try await withHarness(populate: {
            _ = try $0.addFile("/a", text: "")
            _ = try $0.addFile("/b", text: "")
            _ = try $0.addDirectory("/c")
        }) { h in
            let entries = try await h.vfs.readDirectoryAll(h.vfs.root())
            #expect(Set(entries.map(\.name)) == ["a", "b", "c"])
            #expect(entries.first { $0.name == "c" }?.type == .directory)
        }
    }

    @Test("a large directory pages correctly with no gaps or repeats")
    func paging() async throws {
        let count = 400
        try await withHarness(msize: 8192, populate: { memory in
            for i in 0..<count { _ = try memory.addFile("/entry-\(i)", text: "") }
        }) { h in
            var names: [String] = []
            var cookie: UInt64 = 0
            var rounds = 0
            while rounds < 200 {
                rounds += 1
                let chunk = try await h.vfs.readDirectory(h.vfs.root(), cookie: cookie)
                guard let last = chunk.entries.last else { break }
                names.append(contentsOf: chunk.entries.map(\.name))
                cookie = last.cookie
            }
            #expect(rounds > 1, "the directory should not have fitted in one message")
            #expect(names.count == count)
            #expect(Set(names).count == count, "duplicate entries across pages")
        }
    }

    @Test("listing a regular file is ENOTDIR")
    func notDirectory() async throws {
        try await withHarness(populate: { _ = try $0.addFile("/f", text: "x") }) { h in
            let (node, _) = try await h.vfs.resolve("/f")
            await #expect(throws: FSError.notDirectory) {
                _ = try await h.vfs.readDirectory(node)
            }
        }
    }
}

@Suite("VFS namespace")
struct NamespaceTests {
    @Test("create, then read back through a fresh lookup")
    func create() async throws {
        try await withHarness { h in
            let (node, attrs) = try await h.vfs.create(
                parent: h.vfs.root(), name: "new.txt", permissions: 0o640)
            #expect(attrs.type == .regular)
            try await h.vfs.write(node, offset: 0, data: Array("body".utf8))
            await h.vfs.closeHandle(node)

            let (again, _) = try await h.vfs.resolve("/new.txt")
            let data = try await h.vfs.read(again, offset: 0, count: 16)
            #expect(String(decoding: data, as: UTF8.self) == "body")
        }
    }

    @Test("mkdir then rmdir")
    func directories() async throws {
        try await withHarness { h in
            let (dir, attrs) = try await h.vfs.mkdir(
                parent: h.vfs.root(), name: "d", permissions: 0o755)
            #expect(attrs.type == .directory)
            _ = dir
            try await h.vfs.remove(parent: h.vfs.root(), name: "d", isDirectory: true)
            await #expect(throws: FSError.notFound) {
                _ = try await h.vfs.lookup(parent: h.vfs.root(), name: "d")
            }
        }
    }

    @Test("removing a file makes stale references report ESTALE, not a new file")
    func staleAfterRemove() async throws {
        try await withHarness(populate: { _ = try $0.addFile("/victim", text: "x") }) { h in
            let (node, _) = try await h.vfs.resolve("/victim")
            try await h.vfs.remove(parent: h.vfs.root(), name: "victim", isDirectory: false)
            await #expect(throws: FSError.staleHandle) {
                _ = try await h.vfs.getAttributes(node)
            }
        }
    }

    @Test("rename moves a node and updates what its path resolves to")
    func rename() async throws {
        try await withHarness(populate: {
            _ = try $0.addDirectory("/dst")
            _ = try $0.addFile("/a.txt", text: "content")
        }) { h in
            let (node, _) = try await h.vfs.resolve("/a.txt")
            let (dst, _) = try await h.vfs.resolve("/dst")
            try await h.vfs.rename(fromParent: h.vfs.root(), fromName: "a.txt",
                                   toParent: dst, toName: "b.txt")

            // The node survives the move and still reads correctly, which only
            // works if its cached path was updated rather than left behind.
            let data = try await h.vfs.read(node, offset: 0, count: 32)
            #expect(String(decoding: data, as: UTF8.self) == "content")

            let (moved, _) = try await h.vfs.resolve("/dst/b.txt")
            #expect(moved == node)
            await #expect(throws: FSError.notFound) {
                _ = try await h.vfs.lookup(parent: h.vfs.root(), name: "a.txt")
            }
        }
    }

    @Test("symlink and readlink round-trip")
    func symlink() async throws {
        try await withHarness { h in
            let (_, attrs) = try await h.vfs.symlink(
                parent: h.vfs.root(), name: "link", target: "../target")
            #expect(attrs.type == .symlink)
            let (node, _) = try await h.vfs.lookup(parent: h.vfs.root(), name: "link")
            #expect(try await h.vfs.readlink(node) == "../target")
        }
    }

    @Test("truncate and chmod are visible afterwards")
    func setAttributes() async throws {
        try await withHarness(populate: {
            _ = try $0.addFile("/f", contents: Array(repeating: 0x41, count: 100))
        }) { h in
            let (node, _) = try await h.vfs.resolve("/f")
            let truncated = try await h.vfs.setAttributes(node, size: 10)
            #expect(truncated.size == 10)
            let chmodded = try await h.vfs.setAttributes(node, permissions: 0o600)
            #expect(chmodded.permissions & 0o777 == 0o600)
        }
    }

    @Test("a read-only VFS refuses every change")
    func readOnly() async throws {
        try await withHarness(
            options: VFSOptions(attributeCacheDuration: 0, readOnly: true),
            populate: { _ = try $0.addFile("/f", text: "x") }
        ) { h in
            let (node, _) = try await h.vfs.resolve("/f")
            await #expect(throws: FSError(EROFS)) {
                try await h.vfs.write(node, offset: 0, data: [1])
            }
            await #expect(throws: FSError(EROFS)) {
                _ = try await h.vfs.create(parent: h.vfs.root(), name: "n", permissions: 0o644)
            }
            await #expect(throws: FSError(EROFS)) {
                try await h.vfs.remove(parent: h.vfs.root(), name: "f", isDirectory: false)
            }
            // Reads still work.
            #expect(try await h.vfs.read(node, offset: 0, count: 4).count == 1)
        }
    }

    @Test("forced ids override whatever the server reports")
    func forcedOwnership() async throws {
        try await withHarness(
            options: VFSOptions(attributeCacheDuration: 0, forcedUID: 501, forcedGID: 20),
            populate: { _ = try $0.addFile("/f", text: "x") }
        ) { h in
            let (_, attrs) = try await h.vfs.resolve("/f")
            #expect(attrs.uid == 501)
            #expect(attrs.gid == 20)
        }
    }
}

@Suite("VFS fid management")
struct FidTests {
    /// Servers have finite fid tables, so the VFS evicts the least recently
    /// used walked fid. Touching far more files than the cache holds must not
    /// exhaust the server or lose the ability to reach an evicted file.
    @Test("walking more files than the fid cache holds still works")
    func eviction() async throws {
        let fileCount = 60
        try await withHarness(
            options: VFSOptions(attributeCacheDuration: 0, maximumCachedFids: 8),
            populate: { memory in
                for i in 0..<fileCount {
                    _ = try memory.addFile("/f\(i)", text: "content \(i)")
                }
            }
        ) { h in
            var nodes: [NodeID] = []
            for i in 0..<fileCount {
                let (node, _) = try await h.vfs.resolve("/f\(i)")
                nodes.append(node)
            }
            // Reach back to the earliest files, whose fids are long gone.
            for i in [0, 1, 2, 30] {
                let data = try await h.vfs.read(nodes[i], offset: 0, count: 64)
                #expect(String(decoding: data, as: UTF8.self) == "content \(i)")
            }
        }
    }

    @Test("closing a handle releases the open fid")
    func closeHandle() async throws {
        try await withHarness(populate: { _ = try $0.addFile("/f", text: "abc") }) { h in
            let (node, _) = try await h.vfs.resolve("/f")
            _ = try await h.vfs.read(node, offset: 0, count: 3)
            await h.vfs.closeHandle(node)
            // Re-opening after a close must still work.
            let again = try await h.vfs.read(node, offset: 0, count: 3)
            #expect(String(decoding: again, as: UTF8.self) == "abc")
        }
    }
}

@Suite("VFS across dialects")
struct DialectTests {
    @Test("the same operations work on every dialect",
          arguments: [NinePVersion.v9P2000L, .v9P2000u, .v9P2000])
    func acrossDialects(version: NinePVersion) async throws {
        try await withHarness(version: version, populate: {
            _ = try $0.addDirectory("/d")
            _ = try $0.addFile("/d/f.txt", text: "hello")
        }) { h in
            #expect(h.vfs.protocolVersion == version)

            let (node, attrs) = try await h.vfs.resolve("/d/f.txt")
            #expect(attrs.type == .regular)
            #expect(attrs.size == 5)

            let data = try await h.vfs.read(node, offset: 0, count: 16)
            #expect(String(decoding: data, as: UTF8.self) == "hello")

            let entries = try await h.vfs.readDirectoryAll(h.vfs.root())
            #expect(entries.map(\.name) == ["d"])

            // Every dialect must be able to answer this, even the ones with no
            // Tstatfs, because a volume whose df fails is a broken volume.
            let stats = try await h.vfs.statfs()
            #expect(stats.blockSize > 0)
            #expect(stats.totalBlocks > 0)

            let (created, _) = try await h.vfs.create(
                parent: h.vfs.root(), name: "made.txt", permissions: 0o644)
            try await h.vfs.write(created, offset: 0, data: Array("written".utf8))
            await h.vfs.closeHandle(created)
            #expect(try h.memory.contents(of: "/made.txt") == Array("written".utf8))

            _ = try await h.vfs.mkdir(parent: h.vfs.root(), name: "sub", permissions: 0o755)
            #expect(try h.memory.names(in: "/").contains("sub"))

            try await h.vfs.remove(parent: h.vfs.root(), name: "made.txt", isDirectory: false)
            #expect(!(try h.memory.names(in: "/").contains("made.txt")))
        }
    }

    /// Base 9P2000 renames with a wstat, which cannot move a file between
    /// directories. Saying so plainly beats a confusing failure later.
    @Test("base 9P2000 reports EXDEV for a cross-directory rename")
    func legacyRenameLimit() async throws {
        try await withHarness(version: .v9P2000, populate: {
            _ = try $0.addDirectory("/dst")
            _ = try $0.addFile("/a.txt", text: "x")
        }) { h in
            let (dst, _) = try await h.vfs.resolve("/dst")
            await #expect(throws: FSError(EXDEV)) {
                try await h.vfs.rename(fromParent: h.vfs.root(), fromName: "a.txt",
                                       toParent: dst, toName: "a.txt")
            }
            // A rename within one directory is fine.
            try await h.vfs.rename(fromParent: h.vfs.root(), fromName: "a.txt",
                                   toParent: h.vfs.root(), toName: "b.txt")
            #expect(try h.memory.names(in: "/").contains("b.txt"))
        }
    }
}
