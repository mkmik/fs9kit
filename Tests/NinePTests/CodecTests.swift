import Testing
import Foundation
@testable import NineP

// MARK: - Helpers

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func unhex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var it = s.makeIterator()
    while let a = it.next(), let b = it.next() {
        out.append(UInt8(String([a, b]), radix: 16)!)
    }
    return out
}

// MARK: - Primitives

@Suite("Wire primitives")
struct PrimitiveTests {
    @Test("integers are little-endian")
    func littleEndian() throws {
        var w = ByteWriter()
        w.u8(0x01)
        w.u16(0x0302)
        w.u32(0x0706_0504)
        w.u64(0x0F0E_0D0C_0B0A_0908)
        #expect(hex(w.bytes) == "0102030405060708090a0b0c0d0e0f")

        var r = ByteReader(w.bytes)
        #expect(try r.u8() == 0x01)
        #expect(try r.u16() == 0x0302)
        #expect(try r.u32() == 0x0706_0504)
        #expect(try r.u64() == 0x0F0E_0D0C_0B0A_0908)
        #expect(r.isAtEnd)
    }

    @Test("strings are a two-byte count plus UTF-8, not NUL terminated")
    func strings() throws {
        var w = ByteWriter()
        w.string("hi")
        #expect(hex(w.bytes) == "02006869")

        var w2 = ByteWriter()
        w2.string("héllo")           // é is two UTF-8 bytes: the count is bytes, not characters
        var r2 = ByteReader(w2.bytes)
        #expect(try r2.u16() == 6)

        var r = ByteReader(w2.bytes)
        #expect(try r.string() == "héllo")
    }

    @Test("empty string round-trips")
    func emptyString() throws {
        var w = ByteWriter()
        w.string("")
        #expect(hex(w.bytes) == "0000")
        var r = ByteReader(w.bytes)
        #expect(try r.string() == "")
    }

    @Test("reading past the end throws rather than trapping")
    func truncation() throws {
        var r = ByteReader([0x01, 0x02])
        #expect(throws: NinePWireError.self) { var rr = r; _ = try rr.u32() }
        #expect(try r.u16() == 0x0201)
        #expect(throws: NinePWireError.self) { var rr = r; _ = try rr.u8() }
    }

    @Test("invalid UTF-8 in a string is rejected")
    func invalidUTF8() throws {
        // count=2 followed by a lone continuation byte pair
        var r = ByteReader([0x02, 0x00, 0xC3, 0x28])
        #expect(throws: NinePWireError.invalidUTF8) { var rr = r; _ = try rr.string() }
        _ = r
    }

    @Test("qid is 13 bytes: type, version, path")
    func qidLayout() throws {
        var w = ByteWriter()
        w.qid(Qid(kind: .dir, version: 0x1122_3344, path: 0x8877_6655_4433_2211))
        #expect(w.count == Qid.wireSize)
        #expect(hex(w.bytes) == "80443322111122334455667788")
        var r = ByteReader(w.bytes)
        let q = try r.qid()
        #expect(q.kind == .dir)
        #expect(q.isDir)
        #expect(q.version == 0x1122_3344)
        #expect(q.path == 0x8877_6655_4433_2211)
    }
}

// MARK: - Golden frames

@Suite("Golden wire vectors")
struct GoldenTests {
    /// size[4]=21 type=100 tag=NOTAG msize=8192 version="9P2000.L"
    @Test("Tversion")
    func tversion() throws {
        let codec = MessageCodec(version: .v9P2000L)
        let frame = Frame(tag: P9.notag,
                          message: .tversion(msize: 8192, version: "9P2000.L"))
        let bytes = codec.encode(frame)
        #expect(hex(bytes) == "15000000" + "64" + "ffff" + "00200000" + "0800" + "39503230:30302e4c".replacingOccurrences(of: ":", with: ""))
        #expect(try codec.decode(frame: bytes) == frame)
    }

    /// A Tattach in base 9P2000 has no n_uname; the same message in .L does.
    @Test("Tattach differs between dialects")
    func tattachDialects() throws {
        let msg = Message.tattach(fid: 0, afid: P9.nofid, uname: "glenda",
                                  aname: "", numericUID: 1000)
        let plain = MessageCodec(version: .v9P2000)
        let linux = MessageCodec(version: .v9P2000L)
        let plainBytes = plain.encode(Frame(tag: 1, message: msg))
        let linuxBytes = linux.encode(Frame(tag: 1, message: msg))
        #expect(linuxBytes.count == plainBytes.count + 4)

        // Base 9P2000 drops the numeric uid entirely.
        guard case let .tattach(_, _, _, _, nuid) = try plain.decode(frame: plainBytes).message
        else { Issue.record("wrong message"); return }
        #expect(nuid == nil)

        guard case let .tattach(_, _, _, _, lnuid) = try linux.decode(frame: linuxBytes).message
        else { Issue.record("wrong message"); return }
        #expect(lnuid == 1000)
    }

    @Test("Rread payload is a four-byte count")
    func rread() throws {
        let codec = MessageCodec(version: .v9P2000L)
        let bytes = codec.encode(Frame(tag: 7, message: .rread(data: [0xde, 0xad, 0xbe, 0xef])))
        #expect(hex(bytes) == "0f000000" + "75" + "0700" + "04000000" + "deadbeef")
        #expect(try codec.decode(frame: bytes).message == .rread(data: [0xde, 0xad, 0xbe, 0xef]))
    }

    @Test("Twalk carries a two-byte name count")
    func twalk() throws {
        let codec = MessageCodec(version: .v9P2000L)
        let f = Frame(tag: 2, message: .twalk(fid: 1, newfid: 2, names: ["a", "bb"]))
        let bytes = codec.encode(f)
        #expect(hex(bytes) == "18000000" + "6e" + "0200"
            + "01000000" + "02000000" + "0200" + "010061" + "02006262")
        #expect(try codec.decode(frame: bytes) == f)
    }

    @Test("a walk of more than 16 elements is rejected on decode")
    func walkTooLong() throws {
        let codec = MessageCodec(version: .v9P2000L)
        var w = ByteWriter()
        w.u32(0); w.u8(MessageType.twalk.rawValue); w.u16(1)
        w.u32(1); w.u32(2); w.u16(17)
        for _ in 0..<17 { w.string("x") }
        var bytes = w.bytes
        let size = UInt32(bytes.count)
        bytes[0] = UInt8(truncatingIfNeeded: size)
        bytes[1] = UInt8(truncatingIfNeeded: size >> 8)
        #expect(throws: NinePWireError.self) { _ = try codec.decode(frame: bytes) }
    }
}

// MARK: - Stat

@Suite("stat encoding")
struct StatTests {
    static let sample = Stat(
        qid: Qid(kind: .dir, version: 1, path: 42),
        mode: FileMode(rawValue: FileMode.dir.rawValue | 0o755),
        atime: 1_700_000_000, mtime: 1_700_000_001, length: 0,
        name: "docs", uid: "glenda", gid: "sys", muid: "glenda")

    @Test("stat's own size field counts the bytes after it")
    func selfSize() throws {
        var w = ByteWriter()
        w.stat(Self.sample, dotu: false)
        var r = ByteReader(w.bytes)
        let declared = Int(try r.u16())
        #expect(declared == w.count - 2)
    }

    @Test("Rstat carries the size twice, per stat(5) BUGS")
    func doubleSize() throws {
        let codec = MessageCodec(version: .v9P2000)
        let bytes = codec.encode(Frame(tag: 3, message: .rstat(stat: Self.sample)))
        var r = ByteReader(Array(bytes.dropFirst(P9.headerSize)))
        let outer = Int(try r.u16())
        let inner = Int(try r.u16())
        #expect(outer == inner + 2)
        #expect(outer == bytes.count - P9.headerSize - 2)
        #expect(try codec.decode(frame: bytes).message == .rstat(stat: Self.sample))
    }

    @Test("a server that omits the redundant outer count is still understood")
    func toleratesSingleSize() throws {
        let codec = MessageCodec(version: .v9P2000)
        // Build an Rstat by hand with only the inner size.
        var body = ByteWriter()
        body.stat(Self.sample, dotu: false)
        var w = ByteWriter()
        w.u32(0)
        w.u8(MessageType.rstat.rawValue)
        w.u16(3)
        w.raw(body.bytes)
        var bytes = w.bytes
        let size = UInt32(bytes.count)
        for i in 0..<4 { bytes[i] = UInt8(truncatingIfNeeded: size >> (8 * i)) }
        #expect(try codec.decode(frame: bytes).message == .rstat(stat: Self.sample))
    }

    @Test("9P2000.u adds four fields to every stat")
    func dotuFields() throws {
        var s = Self.sample
        s.extensionString = "/target"
        s.numericUID = 1000
        s.numericGID = 1000
        s.numericMUID = 1000
        let dotu = MessageCodec(version: .v9P2000u)
        let bytes = dotu.encode(Frame(tag: 1, message: .rstat(stat: s)))
        #expect(try dotu.decode(frame: bytes).message == .rstat(stat: s))

        // Decoding those bytes as plain 9P2000 must not silently succeed.
        let plain = MessageCodec(version: .v9P2000)
        #expect(throws: (any Error).self) { _ = try plain.decode(frame: bytes) }
    }

    @Test("noTouch stat is all ones so Twstat leaves fields alone")
    func noTouch() {
        let s = Stat.noTouch()
        #expect(s.mtime == UInt32.max)
        #expect(s.length == UInt64.max)
        #expect(s.name.isEmpty)
    }
}

// MARK: - Round trip over every message

@Suite("Round trip")
struct RoundTripTests {
    static let qid = Qid(kind: .file, version: 3, path: 99)
    static let attr = LinuxAttr(
        valid: .basic, qid: qid, mode: PosixFileType.reg | 0o644, uid: 501, gid: 20,
        nlink: 1, rdev: 0, size: 12345, blockSize: 4096, blocks: 24,
        atimeSec: 1, atimeNsec: 2, mtimeSec: 3, mtimeNsec: 4, ctimeSec: 5, ctimeNsec: 6)

    static func allMessages(for version: NinePVersion) -> [Message] {
        // Base 9P2000 has no n_uname on attach/auth; only 9P2000.u has the
        // Tcreate extension string.
        let numericUID: UInt32? = version == .v9P2000 ? nil : 7
        let ext: String? = version == .v9P2000u ? "" : nil
        return allMessages(numericUID: numericUID, ext: ext)
    }

    static func allMessages(numericUID: UInt32?, ext: String?) -> [Message] {
        [
            .tversion(msize: 65536, version: "9P2000.L"),
            .rversion(msize: 65536, version: "9P2000.L"),
            .tauth(afid: 1, uname: "u", aname: "a", numericUID: numericUID),
            .rauth(aqid: qid),
            .tattach(fid: 0, afid: P9.nofid, uname: "u", aname: "", numericUID: numericUID),
            .rattach(qid: qid),
            .rerror(message: "no such file", errno: ext == nil ? nil : 2),
            .rlerror(errno: 2),
            .tflush(oldtag: 9),
            .rflush,
            .twalk(fid: 1, newfid: 2, names: []),
            .twalk(fid: 1, newfid: 2, names: ["a", "b", "c"]),
            .rwalk(qids: []),
            .rwalk(qids: [qid, qid]),
            .topen(fid: 1, mode: [.rdwr, .trunc]),
            .ropen(qid: qid, iounit: 8192),
            .tcreate(fid: 1, name: "n", perm: FileMode(rawValue: 0o644),
                     mode: .write, extensionString: ext),
            .rcreate(qid: qid, iounit: 0),
            .tread(fid: 1, offset: 4096, count: 8192),
            .rread(data: []),
            .rread(data: Array(repeating: 0xAB, count: 300)),
            .twrite(fid: 1, offset: 0, data: [1, 2, 3]),
            .rwrite(count: 3),
            .tclunk(fid: 1), .rclunk,
            .tremove(fid: 1), .rremove,
            .tstat(fid: 1),
            .rstat(stat: StatTests.sample),
            .twstat(fid: 1, stat: Stat.noTouch()),
            .rwstat,
            .tstatfs(fid: 1),
            .rstatfs(StatFS(type: 0x01021997, bsize: 4096, blocks: 100, bfree: 50,
                            bavail: 50, files: 10, ffree: 5, fsid: 0, namelen: 255)),
            .tlopen(fid: 1, flags: [.rdwr, .trunc]),
            .rlopen(qid: qid, iounit: 0),
            .tlcreate(fid: 1, name: "f", flags: [.wronly, .create], mode: 0o644, gid: 20),
            .rlcreate(qid: qid, iounit: 0),
            .tsymlink(dfid: 1, name: "l", target: "/tmp/x", gid: 20),
            .rsymlink(qid: qid),
            .tmknod(dfid: 1, name: "d", mode: 0o020600, major: 1, minor: 3, gid: 20),
            .rmknod(qid: qid),
            .trename(fid: 1, dfid: 2, name: "new"),
            .rrename,
            .treadlink(fid: 1),
            .rreadlink(target: "../elsewhere"),
            .tgetattr(fid: 1, requestMask: .all),
            .rgetattr(attr),
            .tsetattr(fid: 1, valid: [.mode, .size], mode: 0o600, uid: 0, gid: 0,
                      size: 10, atimeSec: 0, atimeNsec: 0, mtimeSec: 0, mtimeNsec: 0),
            .rsetattr,
            .txattrwalk(fid: 1, newfid: 2, name: "user.foo"),
            .rxattrwalk(size: 17),
            .txattrcreate(fid: 1, name: "user.foo", attrSize: 17, flags: 0),
            .rxattrcreate,
            .treaddir(fid: 1, offset: 0, count: 8192),
            .rreaddir(entries: []),
            .rreaddir(entries: [
                Dirent(qid: qid, offset: 1, type: DirentType.dir, name: "."),
                Dirent(qid: qid, offset: 2, type: DirentType.dir, name: ".."),
                Dirent(qid: qid, offset: 3, type: DirentType.reg, name: "file.txt"),
            ]),
            .tfsync(fid: 1, dataSync: 0),
            .rfsync,
            .tlock(fid: 1, type: LockType.write, flags: LockFlags.block,
                   start: 0, length: 0, procID: 1234, clientID: "fs9kit"),
            .rlock(status: LockStatus.success),
            .tgetlock(fid: 1, type: LockType.read, start: 0, length: 1,
                      procID: 1234, clientID: "fs9kit"),
            .rgetlock(type: LockType.unlock, start: 0, length: 0,
                      procID: 0, clientID: ""),
            .tlink(dfid: 1, fid: 2, name: "hard"),
            .rlink,
            .tmkdir(dfid: 1, name: "sub", mode: 0o755, gid: 20),
            .rmkdir(qid: qid),
            .trenameat(olddirfid: 1, oldname: "a", newdirfid: 2, newname: "b"),
            .rrenameat,
            .tunlinkat(dirfid: 1, name: "gone", flags: UnlinkAtFlags.removeDir),
            .runlinkat,
        ]
    }

    @Test("every message round-trips in 9P2000.L")
    func roundTripLinux() throws {
        let codec = MessageCodec(version: .v9P2000L)
        for (i, m) in Self.allMessages(for: .v9P2000L).enumerated() {
            let frame = Frame(tag: Tag(i % 0xFFFF), message: m)
            let bytes = codec.encode(frame)
            let back = try codec.decode(frame: bytes)
            #expect(back == frame, "round trip failed for \(m.type)")
            #expect(bytes.count == Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
        }
    }

    @Test("every message round-trips in 9P2000.u")
    func roundTripDotU() throws {
        let codec = MessageCodec(version: .v9P2000u)
        for m in Self.allMessages(for: .v9P2000u) {
            let frame = Frame(tag: 1, message: m)
            #expect(try codec.decode(frame: codec.encode(frame)) == frame,
                    "round trip failed for \(m.type)")
        }
    }

    @Test("base 9P2000 round-trips its own messages")
    func roundTripPlain() throws {
        let codec = MessageCodec(version: .v9P2000)
        for m in Self.allMessages(for: .v9P2000) {
            let frame = Frame(tag: 1, message: m)
            #expect(try codec.decode(frame: codec.encode(frame)) == frame,
                    "round trip failed for \(m.type)")
        }
    }

    @Test("truncating any frame by one byte is detected")
    func truncatedFrames() throws {
        let codec = MessageCodec(version: .v9P2000L)
        for m in Self.allMessages(for: .v9P2000L) {
            var bytes = codec.encode(Frame(tag: 1, message: m))
            bytes.removeLast()
            #expect(throws: (any Error).self, "\(m.type) truncation not detected") {
                _ = try codec.decode(frame: bytes)
            }
        }
    }

    @Test("an unknown message type is reported, not ignored")
    func unknownType() {
        let codec = MessageCodec(version: .v9P2000L)
        let bytes: [UInt8] = [7, 0, 0, 0, 0xFE, 1, 0]
        #expect(throws: NinePWireError.unknownMessageType(0xFE)) {
            _ = try codec.decode(frame: bytes)
        }
    }

    @Test("a frame whose declared size disagrees with its length is rejected")
    func badSize() {
        let codec = MessageCodec(version: .v9P2000L)
        var bytes = codec.encode(Frame(tag: 1, message: .rclunk))
        bytes[0] = 99
        #expect(throws: NinePWireError.self) { _ = try codec.decode(frame: bytes) }
    }
}

// MARK: - Constants

@Suite("Protocol constants")
struct ConstantTests {
    @Test("message type codes match the specification")
    func codes() {
        #expect(MessageType.tversion.rawValue == 100)
        #expect(MessageType.rversion.rawValue == 101)
        #expect(MessageType.tattach.rawValue == 104)
        #expect(MessageType.rerror.rawValue == 107)
        #expect(MessageType.twstat.rawValue == 126)
        #expect(MessageType.rlerror.rawValue == 7)
        #expect(MessageType.tstatfs.rawValue == 8)
        #expect(MessageType.tgetattr.rawValue == 24)
        #expect(MessageType.treaddir.rawValue == 40)
        #expect(MessageType.tunlinkat.rawValue == 76)
    }

    @Test("T-messages are even and pair with the next odd R-message")
    func pairing() {
        for t in MessageType.allCases where t.isRequest {
            #expect(MessageType(rawValue: t.rawValue + 1) != nil,
                    "\(t) has no paired reply")
        }
    }

    @Test("reserved values")
    func reserved() {
        #expect(P9.notag == 0xFFFF)
        #expect(P9.nofid == 0xFFFF_FFFF)
        #expect(P9.defaultPort == 564)
    }
}
