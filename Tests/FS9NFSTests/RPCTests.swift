import Testing
import Foundation
import FS9NFS

@Suite("Record marking")
struct RecordMarkingTests {
    @Test("a message split across several fragments is reassembled")
    func multipleFragments() throws {
        var assembler = RPCRecordAssembler()
        let payload = (0..<300).map { UInt8($0 & 0xFF) }

        // Three fragments; only the last carries the end-of-record bit.
        var wire: [UInt8] = []
        var offset = 0
        for size in [100, 100, 100] {
            let isLast = offset + size == payload.count
            var header = UInt32(size)
            if isLast { header |= 0x8000_0000 }
            for shift in stride(from: 24, through: 0, by: -8) {
                wire.append(UInt8(truncatingIfNeeded: header >> UInt32(shift)))
            }
            wire.append(contentsOf: payload[offset..<(offset + size)])
            offset += size
        }

        // Feed it a byte at a time: a header split across two reads is the
        // case that breaks naive implementations.
        var completed: [[UInt8]] = []
        for byte in wire { completed.append(contentsOf: try assembler.push([byte])) }
        #expect(completed.count == 1)
        #expect(completed.first == payload)
    }

    @Test("several pipelined messages in one read are all returned")
    func pipelined() throws {
        var assembler = RPCRecordAssembler()
        let wire = rpcFrame([1, 2, 3, 4]) + rpcFrame([5, 6, 7, 8]) + rpcFrame([])
        let completed = try assembler.push(wire)
        #expect(completed == [[1, 2, 3, 4], [5, 6, 7, 8], []])
    }

    @Test("a reply is framed with the last-fragment bit set")
    func framing() {
        let framed = rpcFrame([0xAA, 0xBB])
        #expect(framed.count == 6)
        #expect(framed[0] == 0x80)
        #expect(framed[1] == 0)
        #expect(framed[2] == 0)
        #expect(framed[3] == 2)
        #expect(Array(framed[4...]) == [0xAA, 0xBB])
    }

    @Test("an oversized fragment is rejected before it is buffered")
    func oversized() {
        var assembler = RPCRecordAssembler(maximumRecordSize: 64)
        var header: [UInt8] = [0x00, 0x00, 0x10, 0x00]  // 4096 bytes, not last
        header.append(contentsOf: [1, 2, 3])
        #expect(throws: RPCFramingError.recordTooLarge(limit: 64)) { _ = try assembler.push(header) }
    }

    @Test("fragments that together exceed the ceiling are rejected")
    func oversizedInAggregate() throws {
        var assembler = RPCRecordAssembler(maximumRecordSize: 64)
        var wire: [UInt8] = []
        for _ in 0..<3 {
            wire.append(contentsOf: [0x00, 0x00, 0x00, 32])  // 32 bytes, not last
            wire.append(contentsOf: [UInt8](repeating: 0, count: 32))
        }
        #expect(throws: RPCFramingError.recordTooLarge(limit: 64)) { _ = try assembler.push(wire) }
    }
}

@Suite("RPC message encoding")
struct RPCMessageTests {
    @Test("a call header decodes into its parts, AUTH_SYS included")
    func decodeCall() throws {
        var credentials = XDREncoder()
        credentials.uint32(42)
        credentials.string("machine")
        credentials.uint32(501)
        credentials.uint32(20)
        credentials.array([UInt32(20), 12]) { $0.uint32($1) }

        var e = XDREncoder()
        e.uint32(0xCAFE_0001)
        e.uint32(0)   // CALL
        e.uint32(2)   // rpcvers
        e.uint32(100_003)
        e.uint32(3)
        e.uint32(1)
        e.uint32(1)   // AUTH_SYS
        e.opaqueVariable(credentials.bytes)
        e.uint32(0)   // verifier flavor
        e.uint32(0)   // verifier body
        e.uint32(0xABCD)

        let call = try RPCMessage.decodeCall(e.bytes, argumentLimit: 4096)
        #expect(call.context.xid == 0xCAFE_0001)
        #expect(call.context.program == 100_003)
        #expect(call.context.version == 3)
        #expect(call.context.procedure == 1)
        #expect(call.context.credentials?.uid == 501)
        #expect(call.context.credentials?.gid == 20)
        #expect(call.context.credentials?.groups == [20, 12])
        #expect(call.context.credentials?.machineName == "machine")
        var arguments = call.arguments
        #expect(try arguments.uint32() == 0xABCD)
    }

    @Test("a call with rpcvers other than 2 is reported with its xid intact")
    func versionMismatch() {
        var e = XDREncoder()
        e.uint32(7)
        e.uint32(0)
        e.uint32(3)
        #expect(throws: RPCDecodeError.versionMismatch(xid: 7, offered: 3)) {
            _ = try RPCMessage.decodeCall(e.bytes, argumentLimit: 64)
        }
    }

    @Test("a reply that is not a call is rejected")
    func notACall() {
        var e = XDREncoder()
        e.uint32(7)
        e.uint32(1)
        #expect(throws: RPCDecodeError.notACall(1)) {
            _ = try RPCMessage.decodeCall(e.bytes, argumentLimit: 64)
        }
    }

    @Test("PROG_MISMATCH carries the supported version range")
    func mismatchReply() throws {
        let reply = try RPCTestConnection.decodeReply(
            RPCMessage.programMismatch(xid: 9, low: 3, high: 3))
        #expect(reply.xid == 9)
        #expect(reply.replyStatus == 0)
        #expect(reply.acceptStatus == 2)
        #expect(reply.low == 3)
        #expect(reply.high == 3)
    }
}

@Suite("RPC dispatch over TCP")
struct RPCDispatchTests {
    @Test("an unknown program gets PROG_UNAVAIL")
    func programUnavailable() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let reply = try await bridge.client.connection.call(
            program: 999_999, version: 1, procedure: 0)
        #expect(reply.replyStatus == 0)
        #expect(reply.acceptStatus == 1)
    }

    @Test("a known program at an unknown version gets PROG_MISMATCH with the real range")
    func programMismatch() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let reply = try await bridge.client.connection.call(
            program: NFSConstants.program, version: 4, procedure: 0)
        #expect(reply.acceptStatus == 2)
        #expect(reply.low == 3)
        #expect(reply.high == 3)

        let mountReply = try await bridge.client.connection.call(
            program: MountConstants.program, version: 1, procedure: 0)
        #expect(mountReply.acceptStatus == 2)
        #expect(mountReply.low == 3)
        #expect(mountReply.high == 3)
    }

    @Test("an unknown procedure gets PROC_UNAVAIL")
    func procedureUnavailable() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let reply = try await bridge.client.connection.call(
            program: NFSConstants.program, version: 3, procedure: 99)
        #expect(reply.acceptStatus == 3)

        let mountReply = try await bridge.client.connection.call(
            program: MountConstants.program, version: 3, procedure: 99)
        #expect(mountReply.acceptStatus == 3)
    }

    @Test("NULL succeeds with an empty result on both programs")
    func nullProcedures() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let nfs = try await bridge.client.connection.call(
            program: NFSConstants.program, version: 3, procedure: 0)
        #expect(nfs.isSuccess)
        #expect(nfs.results.isEmpty)

        let mount = try await bridge.client.connection.call(
            program: MountConstants.program, version: 3, procedure: 0)
        #expect(mount.isSuccess)
        #expect(mount.results.isEmpty)
    }

    @Test("the xid is echoed exactly, including one with the top bit set")
    func xidEcho() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        for xid: UInt32 in [0, 1, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF] {
            _ = try await bridge.client.connection.send(
                program: NFSConstants.program, version: 3, procedure: 0, xid: xid)
            let reply = try await bridge.client.connection.receive()
            #expect(reply.xid == xid)
        }
    }

    @Test("a call with rpcvers other than 2 is denied with RPC_MISMATCH")
    func rpcVersionMismatch() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        var e = XDREncoder()
        e.uint32(0x7777)
        e.uint32(0)  // CALL
        e.uint32(3)  // rpcvers: not 2
        e.uint32(NFSConstants.program)
        e.uint32(3)
        e.uint32(0)
        try await bridge.client.connection.sendRaw(bridge.client.connection.frame(e.bytes))
        let reply = try await bridge.client.connection.receive()
        #expect(reply.xid == 0x7777)
        #expect(reply.replyStatus == 1)   // MSG_DENIED
        #expect(reply.rejectStatus == 0)  // RPC_MISMATCH
        #expect(reply.low == 2)
        #expect(reply.high == 2)
    }

    @Test("garbage arguments produce GARBAGE_ARGS, not a dropped connection")
    func garbageArguments() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        // LOOKUP with a file handle whose declared length runs off the end.
        let arguments: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0]
        let reply = try await bridge.client.connection.call(
            program: NFSConstants.program, version: 3,
            procedure: NFSConstants.procedureLookup, arguments: arguments)
        #expect(reply.acceptStatus == 4)

        // And the connection still works afterwards.
        let ping = try await bridge.client.connection.call(
            program: NFSConstants.program, version: 3, procedure: 0)
        #expect(ping.isSuccess)
    }

    @Test("a call split across fragments is served normally")
    func fragmentedCall() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let connection = bridge.client.connection
        let payload = connection.encodeCall(
            xid: 0x5151, program: NFSConstants.program, version: 3,
            procedure: NFSConstants.procedureGetAttr,
            arguments: NFSTestClient.handleArgument(bridge.root))
        try await connection.sendRaw(connection.fragmented(payload, pieces: 4))
        let reply = try await connection.receive()
        #expect(reply.xid == 0x5151)
        #expect(reply.isSuccess)
        var d = reply.decoder
        #expect(try d.uint32() == 0)
    }

    @Test("an oversized record closes the connection instead of wedging it")
    func oversizedRecord() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        let victim = try bridge.connect()
        // Declare a fragment far larger than the server's ceiling.
        try await victim.connection.sendRaw([0x7F, 0xFF, 0xFF, 0xFF])
        let closed = await victim.connection.expectEOF()
        #expect(closed)

        // Other connections are unaffected: the ceiling is per connection.
        let reply = try await bridge.client.connection.call(
            program: NFSConstants.program, version: 3, procedure: 0)
        #expect(reply.isSuccess)
    }
}

@Suite("Concurrency")
struct RPCConcurrencyTests {
    @Test("many overlapping calls on one connection all get their own reply")
    func pipelinedRequests() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        for i in 0..<8 {
            try bridge.fileSystem.addFile("/file\(i)", text: String(repeating: "x", count: i))
        }
        let connection = bridge.client.connection

        // Send everything before reading anything, so the server has many calls
        // outstanding at once and is free to answer them out of order.
        var expected: [UInt32: String] = [:]
        for i in 0..<8 {
            let name = "file\(i)"
            let xid = try await connection.send(
                program: NFSConstants.program, version: 3,
                procedure: NFSConstants.procedureLookup,
                arguments: NFSTestClient.directoryOperation(bridge.root, name))
            expected[xid] = name
        }
        // Interleave NULLs so replies of very different sizes are in flight.
        for _ in 0..<8 {
            let xid = try await connection.send(
                program: NFSConstants.program, version: 3, procedure: 0)
            expected[xid] = ""
        }

        var seen: Set<UInt32> = []
        for _ in 0..<16 {
            let reply = try await connection.receive()
            #expect(expected[reply.xid] != nil, "unexpected xid \(reply.xid)")
            #expect(!seen.contains(reply.xid), "duplicate reply for \(reply.xid)")
            seen.insert(reply.xid)
            #expect(reply.isSuccess)
            guard let name = expected[reply.xid], !name.isEmpty else { continue }
            var d = reply.decoder
            #expect(try d.uint32() == 0, "LOOKUP of \(name) failed")
            let handle = try d.opaqueVariable(limit: 64)
            let attributes = try TestAttributes.decodePostOp(&d)
            #expect(handle.count == NFSFileHandle.encodedSize)
            // The size proves the reply belongs to the file this xid asked
            // about, not merely that some reply arrived.
            #expect(attributes?.size == UInt64(name.dropFirst(4)) ?? 0)
        }
        #expect(seen.count == 16)
    }

    @Test("several connections are served at once")
    func multipleConnections() async throws {
        let bridge = try await TestBridge.start()
        defer { bridge.tearDown() }
        try bridge.fileSystem.addFile("/shared", text: "hello")

        var clients: [NFSTestClient] = []
        for _ in 0..<4 { clients.append(try bridge.connect()) }
        for client in clients {
            let mounted = try await client.mountRoot()
            #expect(mounted.status == 0)
            let found = try await client.lookup(mounted.handle, "shared")
            #expect(found.status == 0)
            #expect(found.attributes?.size == 5)
        }
    }
}
