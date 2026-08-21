import Foundation
import NineP

/// The per-connection 9P state machine.
///
/// A session owns the fid table and the negotiated dialect; it turns request
/// frames into reply frames and never touches a socket, so it can be driven
/// straight from a test. ``NinePConnection`` supplies the framing.
///
/// Requests are processed one at a time under a lock. That makes Tflush
/// trivially correct — by the time a Tflush is decoded, the request it names
/// has already been answered — at the cost of not overlapping slow reads on one
/// connection.
public final class NinePSession: @unchecked Sendable {
    /// Bytes of overhead in an Rread/Rreaddir frame: size[4] type[1] tag[2] count[4].
    static let dataFrameOverhead = NineP.headerSize + 4
    /// Difference between msize and the largest useful I/O chunk, matching the
    /// `IOHDRSZ` every other 9P implementation uses.
    static let ioHeaderSize: UInt32 = 24

    public let fileSystem: any NinePFileServer
    public let configuration: NinePServerConfiguration

    private let lock = NSLock()
    private var fids: [Fid: FidState] = [:]
    private var version: NinePVersion?
    private var negotiatedMsize: UInt32

    public init(fileSystem: any NinePFileServer, configuration: NinePServerConfiguration = .init()) {
        self.fileSystem = fileSystem
        self.configuration = configuration
        self.negotiatedMsize = configuration.maxMessageSize
    }

    /// The dialect agreed by Tversion, or nil before negotiation.
    public var negotiatedVersion: NinePVersion? { lock.withLock { version } }

    /// The largest frame either side may send. Before negotiation this is the
    /// server's maximum, which is what the framing layer must use to bound the
    /// very first read.
    public var msize: UInt32 { lock.withLock { negotiatedMsize } }

    /// Codec for the negotiated dialect. Tversion decodes identically in all
    /// three, so the pre-negotiation value is safe for the first message.
    public var codec: MessageCodec { lock.withLock { MessageCodec(version: version ?? .v9P2000) } }

    /// Answers one request. Never throws: every failure becomes an error reply
    /// in whichever shape the negotiated dialect uses.
    public func handle(_ frame: Frame) -> Frame {
        lock.withLock {
            do {
                return try dispatch(frame)
            } catch {
                return errorFrame(tag: frame.tag, error.asNinePServerError)
            }
        }
    }

    /// Releases every fid. Called when the connection goes away.
    public func close() {
        lock.withLock {
            for (_, state) in fids { discard(state) }
            fids.removeAll()
        }
    }

    // MARK: - Fid state

    private final class FidState {
        var path: FilePath
        /// The attach point; `..` may never climb above it.
        let root: FilePath
        var qid: Qid
        var uname: String
        var uid: UInt32
        var handle: NinePFileHandle?
        var directory: DirectorySnapshot?
        var isOpen = false
        var openFlags: LinuxOpenFlags = .rdonly
        /// ORCLOSE: remove the file when the fid is clunked.
        var removeOnClunk = false
        /// Bound by Txattrwalk; every operation on it but clunk fails.
        var isXattr = false

        init(path: FilePath, root: FilePath, qid: Qid, uname: String, uid: UInt32) {
            self.path = path
            self.root = root
            self.qid = qid
            self.uname = uname
            self.uid = uid
        }
    }

    /// A directory listing frozen at open time.
    ///
    /// Both dialects hand a listing out in chunks and expect the offsets in one
    /// reply to still mean the same thing in the next request, which is only
    /// true if the listing does not shift underneath the client. Freezing it
    /// also makes "offsets must land on an entry boundary" checkable.
    private struct DirectorySnapshot {
        /// Rreaddir entries, including `.` and `..`; `offset` is the cookie to
        /// resume *after* that entry, so it equals the entry's index plus one.
        var dirents: [Dirent]
        /// 9P2000 stat structures, one per real child (no `.` or `..`).
        var statBlobs: [[UInt8]]
        /// Byte offset of each blob, plus the total length as a final element.
        var statStarts: [UInt64]

        func statBytes(at offset: UInt64, limit: Int) throws -> [UInt8] {
            guard let index = statStarts.firstIndex(of: offset) else {
                throw NinePServerError.invalidArgument(
                    "directory read at offset \(offset), which is not an entry boundary")
            }
            var out: [UInt8] = []
            var i = index
            while i < statBlobs.count, out.count + statBlobs[i].count <= limit {
                out.append(contentsOf: statBlobs[i])
                i += 1
            }
            if out.isEmpty && index < statBlobs.count {
                throw NinePServerError.invalidArgument(
                    "read count \(limit) is too small for the next directory entry")
            }
            return out
        }

        func entries(at offset: UInt64, limit: Int) throws -> [Dirent] {
            guard offset <= UInt64(dirents.count) else {
                throw NinePServerError.invalidArgument("readdir offset \(offset) past the end")
            }
            var out: [Dirent] = []
            var used = 0
            var i = Int(offset)
            while i < dirents.count {
                let size = Qid.wireSize + 8 + 1 + 2 + dirents[i].name.utf8.count
                if used + size > limit { break }
                out.append(dirents[i])
                used += size
                i += 1
            }
            return out
        }
    }

    private func discard(_ state: FidState) {
        state.handle?.close()
        state.handle = nil
        state.directory = nil
    }

    private func lookup(_ fid: Fid) throws -> FidState {
        guard fid != NineP.nofid, let state = fids[fid] else {
            throw NinePServerError.badFileDescriptor("unknown fid \(fid)")
        }
        guard !state.isXattr else {
            throw NinePServerError.notSupported("extended attributes are not supported")
        }
        return state
    }

    private func requireOpen(_ state: FidState) throws {
        guard state.isOpen else { throw NinePServerError.badFileDescriptor("fid is not open") }
    }

    private func requireLinux() throws {
        guard version?.isLinux == true else {
            throw NinePServerError.notSupported("message is 9P2000.L only")
        }
    }

    private static func validate(name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw NinePServerError.invalidArgument("invalid file name \"\(name)\"")
        }
    }

    // MARK: - Replies

    private func errorFrame(tag: Tag, _ error: NinePServerError) -> Frame {
        if version?.isLinux == true {
            return Frame(tag: tag, message: .rlerror(errno: error.errno))
        }
        // The codec drops the errno for base 9P2000 and keeps it for 9P2000.u.
        return Frame(tag: tag, message: .rerror(message: error.message, errno: error.errno))
    }

    private var iounit: UInt32 {
        negotiatedMsize > Self.ioHeaderSize ? negotiatedMsize - Self.ioHeaderSize : 0
    }

    /// Largest payload that still fits in one frame.
    private var maxDataPayload: Int {
        max(0, Int(negotiatedMsize) - Self.dataFrameOverhead)
    }

    // MARK: - Dispatch

    private func dispatch(_ frame: Frame) throws -> Frame {
        let tag = frame.tag
        if case let .tversion(msize, name) = frame.message {
            return handleVersion(tag: tag, requestedMsize: msize, requestedVersion: name)
        }
        guard version != nil else {
            throw NinePServerError.invalidArgument("no version has been negotiated")
        }

        switch frame.message {
        case .tauth:
            throw NinePServerError.notSupported("authentication is not required")

        case let .tattach(fid, _, uname, aname, numericUID):
            guard fid != NineP.nofid else { throw NinePServerError.invalidArgument("bad fid") }
            guard fids[fid] == nil else { throw NinePServerError.invalidArgument("fid \(fid) is in use") }
            let uid = numericUID ?? UInt32.max
            let attached = try fileSystem.attach(uname: uname, aname: aname, uid: uid)
            fids[fid] = FidState(path: attached.path, root: attached.path,
                                 qid: attached.entry.qid, uname: uname, uid: uid)
            return Frame(tag: tag, message: .rattach(qid: attached.entry.qid))

        case .tflush:
            // Requests are answered in order, so anything a client tries to
            // flush has already been replied to.
            return Frame(tag: tag, message: .rflush)

        case let .twalk(fid, newfid, names):
            return try handleWalk(tag: tag, fid: fid, newfid: newfid, names: names)

        case let .topen(fid, mode):
            let state = try lookup(fid)
            guard !state.isOpen else { throw NinePServerError.invalidArgument("fid is already open") }
            let entry = try fileSystem.entry(at: state.path)
            try open(state, entry: entry, flags: Self.linuxFlags(from: mode))
            state.removeOnClunk = mode.contains(.rclose)
            return Frame(tag: tag, message: .ropen(qid: entry.qid, iounit: iounit))

        case let .tcreate(fid, name, perm, mode, extensionString):
            return try handleCreate(tag: tag, fid: fid, name: name, perm: perm,
                                    mode: mode, extensionString: extensionString)

        case let .tread(fid, offset, count):
            let state = try lookup(fid)
            try requireOpen(state)
            let limit = min(Int(count), maxDataPayload)
            if let snapshot = state.directory {
                guard version?.isLinux != true else {
                    throw NinePServerError.isADirectory("use Treaddir in 9P2000.L")
                }
                return Frame(tag: tag, message: .rread(data: try snapshot.statBytes(at: offset, limit: limit)))
            }
            guard let handle = state.handle else { throw NinePServerError.badFileDescriptor() }
            return Frame(tag: tag, message: .rread(data: try handle.read(offset: offset, count: limit)))

        case let .twrite(fid, offset, data):
            let state = try lookup(fid)
            try requireOpen(state)
            guard state.directory == nil, let handle = state.handle else {
                throw NinePServerError.isADirectory("cannot write to a directory")
            }
            let written = try handle.write(offset: offset, bytes: data)
            return Frame(tag: tag, message: .rwrite(count: UInt32(written)))

        case let .tclunk(fid):
            guard let state = fids.removeValue(forKey: fid) else {
                throw NinePServerError.badFileDescriptor("unknown fid \(fid)")
            }
            discard(state)
            if state.removeOnClunk, let parent = state.path.parent {
                // A failed ORCLOSE removal is not worth failing the clunk over:
                // the fid is gone either way.
                try? fileSystem.unlink(in: parent, name: state.path.name,
                                       isDirectory: state.qid.isDir)
            }
            return Frame(tag: tag, message: .rclunk)

        case let .tremove(fid):
            guard let state = fids.removeValue(forKey: fid) else {
                throw NinePServerError.badFileDescriptor("unknown fid \(fid)")
            }
            discard(state)
            guard let parent = state.path.parent else {
                throw NinePServerError.permissionDenied("cannot remove the root")
            }
            let entry = try fileSystem.entry(at: state.path)
            try fileSystem.unlink(in: parent, name: state.path.name, isDirectory: entry.isDirectory)
            return Frame(tag: tag, message: .rremove)

        case let .tstat(fid):
            let state = try lookup(fid)
            let entry = try fileSystem.entry(at: state.path)
            return Frame(tag: tag, message: .rstat(stat: stat(for: entry, at: state.path)))

        case let .twstat(fid, requested):
            return try handleWstat(tag: tag, fid: fid, requested: requested)

        // MARK: 9P2000.L

        case let .tstatfs(fid):
            try requireLinux()
            let state = try lookup(fid)
            return Frame(tag: tag, message: .rstatfs(try fileSystem.statfs(state.path)))

        case let .tlopen(fid, flags):
            try requireLinux()
            let state = try lookup(fid)
            guard !state.isOpen else { throw NinePServerError.invalidArgument("fid is already open") }
            let entry = try fileSystem.entry(at: state.path)
            try open(state, entry: entry, flags: flags)
            return Frame(tag: tag, message: .rlopen(qid: entry.qid, iounit: iounit))

        case let .tlcreate(fid, name, flags, mode, gid):
            try requireLinux()
            try Self.validate(name: name)
            let state = try lookup(fid)
            guard !state.isOpen else { throw NinePServerError.invalidArgument("fid is already open") }
            let created = try fileSystem.create(in: state.path, name: name, mode: mode,
                                                flags: flags, gid: gid)
            state.path = state.path.appending(name)
            state.qid = created.entry.qid
            state.handle = created.handle
            state.isOpen = true
            state.openFlags = flags
            return Frame(tag: tag, message: .rlcreate(qid: created.entry.qid, iounit: iounit))

        case let .tsymlink(dfid, name, target, gid):
            try requireLinux()
            try Self.validate(name: name)
            let state = try lookup(dfid)
            let entry = try fileSystem.symlink(in: state.path, name: name, target: target, gid: gid)
            return Frame(tag: tag, message: .rsymlink(qid: entry.qid))

        case .tmknod:
            throw NinePServerError.notSupported("device nodes are not supported")

        case let .trename(fid, dfid, name):
            try requireLinux()
            try Self.validate(name: name)
            let state = try lookup(fid)
            let destination = try lookup(dfid)
            guard let parent = state.path.parent else {
                throw NinePServerError.permissionDenied("cannot rename the root")
            }
            try fileSystem.rename(from: parent, name: state.path.name,
                                  to: destination.path, newName: name)
            reparent(from: state.path, to: destination.path.appending(name))
            return Frame(tag: tag, message: .rrename)

        case let .treadlink(fid):
            try requireLinux()
            let state = try lookup(fid)
            return Frame(tag: tag, message: .rreadlink(target: try fileSystem.readlink(state.path)))

        case let .tgetattr(fid, requestMask):
            try requireLinux()
            let state = try lookup(fid)
            let entry = try fileSystem.entry(at: state.path)
            return Frame(tag: tag, message: .rgetattr(Self.linuxAttr(for: entry, request: requestMask)))

        case let .tsetattr(fid, valid, mode, uid, gid, size, atimeSec, atimeNsec, mtimeSec, mtimeNsec):
            try requireLinux()
            let state = try lookup(fid)
            var request = SetattrRequest()
            if valid.contains(.mode) { request.mode = mode }
            if valid.contains(.uid) { request.uid = uid }
            if valid.contains(.gid) { request.gid = gid }
            if valid.contains(.size) { request.size = size }
            if valid.contains(.atime) {
                request.atime = valid.contains(.atimeSet)
                    ? .set(TimeSpec(seconds: atimeSec, nanoseconds: atimeNsec)) : .now
            }
            if valid.contains(.mtime) {
                request.mtime = valid.contains(.mtimeSet)
                    ? .set(TimeSpec(seconds: mtimeSec, nanoseconds: mtimeNsec)) : .now
            }
            try fileSystem.setattr(state.path, request)
            return Frame(tag: tag, message: .rsetattr)

        case let .txattrwalk(fid, newfid, _):
            try requireLinux()
            let state = try lookup(fid)
            guard fids[newfid] == nil || newfid == fid else {
                throw NinePServerError.invalidArgument("newfid \(newfid) is in use")
            }
            // No xattr support: bind newfid so the client's clunk succeeds, and
            // report an empty attribute set.
            let clone = FidState(path: state.path, root: state.root, qid: state.qid,
                                 uname: state.uname, uid: state.uid)
            clone.isXattr = true
            fids[newfid] = clone
            return Frame(tag: tag, message: .rxattrwalk(size: 0))

        case .txattrcreate:
            throw NinePServerError.notSupported("extended attributes are not supported")

        case let .treaddir(fid, offset, count):
            try requireLinux()
            let state = try lookup(fid)
            try requireOpen(state)
            guard let snapshot = state.directory else {
                throw NinePServerError.notADirectory("fid is not a directory")
            }
            let limit = min(Int(count), maxDataPayload)
            return Frame(tag: tag, message: .rreaddir(entries: try snapshot.entries(at: offset, limit: limit)))

        case let .tfsync(fid, _):
            try requireLinux()
            let state = try lookup(fid)
            if let handle = state.handle {
                try handle.sync()
            } else {
                try fileSystem.sync(state.path)
            }
            return Frame(tag: tag, message: .rfsync)

        case .tlock:
            try requireLinux()
            // Advisory locks are accepted and forgotten: this server has a
            // single writer per file anyway, and refusing would break clients
            // that lock defensively. Documented in docs/design/server.md.
            return Frame(tag: tag, message: .rlock(status: LockStatus.success))

        case let .tgetlock(_, _, start, length, procID, clientID):
            try requireLinux()
            return Frame(tag: tag, message: .rgetlock(
                type: LockType.unlock, start: start, length: length,
                procID: procID, clientID: clientID))

        case let .tlink(dfid, fid, name):
            try requireLinux()
            try Self.validate(name: name)
            let directory = try lookup(dfid)
            let target = try lookup(fid)
            try fileSystem.link(target.path, in: directory.path, name: name)
            return Frame(tag: tag, message: .rlink)

        case let .tmkdir(dfid, name, mode, gid):
            try requireLinux()
            try Self.validate(name: name)
            let state = try lookup(dfid)
            let entry = try fileSystem.mkdir(in: state.path, name: name, mode: mode, gid: gid)
            return Frame(tag: tag, message: .rmkdir(qid: entry.qid))

        case let .trenameat(olddirfid, oldname, newdirfid, newname):
            try requireLinux()
            try Self.validate(name: oldname)
            try Self.validate(name: newname)
            let source = try lookup(olddirfid)
            let destination = try lookup(newdirfid)
            try fileSystem.rename(from: source.path, name: oldname,
                                  to: destination.path, newName: newname)
            reparent(from: source.path.appending(oldname),
                     to: destination.path.appending(newname))
            return Frame(tag: tag, message: .rrenameat)

        case let .tunlinkat(dirfid, name, flags):
            try requireLinux()
            try Self.validate(name: name)
            let state = try lookup(dirfid)
            try fileSystem.unlink(in: state.path, name: name,
                                  isDirectory: flags & UnlinkAtFlags.removeDir != 0)
            return Frame(tag: tag, message: .runlinkat)

        default:
            // Every remaining case is an R-message; a client that sends one is
            // confused, but that is not a reason to drop the connection.
            throw NinePServerError.invalidArgument("unexpected message \(frame.message.type)")
        }
    }

    // MARK: - Version

    private func handleVersion(tag: Tag, requestedMsize: UInt32, requestedVersion name: String) -> Frame {
        // Tversion restarts the connection: every fid is forgotten.
        for (_, state) in fids { discard(state) }
        fids.removeAll()
        version = nil

        let clamped = min(requestedMsize, configuration.maxMessageSize)
        guard clamped >= configuration.minimumMessageSize,
              let chosen = selectVersion(name) else {
            negotiatedMsize = configuration.maxMessageSize
            return Frame(tag: tag, message: .rversion(msize: clamped, version: "unknown"))
        }
        version = chosen
        negotiatedMsize = clamped
        return Frame(tag: tag, message: .rversion(msize: clamped, version: chosen.rawValue))
    }

    /// Picks the dialect to speak.
    ///
    /// version(5) lets the server answer with any version no greater than the
    /// one proposed, so an unrecognised member of the 9P2000 family degrades to
    /// base 9P2000 rather than failing outright.
    private func selectVersion(_ requested: String) -> NinePVersion? {
        if let exact = NinePVersion(rawValue: requested),
           configuration.supportedVersions.contains(exact) {
            return exact
        }
        if requested.hasPrefix("9P2000"), configuration.supportedVersions.contains(.v9P2000) {
            return .v9P2000
        }
        return nil
    }

    // MARK: - Walk

    private func handleWalk(tag: Tag, fid: Fid, newfid: Fid, names: [String]) throws -> Frame {
        guard names.count <= NineP.maxWalkElements else {
            throw NinePServerError.invalidArgument("a walk may carry at most \(NineP.maxWalkElements) names")
        }
        let state = try lookup(fid)
        guard !state.isOpen else { throw NinePServerError.invalidArgument("cannot walk an open fid") }
        if newfid != fid {
            guard newfid != NineP.nofid else { throw NinePServerError.invalidArgument("bad newfid") }
            guard fids[newfid] == nil else { throw NinePServerError.invalidArgument("newfid \(newfid) is in use") }
        }

        var current = state.path
        var entry = try fileSystem.entry(at: current)
        var qids: [Qid] = []
        for (index, name) in names.enumerated() {
            guard entry.isDirectory else {
                if index == 0 { throw NinePServerError.notADirectory(current.posixString) }
                break
            }
            let next: FilePath
            switch name {
            case ".":
                next = current
            case "..":
                // The attach point is the top of the client's world.
                next = current == state.root ? current : (current.parent ?? current)
            default:
                guard !name.contains("/") else {
                    throw NinePServerError.invalidArgument("walk name may not contain a slash")
                }
                next = current.appending(name)
            }
            do {
                entry = try fileSystem.entry(at: next)
            } catch {
                if index == 0 { throw error }
                break
            }
            current = next
            qids.append(entry.qid)
        }

        // A partial walk must leave newfid unbound — and must leave fid alone
        // even when the client asked to clone onto itself.
        if qids.count == names.count {
            let bound = FidState(path: current, root: state.root, qid: entry.qid,
                                 uname: state.uname, uid: state.uid)
            fids[newfid] = bound
        }
        return Frame(tag: tag, message: .rwalk(qids: qids))
    }

    // MARK: - Open and create

    private func open(_ state: FidState, entry: FileEntry, flags: LinuxOpenFlags) throws {
        if entry.isDirectory {
            guard flags.accessMode == LinuxOpenFlags.rdonly.rawValue else {
                throw NinePServerError.isADirectory("a directory can only be opened for reading")
            }
            state.directory = try snapshot(of: state.path, entry: entry, root: state.root)
            state.handle = nil
        } else {
            state.handle = try fileSystem.open(state.path, flags: flags)
            state.directory = nil
        }
        state.isOpen = true
        state.openFlags = flags
        state.qid = entry.qid
    }

    private func handleCreate(tag: Tag, fid: Fid, name: String, perm: FileMode,
                              mode: OpenMode, extensionString: String?) throws -> Frame {
        try Self.validate(name: name)
        let state = try lookup(fid)
        guard !state.isOpen else { throw NinePServerError.invalidArgument("fid is already open") }
        let permissions = perm.rawValue & 0o777
        let flags = Self.linuxFlags(from: mode)
        let created: FileEntry

        if perm.contains(.dir) {
            created = try fileSystem.mkdir(in: state.path, name: name, mode: permissions, gid: state.uid)
            state.path = state.path.appending(name)
            try open(state, entry: created, flags: .rdonly)
        } else if perm.contains(.symlink) {
            guard version == .v9P2000u else {
                throw NinePServerError.notSupported("symlink creation needs 9P2000.u")
            }
            guard let target = extensionString, !target.isEmpty else {
                throw NinePServerError.invalidArgument("a symlink needs a target in the extension field")
            }
            created = try fileSystem.symlink(in: state.path, name: name, target: target, gid: state.uid)
            state.path = state.path.appending(name)
            state.qid = created.qid
            state.isOpen = true
        } else {
            let result = try fileSystem.create(in: state.path, name: name, mode: permissions,
                                               flags: flags.union([.create, .excl]), gid: state.uid)
            created = result.entry
            state.path = state.path.appending(name)
            state.handle = result.handle
            state.directory = nil
            state.isOpen = true
            state.openFlags = flags
            state.qid = created.qid
        }
        state.removeOnClunk = mode.contains(.rclose)
        return Frame(tag: tag, message: .rcreate(qid: created.qid, iounit: iounit))
    }

    // MARK: - Wstat

    private func handleWstat(tag: Tag, fid: Fid, requested: Stat) throws -> Frame {
        let state = try lookup(fid)
        var request = SetattrRequest()
        if requested.mode.rawValue != UInt32.max {
            request.mode = Self.posixPermissions(from: requested.mode)
        }
        if requested.length != UInt64.max { request.size = requested.length }
        if requested.atime != UInt32.max {
            request.atime = .set(TimeSpec(seconds: UInt64(requested.atime)))
        }
        if requested.mtime != UInt32.max {
            request.mtime = .set(TimeSpec(seconds: UInt64(requested.mtime)))
        }
        if !requested.uid.isEmpty { request.ownerName = requested.uid }
        if !requested.gid.isEmpty { request.groupName = requested.gid }
        if requested.numericUID != UInt32.max { request.uid = requested.numericUID }
        if requested.numericGID != UInt32.max { request.gid = requested.numericGID }

        // stat(5): a wstat with every field set to "don't touch" asks the
        // server to flush the file to storage.
        if request.isEmpty && requested.name.isEmpty {
            try fileSystem.sync(state.path)
            return Frame(tag: tag, message: .rwstat)
        }
        if !request.isEmpty {
            try fileSystem.setattr(state.path, request)
        }
        if !requested.name.isEmpty && requested.name != state.path.name {
            try Self.validate(name: requested.name)
            guard let parent = state.path.parent else {
                throw NinePServerError.permissionDenied("cannot rename the root")
            }
            try fileSystem.rename(from: parent, name: state.path.name,
                                  to: parent, newName: requested.name)
            reparent(from: state.path, to: parent.appending(requested.name))
        }
        return Frame(tag: tag, message: .rwstat)
    }

    /// Moves every fid that pointed at `from` (or into it) to the new location,
    /// so a rename does not strand the client's other fids.
    private func reparent(from: FilePath, to: FilePath) {
        for (_, state) in fids where state.path.isInside(from) {
            let tail = state.path.components.dropFirst(from.components.count)
            state.path = FilePath(to.components + tail)
        }
    }

    // MARK: - Snapshots and conversions

    private func snapshot(of path: FilePath, entry: FileEntry, root: FilePath) throws -> DirectorySnapshot {
        let children = try fileSystem.list(path)
        let parentEntry: FileEntry
        if path == root, let parent = path.parent {
            // At the attach point `..` is itself, matching the walk rule above.
            parentEntry = entry
            _ = parent
        } else if let parent = path.parent {
            parentEntry = (try? fileSystem.entry(at: parent)) ?? entry
        } else {
            parentEntry = entry
        }

        var dirents: [Dirent] = []
        dirents.append(Dirent(qid: entry.qid, offset: 1, type: DirentType.dir, name: "."))
        dirents.append(Dirent(qid: parentEntry.qid, offset: 2, type: DirentType.dir, name: ".."))
        for child in children {
            dirents.append(Dirent(qid: child.qid, offset: UInt64(dirents.count + 1),
                                  type: child.direntType, name: child.name))
        }

        let dotu = version == .v9P2000u
        var blobs: [[UInt8]] = []
        var starts: [UInt64] = []
        var total: UInt64 = 0
        for child in children {
            var writer = ByteWriter(reserving: 128)
            writer.stat(stat(for: child, at: path.appending(child.name)), dotu: dotu)
            starts.append(total)
            total += UInt64(writer.count)
            blobs.append(writer.bytes)
        }
        starts.append(total)
        return DirectorySnapshot(dirents: dirents, statBlobs: blobs, statStarts: starts)
    }

    private func stat(for entry: FileEntry, at path: FilePath) -> Stat {
        Stat(
            type: 0, dev: 0, qid: entry.qid,
            mode: Self.fileMode(from: entry.mode),
            atime: UInt32(truncatingIfNeeded: entry.atime.seconds),
            mtime: UInt32(truncatingIfNeeded: entry.mtime.seconds),
            length: entry.isDirectory ? 0 : entry.size,
            name: path.isRoot ? "/" : entry.name,
            uid: entry.ownerName, gid: entry.groupName, muid: entry.ownerName,
            extensionString: entry.symlinkTarget ?? "",
            numericUID: entry.uid, numericGID: entry.gid, numericMUID: entry.uid)
    }

    static func linuxAttr(for entry: FileEntry, request: GetattrMask) -> LinuxAttr {
        LinuxAttr(
            valid: request.intersection(.basic), qid: entry.qid, mode: entry.mode,
            uid: entry.uid, gid: entry.gid, nlink: entry.nlink, rdev: entry.rdev,
            size: entry.size, blockSize: entry.blockSize, blocks: entry.blocks,
            atimeSec: entry.atime.seconds, atimeNsec: entry.atime.nanoseconds,
            mtimeSec: entry.mtime.seconds, mtimeNsec: entry.mtime.nanoseconds,
            ctimeSec: entry.ctime.seconds, ctimeNsec: entry.ctime.nanoseconds)
    }

    /// 9P2000 open mode to the Linux flags the provider protocol speaks.
    static func linuxFlags(from mode: OpenMode) -> LinuxOpenFlags {
        var flags: LinuxOpenFlags
        switch mode.access {
        case 1: flags = .wronly
        case 2: flags = .rdwr
        default: flags = .rdonly     // OEXEC reads, as far as the server cares
        }
        if mode.contains(.trunc) { flags.insert(.trunc) }
        return flags
    }

    /// POSIX `st_mode` to the 9P2000 DM-flavoured mode.
    static func fileMode(from posix: UInt32) -> FileMode {
        var mode = FileMode(rawValue: posix & 0o777)
        switch posix & PosixFileType.mask {
        case PosixFileType.dir: mode.insert(.dir)
        case PosixFileType.lnk: mode.insert(.symlink)
        case PosixFileType.fifo: mode.insert(.namedPipe)
        case PosixFileType.sock: mode.insert(.socket)
        case PosixFileType.chr, PosixFileType.blk: mode.insert(.device)
        default: break
        }
        if posix & 0o4000 != 0 { mode.insert(.setuid) }
        if posix & 0o2000 != 0 { mode.insert(.setgid) }
        return mode
    }

    /// The permission bits of a 9P2000 mode, including setuid/setgid.
    static func posixPermissions(from mode: FileMode) -> UInt32 {
        var posix = mode.rawValue & 0o777
        if mode.contains(.setuid) { posix |= 0o4000 }
        if mode.contains(.setgid) { posix |= 0o2000 }
        return posix
    }
}
