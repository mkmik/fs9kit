// An NFSv3 + MOUNTv3 client for the tests: encodes real arguments, decodes
// real replies, and asserts nothing itself.

import Foundation
import FS9NFS

struct TestTime: Equatable {
    var seconds: UInt32
    var nanoseconds: UInt32
}

struct TestAttributes: Equatable {
    var type: UInt32
    var mode: UInt32
    var linkCount: UInt32
    var uid: UInt32
    var gid: UInt32
    var size: UInt64
    var used: UInt64
    var rdevMajor: UInt32
    var rdevMinor: UInt32
    var fsid: UInt64
    var fileID: UInt64
    var accessTime: TestTime
    var modifyTime: TestTime
    var changeTime: TestTime

    static func decode(_ d: inout XDRDecoder) throws -> TestAttributes {
        TestAttributes(
            type: try d.uint32(), mode: try d.uint32(), linkCount: try d.uint32(),
            uid: try d.uint32(), gid: try d.uint32(),
            size: try d.uint64(), used: try d.uint64(),
            rdevMajor: try d.uint32(), rdevMinor: try d.uint32(),
            fsid: try d.uint64(), fileID: try d.uint64(),
            accessTime: try decodeTime(&d), modifyTime: try decodeTime(&d),
            changeTime: try decodeTime(&d))
    }

    static func decodeTime(_ d: inout XDRDecoder) throws -> TestTime {
        TestTime(seconds: try d.uint32(), nanoseconds: try d.uint32())
    }

    static func decodePostOp(_ d: inout XDRDecoder) throws -> TestAttributes? {
        try d.bool() ? try decode(&d) : nil
    }

    /// `wcc_data`: the before-image (size, mtime, ctime) then the after-image.
    static func skipWcc(_ d: inout XDRDecoder) throws -> (before: UInt64?, after: TestAttributes?) {
        var before: UInt64?
        if try d.bool() {
            before = try d.uint64()
            _ = try decodeTime(&d)
            _ = try decodeTime(&d)
        }
        return (before, try decodePostOp(&d))
    }
}

/// The optional fields of a `sattr3`, in the shape a test wants to write them.
struct TestSetAttributes {
    var mode: UInt32?
    var uid: UInt32?
    var gid: UInt32?
    var size: UInt64?
    /// nil means DONT_CHANGE; `.some(nil)` means SET_TO_SERVER_TIME.
    var accessTime: TestTime??
    var modifyTime: TestTime??

    init(mode: UInt32? = nil, uid: UInt32? = nil, gid: UInt32? = nil, size: UInt64? = nil,
         accessTime: TestTime?? = nil, modifyTime: TestTime?? = nil) {
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.size = size
        self.accessTime = accessTime
        self.modifyTime = modifyTime
    }

    func encode(into e: inout XDREncoder) {
        e.optional(mode) { $0.uint32($1) }
        e.optional(uid) { $0.uint32($1) }
        e.optional(gid) { $0.uint32($1) }
        e.optional(size) { $0.uint64($1) }
        for how in [accessTime, modifyTime] {
            switch how {
            case .none: e.uint32(0)                       // DONT_CHANGE
            case .some(.none): e.uint32(1)                // SET_TO_SERVER_TIME
            case let .some(.some(time)):
                e.uint32(2)                               // SET_TO_CLIENT_TIME
                e.uint32(time.seconds)
                e.uint32(time.nanoseconds)
            }
        }
    }
}

struct TestDirectoryEntry: Equatable {
    var fileID: UInt64
    var name: String
    var cookie: UInt64
    var handle: [UInt8]?
    var hasAttributes: Bool
}

struct TestDirectoryPage {
    var status: UInt32
    var verifier: [UInt8]
    var entries: [TestDirectoryEntry]
    var eof: Bool
}

/// Typed wrappers around the two programs.
struct NFSTestClient {
    let connection: RPCTestConnection

    static let nfs = NFSConstants.program
    static let nfsVersion = NFSConstants.version
    static let mount = MountConstants.program
    static let mountVersion = MountConstants.version

    func nfsCall(_ procedure: UInt32, _ arguments: [UInt8] = []) async throws -> XDRDecoder {
        let reply = try await connection.call(
            program: Self.nfs, version: Self.nfsVersion,
            procedure: procedure, arguments: arguments)
        guard reply.isSuccess else {
            throw RPCTestError.malformed("RPC rejected: accept=\(reply.acceptStatus ?? 99)")
        }
        return reply.decoder
    }

    static func handleArgument(_ handle: [UInt8]) -> [UInt8] {
        var e = XDREncoder()
        e.opaqueVariable(handle)
        return e.bytes
    }

    static func directoryOperation(_ handle: [UInt8], _ name: String) -> [UInt8] {
        var e = XDREncoder()
        e.opaqueVariable(handle)
        e.string(name)
        return e.bytes
    }

    // MARK: MOUNT

    func mountRoot(path: String = "/") async throws -> (status: UInt32, handle: [UInt8], flavors: [UInt32]) {
        var e = XDREncoder()
        e.string(path)
        let reply = try await connection.call(
            program: Self.mount, version: Self.mountVersion,
            procedure: MountConstants.procedureMount, arguments: e.bytes)
        var d = reply.decoder
        let status = try d.uint32()
        guard status == 0 else { return (status, [], []) }
        let handle = try d.opaqueVariable(limit: 64)
        let flavors = try d.array(limit: 8) { try $0.uint32() }
        return (status, handle, flavors)
    }

    func unmount(path: String = "/") async throws {
        var e = XDREncoder()
        e.string(path)
        _ = try await connection.call(
            program: Self.mount, version: Self.mountVersion,
            procedure: MountConstants.procedureUnmount, arguments: e.bytes)
    }

    func mountDump() async throws -> [(host: String, directory: String)] {
        let reply = try await connection.call(
            program: Self.mount, version: Self.mountVersion,
            procedure: MountConstants.procedureDump)
        var d = reply.decoder
        var out: [(String, String)] = []
        while try d.bool() {
            out.append((try d.string(limit: 255), try d.string(limit: 1024)))
        }
        return out
    }

    func exports() async throws -> [String] {
        let reply = try await connection.call(
            program: Self.mount, version: Self.mountVersion,
            procedure: MountConstants.procedureExport)
        var d = reply.decoder
        var out: [String] = []
        while try d.bool() {
            out.append(try d.string(limit: 1024))
            while try d.bool() { _ = try d.string(limit: 255) }
        }
        return out
    }

    // MARK: NFS

    func getAttributes(_ handle: [UInt8]) async throws -> (status: UInt32, attributes: TestAttributes?) {
        var d = try await nfsCall(NFSConstants.procedureGetAttr, Self.handleArgument(handle))
        let status = try d.uint32()
        return (status, status == 0 ? try TestAttributes.decode(&d) : nil)
    }

    func setAttributes(
        _ handle: [UInt8], _ requested: TestSetAttributes, guardTime: TestTime? = nil
    ) async throws -> (status: UInt32, after: TestAttributes?) {
        var e = XDREncoder()
        e.opaqueVariable(handle)
        requested.encode(into: &e)
        if let guardTime {
            e.bool(true)
            e.uint32(guardTime.seconds)
            e.uint32(guardTime.nanoseconds)
        } else {
            e.bool(false)
        }
        var d = try await nfsCall(NFSConstants.procedureSetAttr, e.bytes)
        let status = try d.uint32()
        let wcc = try TestAttributes.skipWcc(&d)
        return (status, wcc.after)
    }

    func lookup(_ directory: [UInt8], _ name: String) async throws
    -> (status: UInt32, handle: [UInt8]?, attributes: TestAttributes?) {
        var d = try await nfsCall(
            NFSConstants.procedureLookup, Self.directoryOperation(directory, name))
        let status = try d.uint32()
        guard status == 0 else { return (status, nil, nil) }
        let handle = try d.opaqueVariable(limit: 64)
        let attributes = try TestAttributes.decodePostOp(&d)
        return (status, handle, attributes)
    }

    func access(_ handle: [UInt8], _ mask: UInt32) async throws -> (status: UInt32, granted: UInt32) {
        var e = XDREncoder()
        e.opaqueVariable(handle)
        e.uint32(mask)
        var d = try await nfsCall(NFSConstants.procedureAccess, e.bytes)
        let status = try d.uint32()
        guard status == 0 else { return (status, 0) }
        _ = try TestAttributes.decodePostOp(&d)
        return (status, try d.uint32())
    }

    func readlink(_ handle: [UInt8]) async throws -> (status: UInt32, target: String?) {
        var d = try await nfsCall(NFSConstants.procedureReadlink, Self.handleArgument(handle))
        let status = try d.uint32()
        guard status == 0 else { return (status, nil) }
        _ = try TestAttributes.decodePostOp(&d)
        return (status, try d.string(limit: 1024))
    }

    func read(_ handle: [UInt8], offset: UInt64, count: UInt32) async throws
    -> (status: UInt32, data: [UInt8], eof: Bool) {
        var e = XDREncoder()
        e.opaqueVariable(handle)
        e.uint64(offset)
        e.uint32(count)
        var d = try await nfsCall(NFSConstants.procedureRead, e.bytes)
        let status = try d.uint32()
        guard status == 0 else { return (status, [], false) }
        _ = try TestAttributes.decodePostOp(&d)
        let reported = try d.uint32()
        let eof = try d.bool()
        let data = try d.opaqueVariable(limit: 1 << 20)
        guard Int(reported) == data.count else {
            throw RPCTestError.malformed("READ count \(reported) != data \(data.count)")
        }
        return (status, data, eof)
    }

    func write(_ handle: [UInt8], offset: UInt64, data: [UInt8], stable: UInt32 = 2) async throws
    -> (status: UInt32, count: UInt32, committed: UInt32, verifier: [UInt8]) {
        var e = XDREncoder()
        e.opaqueVariable(handle)
        e.uint64(offset)
        e.uint32(UInt32(data.count))
        e.uint32(stable)
        e.opaqueVariable(data)
        var d = try await nfsCall(NFSConstants.procedureWrite, e.bytes)
        let status = try d.uint32()
        _ = try TestAttributes.skipWcc(&d)
        guard status == 0 else { return (status, 0, 0, []) }
        return (status, try d.uint32(), try d.uint32(), try d.opaqueFixed(8))
    }

    /// `how`: 0 UNCHECKED, 1 GUARDED, 2 EXCLUSIVE.
    func create(_ directory: [UInt8], _ name: String, how: UInt32 = 0,
                attributes: TestSetAttributes = TestSetAttributes(),
                verifier: [UInt8] = []) async throws
    -> (status: UInt32, handle: [UInt8]?, attributes: TestAttributes?) {
        var e = XDREncoder()
        e.opaqueVariable(directory)
        e.string(name)
        e.uint32(how)
        if how == 2 {
            e.opaqueFixed(verifier.isEmpty ? [UInt8](repeating: 7, count: 8) : verifier)
        } else {
            attributes.encode(into: &e)
        }
        return try await decodeCreation(NFSConstants.procedureCreate, e.bytes)
    }

    func mkdir(_ directory: [UInt8], _ name: String,
               attributes: TestSetAttributes = TestSetAttributes(mode: 0o755)) async throws
    -> (status: UInt32, handle: [UInt8]?, attributes: TestAttributes?) {
        var e = XDREncoder()
        e.opaqueVariable(directory)
        e.string(name)
        attributes.encode(into: &e)
        return try await decodeCreation(NFSConstants.procedureMkdir, e.bytes)
    }

    func symlink(_ directory: [UInt8], _ name: String, target: String) async throws
    -> (status: UInt32, handle: [UInt8]?, attributes: TestAttributes?) {
        var e = XDREncoder()
        e.opaqueVariable(directory)
        e.string(name)
        TestSetAttributes(mode: 0o777).encode(into: &e)
        e.string(target)
        return try await decodeCreation(NFSConstants.procedureSymlink, e.bytes)
    }

    func mknod(_ directory: [UInt8], _ name: String) async throws
    -> (status: UInt32, handle: [UInt8]?, attributes: TestAttributes?) {
        var e = XDREncoder()
        e.opaqueVariable(directory)
        e.string(name)
        e.uint32(3)  // NF3BLK
        e.uint32(0)  // no attributes
        e.uint32(0)
        e.uint32(0)
        e.uint32(0)
        e.uint32(0)
        e.uint32(0)
        e.uint32(8)  // major
        e.uint32(1)  // minor
        return try await decodeCreation(NFSConstants.procedureMknod, e.bytes)
    }

    private func decodeCreation(_ procedure: UInt32, _ arguments: [UInt8]) async throws
    -> (status: UInt32, handle: [UInt8]?, attributes: TestAttributes?) {
        var d = try await nfsCall(procedure, arguments)
        let status = try d.uint32()
        guard status == 0 else {
            _ = try TestAttributes.skipWcc(&d)
            return (status, nil, nil)
        }
        let handle = try d.bool() ? try d.opaqueVariable(limit: 64) : nil
        let attributes = try TestAttributes.decodePostOp(&d)
        _ = try TestAttributes.skipWcc(&d)
        return (status, handle, attributes)
    }

    func remove(_ directory: [UInt8], _ name: String) async throws -> UInt32 {
        var d = try await nfsCall(
            NFSConstants.procedureRemove, Self.directoryOperation(directory, name))
        return try d.uint32()
    }

    func rmdir(_ directory: [UInt8], _ name: String) async throws -> UInt32 {
        var d = try await nfsCall(
            NFSConstants.procedureRmdir, Self.directoryOperation(directory, name))
        return try d.uint32()
    }

    func rename(_ from: [UInt8], _ fromName: String, _ to: [UInt8], _ toName: String) async throws -> UInt32 {
        var e = XDREncoder()
        e.opaqueVariable(from)
        e.string(fromName)
        e.opaqueVariable(to)
        e.string(toName)
        var d = try await nfsCall(NFSConstants.procedureRename, e.bytes)
        return try d.uint32()
    }

    func link(_ file: [UInt8], to directory: [UInt8], name: String) async throws -> UInt32 {
        var e = XDREncoder()
        e.opaqueVariable(file)
        e.opaqueVariable(directory)
        e.string(name)
        var d = try await nfsCall(NFSConstants.procedureLink, e.bytes)
        return try d.uint32()
    }

    func readdir(_ directory: [UInt8], cookie: UInt64 = 0,
                 verifier: [UInt8] = [UInt8](repeating: 0, count: 8),
                 count: UInt32 = 8192) async throws -> TestDirectoryPage {
        var e = XDREncoder()
        e.opaqueVariable(directory)
        e.uint64(cookie)
        e.opaqueFixed(verifier)
        e.uint32(count)
        var d = try await nfsCall(NFSConstants.procedureReaddir, e.bytes)
        let status = try d.uint32()
        guard status == 0 else { return TestDirectoryPage(status: status, verifier: [], entries: [], eof: false) }
        _ = try TestAttributes.decodePostOp(&d)
        let verf = try d.opaqueFixed(8)
        var entries: [TestDirectoryEntry] = []
        while try d.bool() {
            entries.append(TestDirectoryEntry(
                fileID: try d.uint64(), name: try d.string(limit: 255),
                cookie: try d.uint64(), handle: nil, hasAttributes: false))
        }
        return TestDirectoryPage(status: status, verifier: verf, entries: entries, eof: try d.bool())
    }

    func readdirPlus(_ directory: [UInt8], cookie: UInt64 = 0,
                     verifier: [UInt8] = [UInt8](repeating: 0, count: 8),
                     dircount: UInt32 = 4096, maxcount: UInt32 = 32768) async throws -> TestDirectoryPage {
        var e = XDREncoder()
        e.opaqueVariable(directory)
        e.uint64(cookie)
        e.opaqueFixed(verifier)
        e.uint32(dircount)
        e.uint32(maxcount)
        var d = try await nfsCall(NFSConstants.procedureReaddirPlus, e.bytes)
        let status = try d.uint32()
        guard status == 0 else { return TestDirectoryPage(status: status, verifier: [], entries: [], eof: false) }
        _ = try TestAttributes.decodePostOp(&d)
        let verf = try d.opaqueFixed(8)
        var entries: [TestDirectoryEntry] = []
        while try d.bool() {
            let fileID = try d.uint64()
            let name = try d.string(limit: 255)
            let cookie = try d.uint64()
            let attributes = try TestAttributes.decodePostOp(&d)
            let handle = try d.bool() ? try d.opaqueVariable(limit: 64) : nil
            entries.append(TestDirectoryEntry(
                fileID: fileID, name: name, cookie: cookie,
                handle: handle, hasAttributes: attributes != nil))
        }
        return TestDirectoryPage(status: status, verifier: verf, entries: entries, eof: try d.bool())
    }

    func fsstat(_ handle: [UInt8]) async throws
    -> (status: UInt32, totalBytes: UInt64, freeBytes: UInt64, availableBytes: UInt64,
        totalFiles: UInt64, invariantSeconds: UInt32) {
        var d = try await nfsCall(NFSConstants.procedureFsstat, Self.handleArgument(handle))
        let status = try d.uint32()
        guard status == 0 else { return (status, 0, 0, 0, 0, 0) }
        _ = try TestAttributes.decodePostOp(&d)
        let total = try d.uint64()
        let free = try d.uint64()
        let available = try d.uint64()
        let files = try d.uint64()
        _ = try d.uint64()
        _ = try d.uint64()
        return (status, total, free, available, files, try d.uint32())
    }

    struct TestFSInfo {
        var readMaximum: UInt32
        var readPreferred: UInt32
        var readMultiple: UInt32
        var writeMaximum: UInt32
        var writePreferred: UInt32
        var writeMultiple: UInt32
        var directoryPreferred: UInt32
        var maximumFileSize: UInt64
        var timeDelta: TestTime
        var properties: UInt32
    }

    func fsinfo(_ handle: [UInt8]) async throws -> (status: UInt32, info: TestFSInfo?) {
        var d = try await nfsCall(NFSConstants.procedureFsinfo, Self.handleArgument(handle))
        let status = try d.uint32()
        guard status == 0 else { return (status, nil) }
        _ = try TestAttributes.decodePostOp(&d)
        return (status, TestFSInfo(
            readMaximum: try d.uint32(), readPreferred: try d.uint32(), readMultiple: try d.uint32(),
            writeMaximum: try d.uint32(), writePreferred: try d.uint32(), writeMultiple: try d.uint32(),
            directoryPreferred: try d.uint32(), maximumFileSize: try d.uint64(),
            timeDelta: try TestAttributes.decodeTime(&d), properties: try d.uint32()))
    }

    func pathconf(_ handle: [UInt8]) async throws
    -> (status: UInt32, linkMaximum: UInt32, nameMaximum: UInt32, noTruncate: Bool,
        chownRestricted: Bool, caseInsensitive: Bool, casePreserving: Bool) {
        var d = try await nfsCall(NFSConstants.procedurePathconf, Self.handleArgument(handle))
        let status = try d.uint32()
        guard status == 0 else { return (status, 0, 0, false, false, false, false) }
        _ = try TestAttributes.decodePostOp(&d)
        return (status, try d.uint32(), try d.uint32(), try d.bool(),
                try d.bool(), try d.bool(), try d.bool())
    }

    func commit(_ handle: [UInt8], offset: UInt64 = 0, count: UInt32 = 0) async throws
    -> (status: UInt32, verifier: [UInt8]) {
        var e = XDREncoder()
        e.opaqueVariable(handle)
        e.uint64(offset)
        e.uint32(count)
        var d = try await nfsCall(NFSConstants.procedureCommit, e.bytes)
        let status = try d.uint32()
        _ = try TestAttributes.skipWcc(&d)
        guard status == 0 else { return (status, []) }
        return (status, try d.opaqueFixed(8))
    }
}
