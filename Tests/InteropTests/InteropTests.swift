import Testing
import Foundation
import NineP
import NinePClient
import FS9Core

/// Interoperability tests against a *third-party* 9P server.
///
/// A client that only ever talks to its own server proves very little: both
/// ends can share the same misreading of the spec. These tests point the client
/// at a server written by someone else — `p9ufs` from `hugelgupf/p9` for
/// 9P2000.L, `export9p` from `knusbaum/go9p` for base 9P2000 — exporting a real
/// directory whose contents the test can also inspect directly.
///
/// They are skipped unless the harness sets the environment, so an ordinary
/// `swift test` stays hermetic. `Scripts/interop.sh` sets it up.
struct InteropEnvironment: Sendable {
    /// Dial string for the server, e.g. `tcp!127.0.0.1!5640`.
    let address: String
    /// The directory the server exports, so assertions can compare against the
    /// real filesystem rather than against the client's own beliefs.
    let root: URL
    /// The dialect the server is expected to negotiate.
    let expectedVersion: NinePVersion?
    /// Whether the server supports creating things. `export9p` is read-only in
    /// some configurations.
    let writable: Bool
    /// A label used in failure messages.
    let name: String
    /// Dialects to offer, most preferred first.
    ///
    /// Worth pinning per server: `export9p` cannot even answer a 9P2000.L
    /// Tversion — it logs "Cannot reply to type 100", drops the request and
    /// leaks a goroutine — so offering it costs a handshake timeout on every
    /// connection and eventually kills the server.
    let offer: [NinePVersion]

    static var current: InteropEnvironment? {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["FS9KIT_9P_ADDR"], !address.isEmpty,
              let root = env["FS9KIT_9P_ROOT"], !root.isEmpty else { return nil }
        return InteropEnvironment(
            address: address,
            root: URL(fileURLWithPath: root),
            expectedVersion: env["FS9KIT_9P_VERSION"].flatMap(NinePVersion.init(rawValue:)),
            writable: env["FS9KIT_9P_READONLY"] == nil,
            name: env["FS9KIT_9P_NAME"] ?? address,
            offer: (env["FS9KIT_9P_OFFER"]?.split(separator: ",").compactMap {
                NinePVersion(rawValue: String($0))
            }).flatMap { $0.isEmpty ? nil : $0 } ?? NinePSessionOptions().versions)
    }
}

let interopEnabled = InteropEnvironment.current != nil

@Suite("9P interoperability", .enabled(if: interopEnabled))
struct InteropTests {
    let env: InteropEnvironment

    init() throws {
        env = try #require(InteropEnvironment.current)
    }

    func connect() async throws -> NinePClient {
        let endpoint = try NinePEndpoint.parse(env.address)
        return try await NinePClient.connect(
            to: endpoint,
            credentials: NinePCredentials(uname: NSUserName().isEmpty ? "nobody" : NSUserName()),
            options: NinePSessionOptions(
                msize: 128 * 1024, versions: env.offer,
                connectTimeout: 10, handshakeTimeout: 10))
    }

    func withVFS(_ body: (NineVFS) async throws -> Void) async throws {
        let client = try await connect()
        let vfs = NineVFS(client: client, options: VFSOptions(attributeCacheDuration: 0))
        do {
            try await body(vfs)
        } catch {
            await vfs.shutdown()
            throw error
        }
        await vfs.shutdown()
    }

    /// A scratch directory inside the export, cleaned up afterwards.
    func withScratch(_ body: (NineVFS, NodeID, URL) async throws -> Void) async throws {
        let name = "fs9kit-scratch-\(UInt32.random(in: 0..<UInt32.max))"
        let onDisk = env.root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: onDisk, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: onDisk) }
        try await withVFS { vfs in
            let (node, _) = try await vfs.resolve(name)
            try await body(vfs, node, onDisk)
        }
    }

    // MARK: - Connection

    @Test("connects and negotiates the expected dialect")
    func negotiation() async throws {
        let client = try await connect()
        defer { client.close() }
        if let expected = env.expectedVersion {
            #expect(client.version == expected,
                    "\(env.name) negotiated \(client.version.rawValue)")
        }
        #expect(client.ioSize > 0)
    }

    @Test("the root attaches and reports as a directory")
    func rootAttach() async throws {
        try await withVFS { vfs in
            let attrs = try await vfs.getAttributes(vfs.root())
            #expect(attrs.type == .directory)
        }
    }

    /// Several servers do not implement Tstatfs at all. The VFS substitutes a
    /// plausible answer rather than failing, because a volume whose `df` errors
    /// is a broken volume as far as a mount is concerned.
    @Test("statfs answers with something usable even when the server has none")
    func statfs() async throws {
        try await withVFS { vfs in
            let stats = try await vfs.statfs()
            #expect(stats.blockSize > 0)
            #expect(stats.maximumNameLength >= 8)
            #expect(stats.totalBlocks > 0)
        }
    }

    // MARK: - Reading

    /// Listed against a directory this test owns, not the export root: the
    /// suite runs its cases in parallel and they create and delete files at the
    /// root, so a listing taken there and compared against a `contentsOfDirectory`
    /// taken a moment later disagrees for reasons that have nothing to do with
    /// the server.
    @Test("a directory listing matches what is really on disk, exactly")
    func directoryListing() async throws {
        try await withScratch { vfs, scratch, onDisk in
            try Data("a".utf8).write(to: onDisk.appendingPathComponent("a.txt"))
            try Data(repeating: 0, count: 4096)
                .write(to: onDisk.appendingPathComponent("b.bin"))
            try FileManager.default.createDirectory(
                at: onDisk.appendingPathComponent("sub"), withIntermediateDirectories: false)

            let entries = try await vfs.readDirectoryAll(scratch)
            #expect(Set(entries.map(\.name)) == ["a.txt", "b.bin", "sub"])
            #expect(entries.first { $0.name == "sub" }?.type == .directory)
            #expect(entries.first { $0.name == "a.txt" }?.type == .regular)
        }
    }

    @Test("the fixture the harness laid down is visible at the root")
    func rootListing() async throws {
        try await withVFS { vfs in
            let names = Set(try await vfs.readDirectoryAll(vfs.root()).map(\.name))
            // Only the files Scripts/interop.sh creates and never removes;
            // anything else at the root belongs to another test case.
            #expect(names.isSuperset(of: ["hello.txt", "dir", "big.bin"]),
                    "server omitted \(Set(["hello.txt", "dir", "big.bin"]).subtracting(names))")
        }
    }

    @Test("a file's bytes come back exactly")
    func readFile() async throws {
        let name = "interop-read-\(UInt32.random(in: 0..<UInt32.max)).bin"
        let onDisk = env.root.appendingPathComponent(name)
        // A size that is not a round number and crosses several read chunks.
        let payload = (0..<300_007).map { UInt8(($0 &* 31 &+ 7) & 0xFF) }
        try Data(payload).write(to: onDisk)
        defer { try? FileManager.default.removeItem(at: onDisk) }

        try await withVFS { vfs in
            let (node, attrs) = try await vfs.resolve(name)
            #expect(attrs.type == .regular)
            #expect(attrs.size == UInt64(payload.count))
            let got = try await vfs.read(node, offset: 0, count: payload.count)
            #expect(got.count == payload.count)
            #expect(got == payload)
        }
    }

    @Test("reads at an offset return the right window")
    func readAtOffset() async throws {
        let name = "interop-offset-\(UInt32.random(in: 0..<UInt32.max)).bin"
        let onDisk = env.root.appendingPathComponent(name)
        let payload = Array("0123456789abcdefghijklmnopqrstuvwxyz".utf8)
        try Data(payload).write(to: onDisk)
        defer { try? FileManager.default.removeItem(at: onDisk) }

        try await withVFS { vfs in
            let (node, _) = try await vfs.resolve(name)
            let middle = try await vfs.read(node, offset: 10, count: 6)
            #expect(middle == Array("abcdef".utf8))
            let past = try await vfs.read(node, offset: UInt64(payload.count) + 100, count: 16)
            #expect(past.isEmpty)
        }
    }

    @Test("a missing name is ENOENT, not something else")
    func missingName() async throws {
        try await withVFS { vfs in
            do {
                _ = try await vfs.lookup(parent: vfs.root(), name: "definitely-not-here-9p")
                Issue.record("expected a lookup failure")
            } catch let e as FSError {
                #expect(e.errno == ENOENT, "got \(e)")
            }
        }
    }

    @Test("walking through a regular file is ENOTDIR")
    func walkThroughFile() async throws {
        let name = "interop-notdir-\(UInt32.random(in: 0..<UInt32.max))"
        let onDisk = env.root.appendingPathComponent(name)
        try Data("x".utf8).write(to: onDisk)
        defer { try? FileManager.default.removeItem(at: onDisk) }

        try await withVFS { vfs in
            let (file, _) = try await vfs.resolve(name)
            do {
                _ = try await vfs.lookup(parent: file, name: "child")
                Issue.record("expected ENOTDIR")
            } catch let e as FSError {
                // Servers disagree — p9ufs answers EINVAL — so the VFS answers
                // this itself rather than passing the server's choice through.
                #expect(e.errno == ENOTDIR, "got \(e)")
            }
        }
    }

    @Test("a large directory enumerates completely and without duplicates")
    func largeDirectory() async throws {
        try await withScratch { vfs, scratch, onDisk in
            let count = 500
            for i in 0..<count {
                try Data().write(to: onDisk.appendingPathComponent("entry-\(i)"))
            }
            let entries = try await vfs.readDirectoryAll(scratch)
            let names = entries.map(\.name)
            #expect(names.count == count, "got \(names.count) of \(count)")
            #expect(Set(names).count == names.count, "duplicate entries in listing")
            #expect(Set(names) == Set((0..<count).map { "entry-\($0)" }))
        }
    }

    @Test("concurrent reads of the same file all succeed")
    func concurrentReads() async throws {
        let name = "interop-concurrent-\(UInt32.random(in: 0..<UInt32.max)).bin"
        let onDisk = env.root.appendingPathComponent(name)
        let payload = (0..<200_000).map { UInt8($0 & 0xFF) }
        try Data(payload).write(to: onDisk)
        defer { try? FileManager.default.removeItem(at: onDisk) }

        try await withVFS { vfs in
            let (node, _) = try await vfs.resolve(name)
            try await withThrowingTaskGroup(of: Int.self) { group in
                for i in 0..<8 {
                    group.addTask {
                        let offset = UInt64(i * 1024)
                        let chunk = try await vfs.read(node, offset: offset, count: 4096)
                        #expect(chunk == Array(payload[Int(offset)..<Int(offset) + 4096]))
                        return chunk.count
                    }
                }
                for try await n in group { #expect(n == 4096) }
            }
        }
    }

    // MARK: - Writing

    @Test("a file written through 9P appears on disk with the right bytes",
          .enabled(if: InteropEnvironment.current?.writable ?? false))
    func writeFile() async throws {
        try await withScratch { vfs, scratch, onDisk in
            let payload = (0..<150_000).map { UInt8(($0 &* 17) & 0xFF) }
            let (node, _) = try await vfs.create(parent: scratch, name: "written.bin", permissions: 0o644)
            try await vfs.write(node, offset: 0, data: payload)
            await vfs.closeHandle(node)

            let onDiskData = try Data(contentsOf: onDisk.appendingPathComponent("written.bin"))
            #expect(Array(onDiskData) == payload)
        }
    }

    @Test("mkdir, rename and remove behave",
          .enabled(if: InteropEnvironment.current?.writable ?? false))
    func namespaceOperations() async throws {
        try await withScratch { vfs, scratch, onDisk in
            _ = try await vfs.mkdir(parent: scratch, name: "sub", permissions: 0o755)
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(
                atPath: onDisk.appendingPathComponent("sub").path, isDirectory: &isDir))
            #expect(isDir.boolValue)

            let (file, _) = try await vfs.create(parent: scratch, name: "a.txt", permissions: 0o644)
            try await vfs.write(file, offset: 0, data: Array("hello".utf8))
            await vfs.closeHandle(file)

            try await vfs.rename(fromParent: scratch, fromName: "a.txt",
                                 toParent: scratch, toName: "b.txt")
            #expect(!FileManager.default.fileExists(atPath: onDisk.appendingPathComponent("a.txt").path))
            #expect(try String(contentsOf: onDisk.appendingPathComponent("b.txt"), encoding: .utf8) == "hello")

            try await vfs.remove(parent: scratch, name: "b.txt", isDirectory: false)
            #expect(!FileManager.default.fileExists(atPath: onDisk.appendingPathComponent("b.txt").path))

            try await vfs.remove(parent: scratch, name: "sub", isDirectory: true)
            #expect(!FileManager.default.fileExists(atPath: onDisk.appendingPathComponent("sub").path))
        }
    }

    @Test("truncate and chmod take effect",
          .enabled(if: InteropEnvironment.current?.writable ?? false))
    func setAttributes() async throws {
        try await withScratch { vfs, scratch, onDisk in
            let (node, _) = try await vfs.create(parent: scratch, name: "attr.txt", permissions: 0o644)
            try await vfs.write(node, offset: 0, data: Array(repeating: 0x41, count: 1000))
            await vfs.closeHandle(node)

            _ = try await vfs.setAttributes(node, size: 10)
            let after = try await vfs.getAttributes(node)
            #expect(after.size == 10)
            let onDiskSize = try FileManager.default
                .attributesOfItem(atPath: onDisk.appendingPathComponent("attr.txt").path)[.size] as? Int
            #expect(onDiskSize == 10)

            // Not every server implements chmod: p9ufs's local backend accepts
            // only size on setattr. A server that declines is not a client bug,
            // but one that accepts and then does nothing would be.
            do {
                _ = try await vfs.setAttributes(node, permissions: 0o600)
                let perms = try await vfs.getAttributes(node).permissions
                #expect(perms & 0o777 == 0o600)
            } catch let e as FSError where e.errno == ENOSYS || e.errno == ENOTSUP {
                _ = e  // documented server limitation, not a client failure
            }
        }
    }

    @Test("symlinks round-trip when the dialect supports them",
          .enabled(if: InteropEnvironment.current?.writable ?? false))
    func symlinks() async throws {
        try await withScratch { vfs, scratch, onDisk in
            guard vfs.protocolVersion != .v9P2000 else { return }
            do {
                _ = try await vfs.symlink(parent: scratch, name: "link", target: "../target")
            } catch let e as FSError where e.errno == ENOTSUP || e.errno == ENOSYS {
                return  // server declines symlinks; not a client bug
            }
            let (link, linkAttrs) = try await vfs.lookup(parent: scratch, name: "link")
            #expect(linkAttrs.type == .symlink)
            #expect(try await vfs.readlink(link) == "../target")
            let target = try FileManager.default.destinationOfSymbolicLink(
                atPath: onDisk.appendingPathComponent("link").path)
            #expect(target == "../target")
        }
    }
}
