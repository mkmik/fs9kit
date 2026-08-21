// What eight `shasum` processes reading the same file at once look like from
// the bridge's side.
//
// The kernel's NFS client does not wait for one reply before sending the next
// request, and the end-to-end mount test wedged in exactly that phase after
// every serial check had passed. Every other test here drives one request at a
// time down one connection, so nothing covered what happens when many are in
// flight at once.

import Foundation
import Testing
import FS9Core
import FS9NFS

@Suite("Concurrent load")
struct ConcurrencyTests {
    /// A file big enough that reading it takes many round trips, so the readers
    /// genuinely overlap rather than each finishing before the next starts.
    private static let fileSize = 1 << 20
    private static let chunk: UInt32 = 32 * 1024

    private static func pattern(_ size: Int) -> [UInt8] {
        (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
    }

    @Test("eight connections read the same file at once", .timeLimit(.minutes(1)))
    func manyReadersManyConnections() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }

        let content = Self.pattern(Self.fileSize)
        let created = try await bridge.client.create(bridge.root, "big.bin")
        let handle = try #require(created.handle)
        var written = 0
        while written < content.count {
            let end = min(written + Int(Self.chunk), content.count)
            let result = try await bridge.client.write(
                handle, offset: UInt64(written), data: Array(content[written..<end]))
            #expect(result.status == 0)
            written = end
        }

        let clients = try (0..<8).map { _ in try bridge.connect() }
        try await withThrowingTaskGroup(of: Int.self) { group in
            for client in clients {
                group.addTask {
                    var offset: UInt64 = 0
                    var seen: [UInt8] = []
                    while true {
                        let page = try await client.read(handle, offset: offset, count: Self.chunk)
                        #expect(page.status == 0)
                        seen.append(contentsOf: page.data)
                        offset += UInt64(page.data.count)
                        if page.eof || page.data.isEmpty { break }
                    }
                    #expect(seen == content)
                    return seen.count
                }
            }
            for try await count in group { #expect(count == content.count) }
        }
    }

    /// The same load down a single connection, which is what the kernel
    /// actually does: one TCP stream carrying many outstanding xids.
    @Test("one connection carries many requests at once", .timeLimit(.minutes(1)))
    func pipelinedOnOneConnection() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }

        let content = Self.pattern(Self.fileSize)
        let created = try await bridge.client.create(bridge.root, "big.bin")
        let handle = try #require(created.handle)
        var written = 0
        while written < content.count {
            let end = min(written + Int(Self.chunk), content.count)
            _ = try await bridge.client.write(
                handle, offset: UInt64(written), data: Array(content[written..<end]))
            written = end
        }

        let pipelined = try bridge.connectPipelined()
        let offsets = stride(from: 0, to: content.count, by: Int(Self.chunk)).map(UInt64.init)
        try await withThrowingTaskGroup(of: (UInt64, [UInt8]).self) { group in
            for offset in offsets {
                group.addTask {
                    let page = try await pipelined.read(handle, offset: offset, count: Self.chunk)
                    #expect(page.status == 0)
                    return (offset, page.data)
                }
            }
            for try await (offset, data) in group {
                let end = min(Int(offset) + Int(Self.chunk), content.count)
                #expect(data == Array(content[Int(offset)..<end]))
            }
        }
    }

    /// Readers and writers at once, so the fid leasing in the VFS is under load
    /// from both directions at the same time.
    @Test("readers and writers overlap", .timeLimit(.minutes(1)))
    func mixedLoad() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }

        let created = try await bridge.client.create(bridge.root, "shared.bin")
        let handle = try #require(created.handle)
        let block = [UInt8](repeating: 0xAB, count: Int(Self.chunk))
        _ = try await bridge.client.write(handle, offset: 0, data: block)

        let clients = try (0..<6).map { _ in try bridge.connect() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, client) in clients.enumerated() {
                group.addTask {
                    for _ in 0..<20 {
                        if index.isMultiple(of: 2) {
                            let page = try await client.read(handle, offset: 0, count: Self.chunk)
                            #expect(page.status == 0)
                        } else {
                            let result = try await client.write(handle, offset: 0, data: block)
                            #expect(result.status == 0)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// The regression test for the wedge that only a real kernel client
    /// produced: a peer that stops draining while several large replies are
    /// outstanding.
    ///
    /// Writing a reply blocks until the peer takes the bytes. When that write
    /// happened on the thread that produced the reply — a cooperative pool
    /// thread — enough simultaneous stalled replies occupied every thread in
    /// the pool, and the whole Swift concurrency runtime stopped: no task
    /// could run, so nothing drained anything, so the writes never completed.
    /// A mount wedged this way never recovers.
    ///
    /// So: stall one connection, then require an unrelated one to still be
    /// served. Under the bug this test does not fail, it hangs.
    @Test("a peer that stops reading cannot stall the whole server",
          .timeLimit(.minutes(1)))
    func stalledPeerDoesNotBlockOthers() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }

        // Big enough that one reply cannot fit in the socket buffers.
        let content = Self.pattern(1 << 20)
        let created = try await bridge.client.create(bridge.root, "big.bin")
        let handle = try #require(created.handle)
        var written = 0
        while written < content.count {
            let end = min(written + Int(Self.chunk), content.count)
            _ = try await bridge.client.write(
                handle, offset: UInt64(written), data: Array(content[written..<end]))
            written = end
        }

        // A deliberately deaf client: a tiny receive buffer, and it never reads
        // a single reply.
        let deaf = try bridge.connect(receiveBufferSize: 2048)
        // The bridge clamps a READ to the rtmax it advertises, so the way to
        // put megabytes into the socket — enough that the kernel cannot just
        // buffer them and let every write return — is many requests, not one
        // enormous one.
        let info = try #require(try await bridge.client.fsinfo(bridge.root).info)
        let readSize = info.readMaximum
        let requests = max(256, ProcessInfo.processInfo.activeProcessorCount * 32)
        for _ in 0..<requests {
            var e = XDREncoder()
            e.opaqueVariable(handle)
            e.uint64(0)
            e.uint32(readSize)
            _ = try await deaf.connection.send(
                program: NFSConstants.program, version: NFSConstants.version,
                procedure: NFSConstants.procedureRead, arguments: e.bytes)
        }

        // Give the server time to produce those replies and get stuck writing
        // them, so the pool is under whatever pressure the bug would create.
        try await Task.sleep(nanoseconds: 500_000_000)

        let healthy = try bridge.connect()
        let started = Date()
        let attributes = try await healthy.getAttributes(bridge.root)
        #expect(attributes.status == 0)
        #expect(Date().timeIntervalSince(started) < 10)

        deaf.connection.close()
    }
}
