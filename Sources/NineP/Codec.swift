import Foundation

/// Encodes and decodes 9P frames for a particular negotiated dialect.
///
/// A few messages differ between dialects — Tattach/Tauth carry `n_uname` in
/// 9P2000.u and 9P2000.L but not in base 9P2000, Tcreate carries an extension
/// string only in 9P2000.u, and stat structures carry the four Unix fields only
/// in 9P2000.u — so the codec has to know which version was agreed.
public struct MessageCodec: Sendable {
    public var version: NinePVersion

    public init(version: NinePVersion = .v9P2000L) {
        self.version = version
    }

    /// True when Tattach/Tauth carry a trailing numeric uid.
    private var hasNumericUname: Bool {
        version == .v9P2000u || version == .v9P2000L
    }

    /// True when stat structures and Tcreate carry the 9P2000.u extension fields.
    private var dotu: Bool { version == .v9P2000u }

    // MARK: - Encoding

    /// Encodes a frame, including the leading four-byte size.
    public func encode(_ frame: Frame) -> [UInt8] {
        var w = ByteWriter(reserving: 64)
        w.u32(0) // size placeholder
        w.u8(frame.message.type.rawValue)
        w.u16(frame.tag)
        encodeBody(frame.message, into: &w)
        w.patchU32(at: 0, UInt32(w.count))
        return w.bytes
    }

    private func encodeBody(_ m: Message, into w: inout ByteWriter) {
        switch m {
        case let .tversion(msize, version):
            w.u32(msize); w.string(version)
        case let .rversion(msize, version):
            w.u32(msize); w.string(version)

        case let .tauth(afid, uname, aname, nuid):
            w.u32(afid); w.string(uname); w.string(aname)
            if hasNumericUname { w.u32(nuid ?? UInt32.max) }
        case let .rauth(aqid):
            w.qid(aqid)

        case let .tattach(fid, afid, uname, aname, nuid):
            w.u32(fid); w.u32(afid); w.string(uname); w.string(aname)
            if hasNumericUname { w.u32(nuid ?? UInt32.max) }
        case let .rattach(qid):
            w.qid(qid)

        case let .rerror(message, errno):
            w.string(message)
            if dotu { w.u32(errno ?? 0) }
        case let .rlerror(errno):
            w.u32(errno)

        case let .tflush(oldtag):
            w.u16(oldtag)
        case .rflush:
            break

        case let .twalk(fid, newfid, names):
            w.u32(fid); w.u32(newfid); w.u16(UInt16(names.count))
            for n in names { w.string(n) }
        case let .rwalk(qids):
            w.u16(UInt16(qids.count))
            for q in qids { w.qid(q) }

        case let .topen(fid, mode):
            w.u32(fid); w.u8(mode.rawValue)
        case let .ropen(qid, iounit):
            w.qid(qid); w.u32(iounit)

        case let .tcreate(fid, name, perm, mode, ext):
            w.u32(fid); w.string(name); w.u32(perm.rawValue); w.u8(mode.rawValue)
            if dotu { w.string(ext ?? "") }
        case let .rcreate(qid, iounit):
            w.qid(qid); w.u32(iounit)

        case let .tread(fid, offset, count):
            w.u32(fid); w.u64(offset); w.u32(count)
        case let .rread(data):
            w.u32PrefixedBytes(data)

        case let .twrite(fid, offset, data):
            w.u32(fid); w.u64(offset); w.u32PrefixedBytes(data)
        case let .rwrite(count):
            w.u32(count)

        case let .tclunk(fid):
            w.u32(fid)
        case .rclunk:
            break
        case let .tremove(fid):
            w.u32(fid)
        case .rremove:
            break

        case let .tstat(fid):
            w.u32(fid)
        case let .rstat(stat):
            // The stat is wrapped in its own two-byte count, so the size
            // appears twice. See stat(5) BUGS.
            writeWrappedStat(stat, into: &w)
        case let .twstat(fid, stat):
            w.u32(fid)
            writeWrappedStat(stat, into: &w)
        case .rwstat:
            break

        // MARK: 9P2000.L
        case let .tstatfs(fid):
            w.u32(fid)
        case let .rstatfs(s):
            w.u32(s.type); w.u32(s.bsize); w.u64(s.blocks); w.u64(s.bfree)
            w.u64(s.bavail); w.u64(s.files); w.u64(s.ffree); w.u64(s.fsid); w.u32(s.namelen)

        case let .tlopen(fid, flags):
            w.u32(fid); w.u32(flags.rawValue)
        case let .rlopen(qid, iounit):
            w.qid(qid); w.u32(iounit)

        case let .tlcreate(fid, name, flags, mode, gid):
            w.u32(fid); w.string(name); w.u32(flags.rawValue); w.u32(mode); w.u32(gid)
        case let .rlcreate(qid, iounit):
            w.qid(qid); w.u32(iounit)

        case let .tsymlink(dfid, name, target, gid):
            w.u32(dfid); w.string(name); w.string(target); w.u32(gid)
        case let .rsymlink(qid):
            w.qid(qid)

        case let .tmknod(dfid, name, mode, major, minor, gid):
            w.u32(dfid); w.string(name); w.u32(mode); w.u32(major); w.u32(minor); w.u32(gid)
        case let .rmknod(qid):
            w.qid(qid)

        case let .trename(fid, dfid, name):
            w.u32(fid); w.u32(dfid); w.string(name)
        case .rrename:
            break

        case let .treadlink(fid):
            w.u32(fid)
        case let .rreadlink(target):
            w.string(target)

        case let .tgetattr(fid, mask):
            w.u32(fid); w.u64(mask.rawValue)
        case let .rgetattr(a):
            w.u64(a.valid.rawValue); w.qid(a.qid); w.u32(a.mode); w.u32(a.uid); w.u32(a.gid)
            w.u64(a.nlink); w.u64(a.rdev); w.u64(a.size); w.u64(a.blockSize); w.u64(a.blocks)
            w.u64(a.atimeSec); w.u64(a.atimeNsec); w.u64(a.mtimeSec); w.u64(a.mtimeNsec)
            w.u64(a.ctimeSec); w.u64(a.ctimeNsec); w.u64(a.btimeSec); w.u64(a.btimeNsec)
            w.u64(a.gen); w.u64(a.dataVersion)

        case let .tsetattr(fid, valid, mode, uid, gid, size, atS, atN, mtS, mtN):
            w.u32(fid); w.u32(valid.rawValue); w.u32(mode); w.u32(uid); w.u32(gid)
            w.u64(size); w.u64(atS); w.u64(atN); w.u64(mtS); w.u64(mtN)
        case .rsetattr:
            break

        case let .txattrwalk(fid, newfid, name):
            w.u32(fid); w.u32(newfid); w.string(name)
        case let .rxattrwalk(size):
            w.u64(size)

        case let .txattrcreate(fid, name, attrSize, flags):
            w.u32(fid); w.string(name); w.u64(attrSize); w.u32(flags)
        case .rxattrcreate:
            break

        case let .treaddir(fid, offset, count):
            w.u32(fid); w.u64(offset); w.u32(count)
        case let .rreaddir(entries):
            var inner = ByteWriter(reserving: 256)
            for e in entries {
                inner.qid(e.qid)
                inner.u64(e.offset)
                inner.u8(e.type)
                inner.string(e.name)
            }
            w.u32PrefixedBytes(inner.bytes)

        case let .tfsync(fid, dataSync):
            w.u32(fid); w.u32(dataSync)
        case .rfsync:
            break

        case let .tlock(fid, type, flags, start, length, procID, clientID):
            w.u32(fid); w.u8(type); w.u32(flags); w.u64(start); w.u64(length)
            w.u32(procID); w.string(clientID)
        case let .rlock(status):
            w.u8(status)

        case let .tgetlock(fid, type, start, length, procID, clientID):
            w.u32(fid); w.u8(type); w.u64(start); w.u64(length); w.u32(procID); w.string(clientID)
        case let .rgetlock(type, start, length, procID, clientID):
            w.u8(type); w.u64(start); w.u64(length); w.u32(procID); w.string(clientID)

        case let .tlink(dfid, fid, name):
            w.u32(dfid); w.u32(fid); w.string(name)
        case .rlink:
            break

        case let .tmkdir(dfid, name, mode, gid):
            w.u32(dfid); w.string(name); w.u32(mode); w.u32(gid)
        case let .rmkdir(qid):
            w.qid(qid)

        case let .trenameat(olddirfid, oldname, newdirfid, newname):
            w.u32(olddirfid); w.string(oldname); w.u32(newdirfid); w.string(newname)
        case .rrenameat:
            break

        case let .tunlinkat(dirfid, name, flags):
            w.u32(dirfid); w.string(name); w.u32(flags)
        case .runlinkat:
            break
        }
    }

    /// Writes `n[2]` followed by a stat structure that itself starts with
    /// `size[2] == n - 2`.
    private func writeWrappedStat(_ stat: Stat, into w: inout ByteWriter) {
        let outerOffset = w.count
        w.u16(0)
        let start = w.count
        w.stat(stat, dotu: dotu)
        w.patchU16(at: outerOffset, UInt16(w.count - start))
    }

    // MARK: - Decoding

    /// Decodes one complete frame, including its leading four-byte size.
    ///
    /// - Parameter bytes: exactly one frame; extra trailing bytes are an error.
    public func decode(frame bytes: [UInt8]) throws -> Frame {
        var r = ByteReader(bytes)
        let size = try r.u32()
        guard Int(size) == bytes.count, size >= UInt32(NineP.headerSize) else {
            throw NinePWireError.invalidFrameSize(size)
        }
        let typeByte = try r.u8()
        guard let type = MessageType(rawValue: typeByte) else {
            throw NinePWireError.unknownMessageType(typeByte)
        }
        let tag = try r.u16()
        let message = try decodeBody(type: type, from: &r)
        try r.expectEmpty()
        return Frame(tag: tag, message: message)
    }

    /// Decodes a message body, given a type code and a reader positioned just
    /// past the header.
    public func decodeBody(type: MessageType, from r: inout ByteReader) throws -> Message {
        switch type {
        case .tversion: return .tversion(msize: try r.u32(), version: try r.string())
        case .rversion: return .rversion(msize: try r.u32(), version: try r.string())

        case .tauth:
            let afid = try r.u32(), uname = try r.string(), aname = try r.string()
            let nuid: UInt32? = hasNumericUname ? try r.u32() : nil
            return .tauth(afid: afid, uname: uname, aname: aname, numericUID: nuid)
        case .rauth: return .rauth(aqid: try r.qid())

        case .tattach:
            let fid = try r.u32(), afid = try r.u32()
            let uname = try r.string(), aname = try r.string()
            let nuid: UInt32? = hasNumericUname ? try r.u32() : nil
            return .tattach(fid: fid, afid: afid, uname: uname, aname: aname, numericUID: nuid)
        case .rattach: return .rattach(qid: try r.qid())

        case .rerror:
            let msg = try r.string()
            let errno: UInt32? = (dotu && r.remaining >= 4) ? try r.u32() : nil
            return .rerror(message: msg, errno: errno)
        case .rlerror: return .rlerror(errno: try r.u32())

        case .tflush: return .tflush(oldtag: try r.u16())
        case .rflush: return .rflush

        case .twalk:
            let fid = try r.u32(), newfid = try r.u32()
            let n = Int(try r.u16())
            guard n <= NineP.maxWalkElements else {
                throw NinePWireError.fieldOutOfRange("nwname=\(n)")
            }
            var names: [String] = []
            names.reserveCapacity(n)
            for _ in 0..<n { names.append(try r.string()) }
            return .twalk(fid: fid, newfid: newfid, names: names)
        case .rwalk:
            let n = Int(try r.u16())
            guard n <= NineP.maxWalkElements else {
                throw NinePWireError.fieldOutOfRange("nwqid=\(n)")
            }
            var qids: [Qid] = []
            qids.reserveCapacity(n)
            for _ in 0..<n { qids.append(try r.qid()) }
            return .rwalk(qids: qids)

        case .topen: return .topen(fid: try r.u32(), mode: OpenMode(rawValue: try r.u8()))
        case .ropen: return .ropen(qid: try r.qid(), iounit: try r.u32())

        case .tcreate:
            let fid = try r.u32(), name = try r.string()
            let perm = FileMode(rawValue: try r.u32())
            let mode = OpenMode(rawValue: try r.u8())
            let ext: String? = dotu ? try r.string() : nil
            return .tcreate(fid: fid, name: name, perm: perm, mode: mode, extensionString: ext)
        case .rcreate: return .rcreate(qid: try r.qid(), iounit: try r.u32())

        case .tread: return .tread(fid: try r.u32(), offset: try r.u64(), count: try r.u32())
        case .rread: return .rread(data: try r.u32PrefixedBytes())
        case .twrite:
            return .twrite(fid: try r.u32(), offset: try r.u64(), data: try r.u32PrefixedBytes())
        case .rwrite: return .rwrite(count: try r.u32())

        case .tclunk: return .tclunk(fid: try r.u32())
        case .rclunk: return .rclunk
        case .tremove: return .tremove(fid: try r.u32())
        case .rremove: return .rremove

        case .tstat: return .tstat(fid: try r.u32())
        case .rstat: return .rstat(stat: try readWrappedStat(from: &r))
        case .twstat:
            let fid = try r.u32()
            return .twstat(fid: fid, stat: try readWrappedStat(from: &r))
        case .rwstat: return .rwstat

        // MARK: 9P2000.L
        case .tstatfs: return .tstatfs(fid: try r.u32())
        case .rstatfs:
            return .rstatfs(StatFS(
                type: try r.u32(), bsize: try r.u32(), blocks: try r.u64(),
                bfree: try r.u64(), bavail: try r.u64(), files: try r.u64(),
                ffree: try r.u64(), fsid: try r.u64(), namelen: try r.u32()))

        case .tlopen:
            return .tlopen(fid: try r.u32(), flags: LinuxOpenFlags(rawValue: try r.u32()))
        case .rlopen: return .rlopen(qid: try r.qid(), iounit: try r.u32())

        case .tlcreate:
            return .tlcreate(
                fid: try r.u32(), name: try r.string(),
                flags: LinuxOpenFlags(rawValue: try r.u32()),
                mode: try r.u32(), gid: try r.u32())
        case .rlcreate: return .rlcreate(qid: try r.qid(), iounit: try r.u32())

        case .tsymlink:
            return .tsymlink(
                dfid: try r.u32(), name: try r.string(),
                target: try r.string(), gid: try r.u32())
        case .rsymlink: return .rsymlink(qid: try r.qid())

        case .tmknod:
            return .tmknod(
                dfid: try r.u32(), name: try r.string(), mode: try r.u32(),
                major: try r.u32(), minor: try r.u32(), gid: try r.u32())
        case .rmknod: return .rmknod(qid: try r.qid())

        case .trename:
            return .trename(fid: try r.u32(), dfid: try r.u32(), name: try r.string())
        case .rrename: return .rrename

        case .treadlink: return .treadlink(fid: try r.u32())
        case .rreadlink: return .rreadlink(target: try r.string())

        case .tgetattr:
            return .tgetattr(fid: try r.u32(), requestMask: GetattrMask(rawValue: try r.u64()))
        case .rgetattr:
            return .rgetattr(LinuxAttr(
                valid: GetattrMask(rawValue: try r.u64()), qid: try r.qid(),
                mode: try r.u32(), uid: try r.u32(), gid: try r.u32(),
                nlink: try r.u64(), rdev: try r.u64(), size: try r.u64(),
                blockSize: try r.u64(), blocks: try r.u64(),
                atimeSec: try r.u64(), atimeNsec: try r.u64(),
                mtimeSec: try r.u64(), mtimeNsec: try r.u64(),
                ctimeSec: try r.u64(), ctimeNsec: try r.u64(),
                btimeSec: try r.u64(), btimeNsec: try r.u64(),
                gen: try r.u64(), dataVersion: try r.u64()))

        case .tsetattr:
            return .tsetattr(
                fid: try r.u32(), valid: SetattrMask(rawValue: try r.u32()),
                mode: try r.u32(), uid: try r.u32(), gid: try r.u32(), size: try r.u64(),
                atimeSec: try r.u64(), atimeNsec: try r.u64(),
                mtimeSec: try r.u64(), mtimeNsec: try r.u64())
        case .rsetattr: return .rsetattr

        case .txattrwalk:
            return .txattrwalk(fid: try r.u32(), newfid: try r.u32(), name: try r.string())
        case .rxattrwalk: return .rxattrwalk(size: try r.u64())

        case .txattrcreate:
            return .txattrcreate(
                fid: try r.u32(), name: try r.string(),
                attrSize: try r.u64(), flags: try r.u32())
        case .rxattrcreate: return .rxattrcreate

        case .treaddir:
            return .treaddir(fid: try r.u32(), offset: try r.u64(), count: try r.u32())
        case .rreaddir:
            var inner = ByteReader(try r.u32PrefixedBytes())
            var entries: [Dirent] = []
            while !inner.isAtEnd {
                let q = try inner.qid()
                let off = try inner.u64()
                let t = try inner.u8()
                let name = try inner.string()
                entries.append(Dirent(qid: q, offset: off, type: t, name: name))
            }
            return .rreaddir(entries: entries)

        case .tfsync: return .tfsync(fid: try r.u32(), dataSync: try r.u32())
        case .rfsync: return .rfsync

        case .tlock:
            return .tlock(
                fid: try r.u32(), type: try r.u8(), flags: try r.u32(),
                start: try r.u64(), length: try r.u64(),
                procID: try r.u32(), clientID: try r.string())
        case .rlock: return .rlock(status: try r.u8())

        case .tgetlock:
            return .tgetlock(
                fid: try r.u32(), type: try r.u8(), start: try r.u64(),
                length: try r.u64(), procID: try r.u32(), clientID: try r.string())
        case .rgetlock:
            return .rgetlock(
                type: try r.u8(), start: try r.u64(), length: try r.u64(),
                procID: try r.u32(), clientID: try r.string())

        case .tlink: return .tlink(dfid: try r.u32(), fid: try r.u32(), name: try r.string())
        case .rlink: return .rlink

        case .tmkdir:
            return .tmkdir(
                dfid: try r.u32(), name: try r.string(),
                mode: try r.u32(), gid: try r.u32())
        case .rmkdir: return .rmkdir(qid: try r.qid())

        case .trenameat:
            return .trenameat(
                olddirfid: try r.u32(), oldname: try r.string(),
                newdirfid: try r.u32(), newname: try r.string())
        case .rrenameat: return .rrenameat

        case .tunlinkat:
            return .tunlinkat(dirfid: try r.u32(), name: try r.string(), flags: try r.u32())
        case .runlinkat: return .runlinkat
        }
    }

    /// Reads a stat that may or may not be preceded by the redundant outer
    /// count described in stat(5) BUGS.
    ///
    /// Both layouts put a `remaining - 2` value in the first two bytes, so the
    /// only way to tell them apart is to look one field further: with the outer
    /// count present, the second `u16` is the stat's own size and equals the
    /// first minus two. Otherwise the second `u16` is `type`, which servers set
    /// to zero or a small kernel-private value.
    private func readWrappedStat(from r: inout ByteReader) throws -> Stat {
        guard r.remaining >= 4 else {
            throw NinePWireError.truncated(needed: 4, available: r.remaining)
        }
        var probe = r
        let first = try probe.u16()
        let second = try probe.u16()
        if second == first &- 2 {
            _ = try r.u16() // consume the outer count
        }
        return try r.stat(dotu: dotu)
    }
}
