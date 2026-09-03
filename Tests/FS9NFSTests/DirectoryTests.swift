import Testing
import Foundation
import FS9NFS

/// Names of varying length so the byte accounting has to deal with every
/// padding case rather than one uniform entry size.
private func generatedNames(_ count: Int) -> [String] {
    (0..<count).map { "entry-\($0)-\(String(repeating: "n", count: $0 % 7))" }
}

@Suite("READDIR paging")
struct DirectoryPagingTests {
    @Test("a first page carries . and .. before anything else")
    func dotEntriesFirst() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        for name in generatedNames(20) { try bridge.fileSystem.addFile("/\(name)", text: "x") }

        let page = try await bridge.client.readdir(bridge.root, count: 8192)
        #expect(page.status == 0)
        #expect(page.entries.first?.name == ".")
        #expect(page.entries.dropFirst().first?.name == "..")

        let attributes = try await bridge.client.getAttributes(bridge.root)
        let rootID = attributes.attributes?.fileID
        #expect(page.entries.first?.fileID == rootID)
        // At the export root, `..` is the root as well.
        #expect(page.entries.dropFirst().first?.fileID == rootID)
    }

    @Test("a 500-entry directory is enumerated exactly once across many small pages")
    func fiveHundredEntries() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let expected = generatedNames(500)
        for name in expected { try bridge.fileSystem.addFile("/\(name)", text: "") }

        var collected: [String] = []
        var cookie: UInt64 = 0
        var verifier = [UInt8](repeating: 0, count: 8)
        var pages = 0
        var sawEOF = false

        // A byte count small enough to force many pages, but large enough that
        // at least one entry always fits.
        while pages < 400 {
            let page = try await bridge.client.readdir(
                bridge.root, cookie: cookie, verifier: verifier, count: 512)
            #expect(page.status == 0)
            pages += 1
            verifier = page.verifier
            #expect(!page.entries.isEmpty || page.eof)
            collected.append(contentsOf: page.entries.map(\.name))
            if page.eof {
                sawEOF = true
                break
            }
            // A non-final page must always advance the cookie, or the client
            // asks the same question forever.
            let next = try #require(page.entries.last?.cookie)
            #expect(next != cookie)
            cookie = next
        }

        #expect(sawEOF, "the listing never reported eof")
        #expect(pages > 1, "the byte budget did not force paging")
        #expect(collected.filter { $0 == "." }.count == 1)
        #expect(collected.filter { $0 == ".." }.count == 1)

        let real = collected.filter { $0 != "." && $0 != ".." }
        #expect(Set(real).count == real.count, "an entry was returned twice")
        #expect(Set(real) == Set(expected), "entries were missing or invented")
        #expect(real.count == expected.count)
    }

    @Test("every page fits inside the byte count the client asked for")
    func repliesRespectTheByteCount() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        for name in generatedNames(200) { try bridge.fileSystem.addFile("/\(name)", text: "") }

        for budget: UInt32 in [256, 512, 1024, 4096] {
            var cookie: UInt64 = 0
            var verifier = [UInt8](repeating: 0, count: 8)
            var pages = 0
            while pages < 400 {
                var arguments = XDREncoder()
                arguments.opaqueVariable(bridge.root)
                arguments.uint64(cookie)
                arguments.opaqueFixed(verifier)
                arguments.uint32(budget)
                let reply = try await bridge.client.connection.call(
                    program: NFSConstants.program, version: 3,
                    procedure: NFSConstants.procedureReaddir, arguments: arguments.bytes)
                #expect(reply.isSuccess)
                // A client sizes its buffer from this number; a reply that
                // overruns it is dropped and retried with the same cookie.
                #expect(reply.results.count <= Int(budget),
                        "budget \(budget) exceeded: \(reply.results.count)")

                var d = XDRDecoder(reply.results)
                #expect(try d.uint32() == 0)
                _ = try TestAttributes.decodePostOp(&d)
                verifier = try d.opaqueFixed(8)
                var last: UInt64?
                while try d.bool() {
                    _ = try d.uint64()
                    _ = try d.string(limit: 255)
                    last = try d.uint64()
                }
                if try d.bool() { break }
                cookie = try #require(last)
                pages += 1
            }
        }
    }

    @Test("READDIRPLUS returns attributes and a usable handle for every entry")
    func readdirPlus() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/alpha", text: "12345")
        try bridge.fileSystem.addDirectory("/beta")
        try bridge.fileSystem.addSymlink("/gamma", target: "alpha")

        let page = try await bridge.client.readdirPlus(bridge.root, dircount: 4096, maxcount: 32768)
        #expect(page.status == 0)
        #expect(page.eof)
        #expect(Set(page.entries.map(\.name)) == [".", "..", "alpha", "beta", "gamma"])

        for entry in page.entries {
            #expect(entry.hasAttributes, "\(entry.name) had no attributes")
            let handle = try #require(entry.handle, "\(entry.name) had no handle")
            #expect(handle.count == NFSFileHandle.encodedSize)
            // The handle must actually work, not merely be well formed.
            let attributes = try await bridge.client.getAttributes(handle)
            #expect(attributes.status == 0)
            #expect(attributes.attributes?.fileID == entry.fileID)
        }

        let alpha = try #require(page.entries.first { $0.name == "alpha" }?.handle)
        let contents = try await bridge.client.read(alpha, offset: 0, count: 16)
        #expect(contents.data == Array("12345".utf8))
    }

    @Test("READDIRPLUS pages over a large directory without duplicates")
    func readdirPlusPaging() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let expected = generatedNames(120)
        for name in expected { try bridge.fileSystem.addFile("/\(name)", text: "") }

        var collected: [String] = []
        var cookie: UInt64 = 0
        var verifier = [UInt8](repeating: 0, count: 8)
        var pages = 0
        var sawEOF = false
        while pages < 200 {
            let page = try await bridge.client.readdirPlus(
                bridge.root, cookie: cookie, verifier: verifier, dircount: 512, maxcount: 2048)
            #expect(page.status == 0)
            pages += 1
            verifier = page.verifier
            collected.append(contentsOf: page.entries.map(\.name))
            if page.eof {
                sawEOF = true
                break
            }
            cookie = try #require(page.entries.last?.cookie)
        }
        #expect(sawEOF)
        #expect(pages > 1)
        let real = collected.filter { $0 != "." && $0 != ".." }
        #expect(Set(real).count == real.count)
        #expect(Set(real) == Set(expected))
    }

    @Test("an empty directory reports only . and .. and eof")
    func emptyDirectory() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addDirectory("/empty")

        let directory = try #require(try await bridge.client.lookup(bridge.root, "empty").handle)
        let page = try await bridge.client.readdir(directory)
        #expect(page.status == 0)
        #expect(page.eof)
        #expect(page.entries.map(\.name) == [".", ".."])

        // `..` in a subdirectory is the parent, not the subdirectory.
        let rootAttributes = try await bridge.client.getAttributes(bridge.root)
        #expect(page.entries.last?.fileID == rootAttributes.attributes?.fileID)
    }

    @Test("a byte count too small for a single entry gives NFS3ERR_TOOSMALL")
    func tooSmall() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/x", text: "")
        let page = try await bridge.client.readdir(bridge.root, count: 16)
        #expect(page.status == NFSStatus.toosmall.rawValue)
    }

    @Test("a cookie the server never issued is rejected with NFS3ERR_BAD_COOKIE")
    func badCookie() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/x", text: "")
        // The low two bits identify our cookie encoding; 0b01 with a high value
        // is not a shape we ever hand out.
        let page = try await bridge.client.readdir(bridge.root, cookie: 0xDEAD_BEEF_0000_0001)
        #expect(page.status == NFSStatus.badCookie.rawValue)
    }

    @Test("a cookie verifier from another server instance is rejected")
    func badCookieVerifier() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        for i in 0..<5 { try bridge.fileSystem.addFile("/f\(i)", text: "") }

        let first = try await bridge.client.readdir(bridge.root, count: 256)
        let cookie = try #require(first.entries.last?.cookie)
        let page = try await bridge.client.readdir(
            bridge.root, cookie: cookie, verifier: [UInt8](repeating: 0xEE, count: 8))
        #expect(page.status == NFSStatus.badCookie.rawValue)
    }

    @Test("READDIR on a regular file is NFS3ERR_NOTDIR")
    func readdirOnFile() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/plain", text: "x")
        let file = try #require(try await bridge.client.lookup(bridge.root, "plain").handle)
        let page = try await bridge.client.readdir(file)
        #expect(page.status == NFSStatus.notdir.rawValue)
    }
}
