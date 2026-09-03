import Foundation
import NineP

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Identity presented to the server at attach time.
public struct NinePCredentials: Sendable {
    /// The user name sent in Tattach (`uname`).
    public var uname: String
    /// The file tree to attach to (`aname`); usually empty.
    public var aname: String
    /// Numeric uid sent in 9P2000.u/.L attaches. `nil` means "unspecified".
    public var numericUID: UInt32?
    /// Reported as the owner of files when the server gives no numeric owner.
    public var defaultUID: UInt32
    public var defaultGID: UInt32

    public init(
        uname: String = NinePCredentials.currentUserName(),
        aname: String = "",
        numericUID: UInt32? = nil,
        defaultUID: UInt32 = UInt32(getuid()),
        defaultGID: UInt32 = UInt32(getgid())
    ) {
        self.uname = uname
        self.aname = aname
        self.numericUID = numericUID
        self.defaultUID = defaultUID
        self.defaultGID = defaultGID
    }

    public static func currentUserName() -> String {
        if let name = ProcessInfo.processInfo.environment["USER"], !name.isEmpty { return name }
        return String(cString: getpwuid(getuid())?.pointee.pw_name ?? strdup("none"))
    }
}

/// A POSIX-shaped view of a 9P server.
///
/// The three dialects express the same operations very differently — 9P2000.L
/// has `getattr`/`readdir`/`mkdir`, while base 9P2000 has only `stat`, reads of
/// directories and `create` with a mode bit — so every method here does
/// whatever the negotiated dialect requires and presents one result shape.
public final class NinePClient: @unchecked Sendable {
    public let session: NinePSession
    public let credentials: NinePCredentials
    /// The fid attached to the root of the served tree.
    public let rootFid: Fid
    /// The qid of the root.
    public let rootQid: Qid

    private let fids = FidPool()

    public var version: NinePVersion { session.version }
    /// Largest read or write payload that fits in one message.
    public var ioSize: Int { session.maxDataSize }

    private init(session: NinePSession, credentials: NinePCredentials,
                 rootFid: Fid, rootQid: Qid) {
        self.session = session
        self.credentials = credentials
        self.rootFid = rootFid
        self.rootQid = rootQid
    }

    /// Connects, negotiates a version and attaches to the served tree.
    public static func connect(
        to endpoint: NinePEndpoint,
        credentials: NinePCredentials = NinePCredentials(),
        options: NinePSessionOptions = NinePSessionOptions()
    ) async throws -> NinePClient {
        let session = try await NinePSession.connect(to: endpoint, options: options)
        do {
            let rootFid: Fid = 0
            let qid = try await session.rpc(
                .tattach(fid: rootFid, afid: P9.nofid,
                         uname: credentials.uname, aname: credentials.aname,
                         numericUID: credentials.numericUID ?? UInt32.max)
            ) { if case let .rattach(q) = $0 { q } else { nil } }
            return NinePClient(session: session, credentials: credentials,
                               rootFid: rootFid, rootQid: qid)
        } catch {
            session.close()
            throw error
        }
    }

    public func close() {
        session.close()
    }

    // MARK: - Fids

    /// Allocates an unused fid number. The caller owns it until `clunk`.
    public func allocateFid() throws -> Fid { try fids.allocate() }

    /// Releases a fid on the server and returns its number to the pool.
    ///
    /// Clunking cannot meaningfully fail — the server forgets the fid either
    /// way — so errors are swallowed rather than propagated into cleanup paths.
    public func clunk(_ fid: Fid) async {
        guard fid != rootFid, fid != P9.nofid else { return }
        _ = try? await session.rpc(.tclunk(fid: fid))
        fids.release(fid)
    }

    /// Number of fids handed out and not yet clunked. For leak checks in tests.
    public var outstandingFidCount: Int { fids.outstandingCount }

    // MARK: - Walking

    /// Walks `names` from `from`, binding the result to a fresh fid.
    ///
    /// A walk of more than 16 elements is split into several Twalks, as the
    /// protocol requires. A short reply means the walk stopped early; since the
    /// server then leaves the new fid unbound, that is surfaced as ENOENT.
    @discardableResult
    public func walk(from: Fid, to names: [String]) async throws -> (fid: Fid, qids: [Qid]) {
        let newFid = try fids.allocate()
        do {
            var qids: [Qid] = []
            var source = from
            var remaining = names[...]
            repeat {
                let chunk = Array(remaining.prefix(P9.maxWalkElements))
                remaining = remaining.dropFirst(chunk.count)
                let got = try await session.rpc(
                    .twalk(fid: source, newfid: newFid, names: chunk)
                ) { if case let .rwalk(q) = $0 { q } else { nil } }
                qids.append(contentsOf: got)
                guard got.count == chunk.count else {
                    // Partial walk: newFid was never bound, so there is nothing
                    // to clunk. Report the element that failed.
                    fids.release(newFid)
                    throw NinePServerError(
                        errno: ENOENT,
                        message: "no such file or directory: \(chunk[min(got.count, chunk.count - 1)])")
                }
                // Subsequent chunks continue from the fid we just bound.
                source = newFid
            } while !remaining.isEmpty
            return (newFid, qids)
        } catch {
            fids.release(newFid)
            throw error
        }
    }

    /// Walks a slash-separated path from the root.
    public func walk(path: String) async throws -> (fid: Fid, qids: [Qid]) {
        let names = path.split(separator: "/").map(String.init)
            .filter { $0 != "." && !$0.isEmpty }
        return try await walk(from: rootFid, to: names)
    }

    /// Clones a fid so it can be opened without disturbing the original.
    public func clone(_ fid: Fid) async throws -> Fid {
        try await walk(from: fid, to: []).fid
    }

    // MARK: - Attributes

    /// Reads a file's attributes, using Tgetattr on 9P2000.L and Tstat elsewhere.
    public func getattr(_ fid: Fid, mask: GetattrMask = .basic) async throws -> LinuxAttr {
        if version.isLinux {
            return try await session.rpc(.tgetattr(fid: fid, requestMask: mask)) {
                if case let .rgetattr(a) = $0 { a } else { nil }
            }
        }
        let stat = try await self.stat(fid)
        return attr(from: stat)
    }

    /// Reads a 9P2000 stat structure. Not available in 9P2000.L, which has no
    /// Tstat; callers on that dialect should use ``getattr(_:mask:)``.
    public func stat(_ fid: Fid) async throws -> Stat {
        guard !version.isLinux else {
            throw NinePServerError(errno: ENOTSUP, message: "9P2000.L has no Tstat")
        }
        return try await session.rpc(.tstat(fid: fid)) {
            if case let .rstat(s) = $0 { s } else { nil }
        }
    }

    /// Translates a 9P2000 stat into the POSIX-shaped attributes the rest of
    /// the client speaks.
    func attr(from stat: Stat) -> LinuxAttr {
        var mode: UInt32 = UInt32(stat.mode.permissions)
        if stat.mode.contains(.dir) { mode |= PosixFileType.dir }
        else if stat.mode.contains(.symlink) { mode |= PosixFileType.lnk }
        else if stat.mode.contains(.namedPipe) { mode |= PosixFileType.fifo }
        else if stat.mode.contains(.socket) { mode |= PosixFileType.sock }
        else if stat.mode.contains(.device) {
            // 9P2000.u encodes the device kind in the extension string:
            // "c 1 3" for a character device, "b ..." for a block device.
            mode |= stat.extensionString.hasPrefix("b") ? PosixFileType.blk : PosixFileType.chr
        } else { mode |= PosixFileType.reg }
        if stat.mode.contains(.setuid) { mode |= 0o4000 }
        if stat.mode.contains(.setgid) { mode |= 0o2000 }

        let uid = stat.numericUID == .max ? credentials.defaultUID : stat.numericUID
        let gid = stat.numericGID == .max ? credentials.defaultGID : stat.numericGID
        return LinuxAttr(
            valid: .basic, qid: stat.qid, mode: mode, uid: uid, gid: gid,
            nlink: stat.mode.contains(.dir) ? 2 : 1, rdev: 0,
            size: stat.length, blockSize: 4096,
            blocks: (stat.length + 511) / 512,
            atimeSec: UInt64(stat.atime), atimeNsec: 0,
            mtimeSec: UInt64(stat.mtime), mtimeNsec: 0,
            ctimeSec: UInt64(stat.mtime), ctimeNsec: 0)
    }

    /// Applies attribute changes. On 9P2000 this becomes a Twstat with every
    /// untouched field set to its "don't touch" value.
    public func setattr(
        _ fid: Fid,
        mode: UInt32? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        size: UInt64? = nil,
        atime: (sec: UInt64, nsec: UInt64)? = nil,
        mtime: (sec: UInt64, nsec: UInt64)? = nil
    ) async throws {
        if version.isLinux {
            var valid = SetattrMask()
            if mode != nil { valid.insert(.mode) }
            if uid != nil { valid.insert(.uid) }
            if gid != nil { valid.insert(.gid) }
            if size != nil { valid.insert(.size) }
            if atime != nil { valid.formUnion([.atime, .atimeSet]) }
            if mtime != nil { valid.formUnion([.mtime, .mtimeSet]) }
            guard !valid.isEmpty else { return }
            try await session.rpc(.tsetattr(
                fid: fid, valid: valid, mode: mode ?? 0, uid: uid ?? 0, gid: gid ?? 0,
                size: size ?? 0,
                atimeSec: atime?.sec ?? 0, atimeNsec: atime?.nsec ?? 0,
                mtimeSec: mtime?.sec ?? 0, mtimeNsec: mtime?.nsec ?? 0))
            return
        }

        var st = Stat.noTouch()
        if let mode {
            // Keep the type bits the server already has; only permissions change.
            st.mode = FileMode(rawValue: mode & 0o7777)
        }
        if let size { st.length = size }
        if let atime { st.atime = UInt32(truncatingIfNeeded: atime.sec) }
        if let mtime { st.mtime = UInt32(truncatingIfNeeded: mtime.sec) }
        if version == .v9P2000u {
            if let uid { st.numericUID = uid }
            if let gid { st.numericGID = gid }
        }
        try await session.rpc(.twstat(fid: fid, stat: st))
    }

    // MARK: - Open, read, write

    /// Opens an existing file. Returns the qid and the server's preferred I/O
    /// size (`iounit`); zero means "use msize".
    @discardableResult
    public func open(_ fid: Fid, flags: OpenFlags) async throws -> (qid: Qid, iounit: UInt32) {
        if version.isLinux {
            return try await session.rpc(.tlopen(fid: fid, flags: flags.linux)) {
                if case let .rlopen(q, i) = $0 { (qid: q, iounit: i) } else { nil }
            }
        }
        return try await session.rpc(.topen(fid: fid, mode: flags.legacy)) {
            if case let .ropen(q, i) = $0 { (qid: q, iounit: i) } else { nil }
        }
    }

    /// Reads at most `count` bytes. A short result does not mean end of file
    /// unless it is empty; callers should loop.
    public func read(_ fid: Fid, offset: UInt64, count: UInt32) async throws -> [UInt8] {
        let capped = min(count, UInt32(ioSize))
        return try await session.rpc(.tread(fid: fid, offset: offset, count: capped)) {
            if case let .rread(d) = $0 { d } else { nil }
        }
    }

    /// Reads exactly `count` bytes, or fewer at end of file, issuing as many
    /// Treads as the negotiated msize requires.
    public func readFully(_ fid: Fid, offset: UInt64, count: Int) async throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var position = offset
        while out.count < count {
            let chunk = try await read(fid, offset: position,
                                       count: UInt32(min(count - out.count, ioSize)))
            if chunk.isEmpty { break }
            out.append(contentsOf: chunk)
            position += UInt64(chunk.count)
        }
        return out
    }

    /// Writes at most one message worth of data and reports how much was taken.
    public func write(_ fid: Fid, offset: UInt64, data: [UInt8]) async throws -> UInt32 {
        let chunk = data.count <= ioSize ? data : Array(data.prefix(ioSize))
        return try await session.rpc(.twrite(fid: fid, offset: offset, data: chunk)) {
            if case let .rwrite(n) = $0 { n } else { nil }
        }
    }

    /// Writes everything, splitting across as many messages as needed.
    public func writeFully(_ fid: Fid, offset: UInt64, data: [UInt8]) async throws {
        var written = 0
        while written < data.count {
            let n = try await write(fid, offset: offset + UInt64(written),
                                    data: Array(data[written...]))
            guard n > 0 else {
                throw NinePServerError(errno: EIO, message: "server accepted no bytes")
            }
            written += Int(n)
        }
    }

    public func fsync(_ fid: Fid, dataOnly: Bool = false) async throws {
        guard version.isLinux else { return }  // 9P2000 has no fsync; writes are synchronous
        try await session.rpc(.tfsync(fid: fid, dataSync: dataOnly ? 1 : 0))
    }

    // MARK: - Directories

    /// Lists a directory starting at `offset`.
    ///
    /// The `.` and `..` entries that 9P2000.L servers include are filtered out,
    /// so both dialects yield the same thing: the directory's real contents.
    /// Resume by passing the `offset` of the last entry returned.
    public func readdir(_ fid: Fid, offset: UInt64 = 0, count: UInt32? = nil) async throws -> [Dirent] {
        let want = min(count ?? UInt32(ioSize), UInt32(ioSize))
        if version.isLinux {
            let entries = try await session.rpc(
                .treaddir(fid: fid, offset: offset, count: want)
            ) { if case let .rreaddir(e) = $0 { e } else { nil } }
            return entries.filter { $0.name != "." && $0.name != ".." }
        }

        // Base 9P2000: a read of a directory returns marshalled stat structures
        // back to back, and the offset is a byte offset that must fall on an
        // entry boundary the server previously reported.
        let data = try await read(fid, offset: offset, count: want)
        var reader = ByteReader(data)
        var out: [Dirent] = []
        var consumed = offset
        while !reader.isAtEnd {
            let before = reader.remaining
            let st = try reader.stat(dotu: version == .v9P2000u)
            consumed += UInt64(before - reader.remaining)
            guard st.name != "." && st.name != ".." else { continue }
            out.append(Dirent(qid: st.qid, offset: consumed,
                              type: direntType(for: st.mode), name: st.name))
        }
        return out
    }

    /// Reads a whole directory, looping until the server runs out of entries.
    public func readdirAll(_ fid: Fid) async throws -> [Dirent] {
        var all: [Dirent] = []
        var offset: UInt64 = 0
        while true {
            let batch = try await readdir(fid, offset: offset)
            guard let last = batch.last else { break }
            all.append(contentsOf: batch)
            offset = last.offset
        }
        return all
    }

    private func direntType(for mode: FileMode) -> UInt8 {
        if mode.contains(.dir) { return DirentType.dir }
        if mode.contains(.symlink) { return DirentType.lnk }
        if mode.contains(.namedPipe) { return DirentType.fifo }
        if mode.contains(.socket) { return DirentType.sock }
        if mode.contains(.device) { return DirentType.chr }
        return DirentType.reg
    }

    // MARK: - Namespace changes

    /// Creates and opens a regular file inside the directory `dirFid` names.
    ///
    /// Both dialects consume the directory fid: it comes back referring to the
    /// newly created file, which is why callers should pass a clone.
    @discardableResult
    public func createFile(
        dirFid: Fid, name: String, flags: OpenFlags, mode: UInt32, gid: UInt32? = nil
    ) async throws -> (qid: Qid, iounit: UInt32) {
        if version.isLinux {
            return try await session.rpc(.tlcreate(
                fid: dirFid, name: name, flags: flags.linux, mode: mode,
                gid: gid ?? credentials.defaultGID)
            ) { if case let .rlcreate(q, i) = $0 { (qid: q, iounit: i) } else { nil } }
        }
        return try await session.rpc(.tcreate(
            fid: dirFid, name: name, perm: FileMode(rawValue: mode & 0o7777),
            mode: flags.legacy, extensionString: version == .v9P2000u ? "" : nil)
        ) { if case let .rcreate(q, i) = $0 { (qid: q, iounit: i) } else { nil } }
    }

    /// Creates a directory. Returns its qid.
    @discardableResult
    public func mkdir(dirFid: Fid, name: String, mode: UInt32, gid: UInt32? = nil) async throws -> Qid {
        if version.isLinux {
            return try await session.rpc(.tmkdir(
                dfid: dirFid, name: name, mode: mode, gid: gid ?? credentials.defaultGID)
            ) { if case let .rmkdir(q) = $0 { q } else { nil } }
        }
        // 9P2000 creates a directory by setting DMDIR in the permission word.
        // Tcreate consumes the fid, so work on a clone and clunk it after.
        let scratch = try await clone(dirFid)
        defer { Task { await self.clunk(scratch) } }
        let perm = FileMode(rawValue: FileMode.dir.rawValue | (mode & 0o7777))
        let result = try await session.rpc(.tcreate(
            fid: scratch, name: name, perm: perm, mode: OpenMode.read,
            extensionString: version == .v9P2000u ? "" : nil)
        ) { if case let .rcreate(q, _) = $0 { q } else { nil } }
        return result
    }

    /// Creates a symbolic link. Requires 9P2000.L or 9P2000.u.
    @discardableResult
    public func symlink(dirFid: Fid, name: String, target: String, gid: UInt32? = nil) async throws -> Qid {
        if version.isLinux {
            return try await session.rpc(.tsymlink(
                dfid: dirFid, name: name, target: target, gid: gid ?? credentials.defaultGID)
            ) { if case let .rsymlink(q) = $0 { q } else { nil } }
        }
        guard version == .v9P2000u else {
            throw NinePServerError(errno: ENOTSUP, message: "9P2000 cannot create symlinks")
        }
        let scratch = try await clone(dirFid)
        defer { Task { await self.clunk(scratch) } }
        let perm = FileMode(rawValue: FileMode.symlink.rawValue | 0o777)
        return try await session.rpc(.tcreate(
            fid: scratch, name: name, perm: perm, mode: OpenMode.read,
            extensionString: target)
        ) { if case let .rcreate(q, _) = $0 { q } else { nil } }
    }

    /// Reads a symbolic link's target.
    public func readlink(_ fid: Fid) async throws -> String {
        if version.isLinux {
            return try await session.rpc(.treadlink(fid: fid)) {
                if case let .rreadlink(t) = $0 { t } else { nil }
            }
        }
        guard version == .v9P2000u else {
            throw NinePServerError(errno: ENOTSUP, message: "9P2000 has no symlinks")
        }
        // In 9P2000.u the target lives in the stat extension string.
        return try await stat(fid).extensionString
    }

    /// Creates a hard link. 9P2000.L only.
    public func link(dirFid: Fid, targetFid: Fid, name: String) async throws {
        guard version.isLinux else {
            throw NinePServerError(errno: ENOTSUP, message: "hard links need 9P2000.L")
        }
        try await session.rpc(.tlink(dfid: dirFid, fid: targetFid, name: name))
    }

    /// Removes `name` from the directory `dirFid` names.
    public func unlink(dirFid: Fid, name: String, isDirectory: Bool) async throws {
        if version.isLinux {
            try await session.rpc(.tunlinkat(
                dirfid: dirFid, name: name,
                flags: isDirectory ? UnlinkAtFlags.removeDir : 0))
            return
        }
        // 9P2000 removes through a fid, and Tremove clunks it whether or not
        // the removal succeeded.
        let (victim, _) = try await walk(from: dirFid, to: [name])
        do {
            try await session.rpc(.tremove(fid: victim))
            fids.release(victim)
        } catch {
            fids.release(victim)
            throw error
        }
    }

    /// Renames, possibly across directories.
    public func rename(oldDirFid: Fid, oldName: String, newDirFid: Fid, newName: String) async throws {
        if version.isLinux {
            try await session.rpc(.trenameat(
                olddirfid: oldDirFid, oldname: oldName,
                newdirfid: newDirFid, newname: newName))
            return
        }
        // 9P2000 renames by wstat-ing a new name, which cannot move a file
        // between directories.
        guard oldDirFid == newDirFid else {
            throw NinePServerError(errno: EXDEV, message: "9P2000 cannot rename across directories")
        }
        let (victim, _) = try await walk(from: oldDirFid, to: [oldName])
        defer { Task { await self.clunk(victim) } }
        var st = Stat.noTouch()
        st.name = newName
        try await session.rpc(.twstat(fid: victim, stat: st))
    }

    // MARK: - Filesystem info

    /// Reports free space. Synthesised on dialects that have no Tstatfs.
    public func statfs(_ fid: Fid? = nil) async throws -> StatFS {
        if version.isLinux {
            return try await session.rpc(.tstatfs(fid: fid ?? rootFid)) {
                if case let .rstatfs(s) = $0 { s } else { nil }
            }
        }
        // 9P2000 has no statfs. Report a large, plausible volume rather than
        // zero, which makes callers think the disk is full.
        return StatFS(
            type: 0x39_5000, bsize: 4096,
            blocks: 1 << 32, bfree: 1 << 31, bavail: 1 << 31,
            files: 1 << 20, ffree: 1 << 19, fsid: 0, namelen: 255)
    }

    // MARK: - Extended attributes

    /// Opens an xattr for reading by walking `fid` to the named attribute.
    /// Returns a fid holding the value and its size, or nil when unsupported.
    public func xattrWalk(_ fid: Fid, name: String) async throws -> (fid: Fid, size: UInt64)? {
        guard version.isLinux else { return nil }
        let newFid = try fids.allocate()
        do {
            let size = try await session.rpc(
                .txattrwalk(fid: fid, newfid: newFid, name: name)
            ) { if case let .rxattrwalk(s) = $0 { s } else { nil } }
            return (newFid, size)
        } catch {
            fids.release(newFid)
            throw error
        }
    }
}
