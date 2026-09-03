import Testing
import Foundation
import FS9Core
@testable import FS9KitAdapter

@Suite("Directory enumeration")
struct DirectoryPlanTests {

    private func chunk(_ names: [(String, NodeID, FileType, UInt64)], atEnd: Bool = false) -> DirectoryChunk {
        DirectoryChunk(
            entries: names.map { DirectoryEntry(name: $0.0, node: $0.1, type: $0.2, cookie: $0.3) },
            atEnd: atEnd)
    }

    @Test("entries carry the identifier FSKit will see for them")
    func identifiers() {
        let planned = FS9DirectoryPlanner.plan(chunk([
            ("readme", 5, .regular, 100),
            ("sub", 6, .directory, 200),
            ("link", 7, .symlink, 300),
        ]))
        #expect(planned.map(\.name) == ["readme", "sub", "link"])
        #expect(planned.map(\.kind) == [.file, .directory, .symlink])
        #expect(planned.map(\.itemID) == [5, 6, 7].map(FS9ItemIdentifier.itemID(for:)))
        #expect(planned.map(\.node) == [5, 6, 7])
    }

    /// 9P2000.L `Treaddir` includes `.` and `..`, FSKit's sample code does not
    /// pack them, and packing them anyway would double them up in the kernel's
    /// view of the directory.
    @Test("dot entries are dropped")
    func dotEntries() {
        let planned = FS9DirectoryPlanner.plan(chunk([
            (".", 1, .directory, 1),
            ("..", 1, .directory, 2),
            ("real", 9, .regular, 3),
        ]))
        #expect(planned.map(\.name) == ["real"])
        #expect(FS9DirectoryPlanner.isDotEntry("."))
        #expect(FS9DirectoryPlanner.isDotEntry(".."))
        #expect(FS9DirectoryPlanner.isDotEntry("...") == false)
        #expect(FS9DirectoryPlanner.isDotEntry(".hidden") == false)
    }

    /// The cookie is the 9P offset unchanged. Biasing it — to make room for
    /// synthesised entries, say — breaks the moment a `telldir`-based server
    /// returns an offset near the top of the range, which they legitimately do.
    @Test("the cookie is the server's offset, untouched, at both extremes")
    func cookiesAreServerOffsets() {
        let planned = FS9DirectoryPlanner.plan(chunk([
            ("a", 2, .regular, 0),
            ("b", 3, .regular, UInt64.max),
        ]))
        #expect(planned.map(\.nextCookie) == [0, UInt64.max])
        #expect(FS9DirectoryPlanner.offset(forCookie: UInt64.max) == UInt64.max)
        #expect(FS9DirectoryPlanner.offset(forCookie: 0) == 0)
    }

    @Test("an empty chunk ends the listing")
    func emptyChunkEnds() {
        #expect(FS9DirectoryPlanner.isFinished(chunk([])))
        #expect(FS9DirectoryPlanner.resumeCookie(after: chunk([])) == nil)
    }

    @Test("a full chunk resumes from its last entry")
    func resume() {
        let page = chunk([("a", 2, .regular, 10), ("b", 3, .regular, 20)])
        #expect(FS9DirectoryPlanner.isFinished(page) == false)
        #expect(FS9DirectoryPlanner.resumeCookie(after: page) == 20)
    }

    /// A directory holding nothing but `.` and `..` yields no packable entries
    /// yet is not finished, so "finished" has to be read off the chunk rather
    /// than off the planned entries.
    @Test("a chunk of only dot entries is not the end of the listing")
    func dotOnlyChunkIsNotTheEnd() {
        let page = chunk([(".", 1, .directory, 1), ("..", 1, .directory, 2)])
        #expect(FS9DirectoryPlanner.plan(page).isEmpty)
        #expect(FS9DirectoryPlanner.isFinished(page) == false)
        #expect(FS9DirectoryPlanner.resumeCookie(after: page) == 2)
    }
}

@Suite("Item table")
struct ItemTableTests {
    private final class Fake { let node: NodeID; init(_ node: NodeID) { self.node = node } }

    /// FSKit decides what is what by object identity: two objects for one inode
    /// make the kernel treat them as two files.
    @Test("a node is interned exactly once")
    func interning() {
        let table = FS9ItemTable<Fake>()
        var made = 0
        let first = table.item(for: 7) { made += 1; return Fake(7) }
        let second = table.item(for: 7) { made += 1; return Fake(7) }
        #expect(made == 1)
        #expect(first === second)
        #expect(table.count == 1)
    }

    @Test("removal forgets the item and hands it back")
    func removal() {
        let table = FS9ItemTable<Fake>()
        let item = table.item(for: 3) { Fake(3) }
        #expect(table.existing(3) === item)
        #expect(table.remove(3) === item)
        #expect(table.existing(3) == nil)
        #expect(table.remove(3) == nil)
    }

    @Test("draining empties the table and returns everything")
    func draining() {
        let table = FS9ItemTable<Fake>()
        for node in NodeID(1)...5 { _ = table.item(for: node) { Fake(node) } }
        #expect(table.all().count == 5)
        let drained = table.drain()
        #expect(drained.count == 5)
        #expect(table.count == 0)
        #expect(Set(drained.map(\.node)) == Set(NodeID(1)...5))
    }

    @Test("concurrent interning still produces one object per node")
    func concurrentInterning() async {
        let table = FS9ItemTable<Fake>()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask { _ = table.item(for: 1) { Fake(1) } }
            }
        }
        #expect(table.count == 1)
    }
}

@Suite("Container identifiers")
struct StableUUIDTests {

    /// `fskitd` treats an identifier it has not seen as an unknown container
    /// and closes it, so the same target must always produce the same UUID —
    /// across probe and load, and across mounts.
    @Test("the same name always gives the same UUID")
    func deterministic() {
        #expect(StableUUID.uuid(for: "9p://host:564/tree") == StableUUID.uuid(for: "9p://host:564/tree"))
    }

    @Test("different targets give different UUIDs")
    func distinct() {
        #expect(StableUUID.uuid(for: "9p://host:564/a") != StableUUID.uuid(for: "9p://host:564/b"))
        #expect(StableUUID.uuid(for: "") != StableUUID.uuid(for: " "))
    }

    @Test("the UUID is well-formed: version 5, RFC 4122 variant")
    func wellFormed() {
        for name in ["", "9p://host/", String(repeating: "x", count: 1000)] {
            let bytes = StableUUID.bytes(for: name)
            #expect(bytes.count == 16)
            #expect(bytes[6] & 0xF0 == 0x50)
            #expect(bytes[8] & 0xC0 == 0x80)
        }
    }

    @Test("SHA-256 matches the published vectors", arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
    ])
    func sha256Vectors(input: String, expected: String) {
        let digest = SHA256.hash(Array(input.utf8))
        #expect(digest.map { String(format: "%02x", $0) }.joined() == expected)
    }

    /// The padding path has three cases — under, exactly at, and over the
    /// 56-byte boundary in the final block — and getting one wrong produces a
    /// digest that is stable but wrong, which no other test would catch.
    @Test("SHA-256 pads every message length correctly")
    func sha256Lengths() {
        // A million 'a' characters is the classic long vector.
        let million = SHA256.hash([UInt8](repeating: 0x61, count: 1_000_000))
        #expect(million.map { String(format: "%02x", $0) }.joined()
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        for length in [55, 56, 57, 63, 64, 65, 119, 120] {
            #expect(SHA256.hash([UInt8](repeating: 0x41, count: length)).count == 32)
        }
    }
}
