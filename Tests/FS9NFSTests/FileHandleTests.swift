import Testing
import Foundation
import FS9NFS
import FS9Core

@Suite("File handles")
struct FileHandleTests {
    @Test("a handle round-trips and stays inside the 64-byte NFSv3 limit")
    func roundTrip() throws {
        let boot = BootVerifier(value: 0x0123_4567_89AB_CDEF)
        let handle = NFSFileHandle(boot: boot, node: 4242)
        let bytes = handle.bytes
        #expect(bytes.count == NFSFileHandle.encodedSize)
        #expect(bytes.count <= nfsFileHandleSize)
        // Magic first, so a handle from another server is recognisable.
        #expect(Array(bytes[0..<4]) == Array("9NFS".utf8))
        #expect(bytes[4] == NFSFileHandle.currentVersion)

        let decoded = try #require(NFSFileHandle.decode(bytes, boot: boot))
        #expect(decoded.node == 4242)
        #expect(decoded.boot == boot)
    }

    @Test("a handle from a previous server instance is rejected")
    func differentBootVerifier() {
        let old = BootVerifier(value: 1)
        let new = BootVerifier(value: 2)
        let bytes = NFSFileHandle(boot: old, node: 7).bytes
        #expect(NFSFileHandle.decode(bytes, boot: new) == nil)
    }

    @Test("wrong magic, wrong version and wrong length are all rejected")
    func malformedHandles() {
        let boot = BootVerifier(value: 99)
        var bytes = NFSFileHandle(boot: boot, node: 7).bytes

        var wrongMagic = bytes
        wrongMagic[0] ^= 0xFF
        #expect(NFSFileHandle.decode(wrongMagic, boot: boot) == nil)

        var wrongVersion = bytes
        wrongVersion[4] = 99
        #expect(NFSFileHandle.decode(wrongVersion, boot: boot) == nil)

        bytes.removeLast()
        #expect(NFSFileHandle.decode(bytes, boot: boot) == nil)
        #expect(NFSFileHandle.decode([], boot: boot) == nil)
    }

    @Test("the boot verifier differs between instances")
    func verifiersDiffer() {
        #expect(BootVerifier.generate().value != BootVerifier.generate().value)
    }

    @Test("a handle minted by an earlier instance gets NFS3ERR_STALE from the server")
    func staleAcrossRestart() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/live", text: "here")
        let client = bridge.client

        // A well-formed handle for a real node, stamped with someone else's
        // boot verifier: exactly what a client holds after our process
        // restarts underneath it.
        let foreignBoot = BootVerifier(value: bridge.bridge.export.boot.value &+ 1)
        let foreign = NFSFileHandle(boot: foreignBoot, node: NineVFS.rootNode).bytes
        #expect(foreign.count == NFSFileHandle.encodedSize)

        let stale = NFSStatus.stale.rawValue
        let attributes = try await client.getAttributes(foreign)
        #expect(attributes.status == stale)
        let lookedUp = try await client.lookup(foreign, "live")
        #expect(lookedUp.status == stale)
        let listed = try await client.readdir(foreign)
        #expect(listed.status == stale)
        let removed = try await client.remove(foreign, "live")
        #expect(removed == stale)

        // Ours still works, so the rejection is about the verifier and not
        // about the server having fallen over.
        let ours = try await client.getAttributes(bridge.root)
        #expect(ours.status == 0)
    }

    @Test("a handle for a node that never existed is stale, not a crash")
    func unknownNode() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let bogus = NFSFileHandle(boot: bridge.bridge.export.boot, node: 999_999).bytes
        let attributes = try await bridge.client.getAttributes(bogus)
        #expect(attributes.status == NFSStatus.stale.rawValue)
    }

    @Test("a truncated handle in a request is stale rather than garbage")
    func shortHandleInRequest() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let attributes = try await bridge.client.getAttributes([1, 2, 3])
        #expect(attributes.status == NFSStatus.stale.rawValue)
    }
}
