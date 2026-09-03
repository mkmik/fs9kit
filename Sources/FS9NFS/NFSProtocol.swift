// NFS version 3, RFC 1813: dispatch and every procedure except the two
// directory readers, which live in `NFSDirectory.swift`.
//
// The shape of a v3 reply is always "status, then a union": on success the
// procedure's result, on failure a much smaller structure that still carries
// attributes. Getting the failure arm wrong is worse than it sounds — the
// client cannot resynchronise a reply it cannot parse, and the mount hangs
// rather than reporting an error. So every procedure below encodes both arms
// explicitly.

import Foundation
import FS9Core
import NineP

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum NFSConstants {
    public static let program: UInt32 = 100_003
    public static let version: UInt32 = 3

    public static let procedureNull: UInt32 = 0
    public static let procedureGetAttr: UInt32 = 1
    public static let procedureSetAttr: UInt32 = 2
    public static let procedureLookup: UInt32 = 3
    public static let procedureAccess: UInt32 = 4
    public static let procedureReadlink: UInt32 = 5
    public static let procedureRead: UInt32 = 6
    public static let procedureWrite: UInt32 = 7
    public static let procedureCreate: UInt32 = 8
    public static let procedureMkdir: UInt32 = 9
    public static let procedureSymlink: UInt32 = 10
    public static let procedureMknod: UInt32 = 11
    public static let procedureRemove: UInt32 = 12
    public static let procedureRmdir: UInt32 = 13
    public static let procedureRename: UInt32 = 14
    public static let procedureLink: UInt32 = 15
    public static let procedureReaddir: UInt32 = 16
    public static let procedureReaddirPlus: UInt32 = 17
    public static let procedureFsstat: UInt32 = 18
    public static let procedureFsinfo: UInt32 = 19
    public static let procedurePathconf: UInt32 = 20
    public static let procedureCommit: UInt32 = 21

    /// NFS3_MAXNAMLEN.
    public static let maximumNameLength = 255
    /// NFS3_MAXPATHLEN, the ceiling on a symlink target.
    public static let maximumPathLength = 1024
    /// NFS3_COOKIEVERFSIZE / NFS3_CREATEVERFSIZE / NFS3_WRITEVERFSIZE.
    public static let verifierSize = 8

    // `stable_how`
    public static let unstable: UInt32 = 0
    public static let dataSync: UInt32 = 1
    public static let fileSync: UInt32 = 2

    // FSINFO properties
    public static let fsfLink: UInt32 = 0x0001
    public static let fsfSymlink: UInt32 = 0x0002
    public static let fsfHomogeneous: UInt32 = 0x0008
    public static let fsfCanSetTime: UInt32 = 0x0010
}

/// The NFSv3 server.
///
/// An actor because it owns the exclusive-create verifier table and because
/// everything it does ends up awaiting ``NineVFS`` anyway; concurrency between
/// requests is provided by the RPC layer, which runs each call in its own task.
public actor NFSProgram: RPCProgram {
    public nonisolated let program = NFSConstants.program
    public nonisolated let versions = NFSConstants.version...NFSConstants.version

    let export: NFSExport
    private var vfs: NineVFS { export.vfs }

    /// Verifiers from EXCLUSIVE creates, keyed by node.
    ///
    /// RFC 1813 wants the verifier stored *persistently* with the file so a
    /// retried create after a network hiccup is recognised as a duplicate. We
    /// have nowhere on a 9P server to put it, so it is kept in memory: the
    /// retry window a client cares about is far shorter than our lifetime.
    private var exclusiveVerifiers: [NodeID: [UInt8]] = [:]

    public init(export: NFSExport) {
        self.export = export
    }

    public func call(procedure: UInt32, arguments: XDRDecoder, context: RPCContext) async throws -> [UInt8] {
        var args = arguments
        switch procedure {
        case NFSConstants.procedureNull: return []
        case NFSConstants.procedureGetAttr: return try await getAttr(&args)
        case NFSConstants.procedureSetAttr: return try await setAttr(&args)
        case NFSConstants.procedureLookup: return try await lookup(&args)
        case NFSConstants.procedureAccess: return try await access(&args, context)
        case NFSConstants.procedureReadlink: return try await readlink(&args)
        case NFSConstants.procedureRead: return try await read(&args)
        case NFSConstants.procedureWrite: return try await write(&args)
        case NFSConstants.procedureCreate: return try await create(&args)
        case NFSConstants.procedureMkdir: return try await mkdir(&args)
        case NFSConstants.procedureSymlink: return try await symlink(&args)
        case NFSConstants.procedureMknod: return try await mknod(&args)
        case NFSConstants.procedureRemove: return try await remove(&args, isDirectory: false)
        case NFSConstants.procedureRmdir: return try await remove(&args, isDirectory: true)
        case NFSConstants.procedureRename: return try await rename(&args)
        case NFSConstants.procedureLink: return try await link(&args)
        case NFSConstants.procedureReaddir: return try await readdir(&args)
        case NFSConstants.procedureReaddirPlus: return try await readdirPlus(&args)
        case NFSConstants.procedureFsstat: return try await fsstat(&args)
        case NFSConstants.procedureFsinfo: return try await fsinfo(&args)
        case NFSConstants.procedurePathconf: return try await pathconf(&args)
        case NFSConstants.procedureCommit: return try await commit(&args)
        default: throw RPCProgramError.procedureUnavailable
        }
    }

    // MARK: - Shared helpers

    /// Decodes a `nfs_fh3` and resolves it to a node.
    ///
    /// Anything we did not mint — wrong magic, wrong boot verifier, wrong
    /// length — is NFS3ERR_STALE, which tells the client to forget the handle
    /// and look the file up again. Silently accepting it would let a handle
    /// from a previous run of the server address an unrelated file.
    func decodeHandle(_ d: inout XDRDecoder) throws -> NodeID {
        let raw = try d.opaqueVariable(limit: nfsFileHandleSize)
        guard let handle = NFSFileHandle.decode(raw, boot: export.boot) else {
            throw NFSStatus.stale.failure
        }
        return handle.node
    }

    /// Decodes a `filename3`.
    ///
    /// The XDR limit is deliberately far above NFS3_MAXNAMLEN: a name of 300
    /// bytes is perfectly decodable and deserves NFS3ERR_NAMETOOLONG, whereas
    /// refusing it at the codec would report it as undecodable garbage. Only a
    /// length no sane client could have sent is treated as garbage.
    func decodeName(_ d: inout XDRDecoder) throws -> String {
        let name = try d.string(limit: 4096)
        guard name.utf8.count <= NFSConstants.maximumNameLength else {
            throw NFSStatus.nametoolong.failure
        }
        guard !name.isEmpty else { throw NFSStatus.inval.failure }
        return name
    }

    func handleBytes(_ node: NodeID) -> [UInt8] {
        NFSFileHandle(boot: export.boot, node: node).bytes
    }

    /// Attributes for a `post_op_attr`, or nil if they cannot be fetched.
    ///
    /// A failure here is never fatal: `post_op_attr` is optional precisely so
    /// a server can decline to answer without failing the whole call.
    func postAttributes(_ node: NodeID) async -> NFSFileAttributes? {
        guard let attributes = try? await vfs.getAttributes(node) else { return nil }
        return NFSFileAttributes(attributes, fsid: export.fsid)
    }

    /// The optional form, for the many failure paths where the handle may not
    /// have decoded at all.
    func postAttributes(_ node: NodeID?) async -> NFSFileAttributes? {
        guard let node else { return nil }
        return await postAttributes(node)
    }

    func wccBefore(_ node: NodeID) async -> NFSWccAttributes? {
        guard let attributes = try? await vfs.getAttributes(node) else { return nil }
        return NFSWccAttributes(attributes)
    }

    func requireWritable() throws {
        if export.isReadOnly { throw NFSStatus.rofs.failure }
    }

    /// Re-raises an argument that could not be decoded as an RPC-level
    /// GARBAGE_ARGS.
    ///
    /// A malformed argument is not a filesystem error: the call could not be
    /// parsed at all, so there is no `nfsstat3` that honestly describes it, and
    /// RFC 5531 already has a status that says exactly this. Everything else —
    /// including a well-formed handle we simply do not recognise — stays an
    /// NFS-level error.
    func rethrowIfMalformed(_ error: any Error) throws {
        if error is XDRError { throw RPCProgramError.garbageArguments }
    }

    /// Encodes `status` followed by a `wcc_data`, the failure shape shared by
    /// every modifying procedure.
    private func wccReply(_ status: NFSStatus, _ wcc: NFSWccData) -> [UInt8] {
        var e = XDREncoder()
        e.uint32(status.rawValue)
        wcc.encode(into: &e)
        return e.bytes
    }

    // MARK: - GETATTR, SETATTR

    private func getAttr(_ d: inout XDRDecoder) async throws -> [UInt8] {
        var e = XDREncoder()
        do {
            let node = try decodeHandle(&d)
            let attributes = try await vfs.getAttributes(node)
            e.uint32(NFSStatus.ok.rawValue)
            NFSFileAttributes(attributes, fsid: export.fsid).encode(into: &e)
        } catch {
            try rethrowIfMalformed(error)
            e = XDREncoder()
            e.uint32(nfsStatus(for: error).rawValue)
        }
        return e.bytes
    }

    private func setAttr(_ d: inout XDRDecoder) async throws -> [UInt8] {
        var node: NodeID?
        var before: NFSWccAttributes?
        do {
            let target = try decodeHandle(&d)
            node = target
            let requested = try NFSSetAttributes.decode(&d)
            // `guard` is a bool followed by the ctime the client last saw. It
            // exists so a chmod does not clobber a change made by someone else
            // between the client's GETATTR and its SETATTR.
            let guardTime = try d.optional { try NFSTime.decode(&$0) }

            let current = try await vfs.getAttributes(target)
            before = NFSWccAttributes(current)
            if let guardTime, NFSTime(current.changeTime) != guardTime {
                throw NFSStatus.notSync.failure
            }
            try requireWritable()

            if !requested.isEmpty {
                let times = requested.resolvedTimes(now: FileTime.now())
                _ = try await vfs.setAttributes(
                    target,
                    permissions: requested.mode.map { UInt16(truncatingIfNeeded: $0 & 0o7777) },
                    uid: requested.uid,
                    gid: requested.gid,
                    size: requested.size,
                    accessTime: times.access,
                    modifyTime: times.modify)
            }
            let after = await postAttributes(target)
            return wccReply(.ok, NFSWccData(before: before, after: after))
        } catch {
            try rethrowIfMalformed(error)
            let after = await postAttributes(node)
            return wccReply(nfsStatus(for: error), NFSWccData(before: before, after: after))
        }
    }

    // MARK: - LOOKUP, ACCESS, READLINK

    private func lookup(_ d: inout XDRDecoder) async throws -> [UInt8] {
        var directory: NodeID?
        var e = XDREncoder()
        do {
            let parent = try decodeHandle(&d)
            directory = parent
            let name = try decodeName(&d)
            let (node, attributes) = try await vfs.lookup(parent: parent, name: name)
            e.uint32(NFSStatus.ok.rawValue)
            e.opaqueVariable(handleBytes(node))
            encodePostOpAttributes(&e, NFSFileAttributes(attributes, fsid: export.fsid))
            encodePostOpAttributes(&e, await postAttributes(parent))
        } catch {
            try rethrowIfMalformed(error)
            e = XDREncoder()
            e.uint32(nfsStatus(for: error).rawValue)
            encodePostOpAttributes(&e, await postAttributes(directory))
        }
        return e.bytes
    }

    private func access(_ d: inout XDRDecoder, _ context: RPCContext) async throws -> [UInt8] {
        var e = XDREncoder()
        do {
            let node = try decodeHandle(&d)
            let requested = NFSAccess(rawValue: try d.uint32())
            let attributes = try await vfs.getAttributes(node)
            let granted = nfsAccessMask(
                for: attributes, credentials: context.credentials, readOnly: export.isReadOnly)
            e.uint32(NFSStatus.ok.rawValue)
            encodePostOpAttributes(&e, NFSFileAttributes(attributes, fsid: export.fsid))
            // Only the bits the client asked about may be reported back.
            e.uint32(granted.intersection(requested).rawValue)
        } catch {
            try rethrowIfMalformed(error)
            e = XDREncoder()
            e.uint32(nfsStatus(for: error).rawValue)
            e.bool(false)
        }
        return e.bytes
    }

    private func readlink(_ d: inout XDRDecoder) async throws -> [UInt8] {
        var node: NodeID?
        var e = XDREncoder()
        do {
            let target = try decodeHandle(&d)
            node = target
            let attributes = try await vfs.getAttributes(target)
            guard attributes.type == .symlink else { throw NFSStatus.inval.failure }
            let path = try await vfs.readlink(target)
            e.uint32(NFSStatus.ok.rawValue)
            encodePostOpAttributes(&e, NFSFileAttributes(attributes, fsid: export.fsid))
            e.string(path)
        } catch {
            try rethrowIfMalformed(error)
            e = XDREncoder()
            e.uint32(nfsStatus(for: error).rawValue)
            encodePostOpAttributes(&e, await postAttributes(node))
        }
        return e.bytes
    }

    // MARK: - READ, WRITE, COMMIT

    private func read(_ d: inout XDRDecoder) async throws -> [UInt8] {
        var node: NodeID?
        var e = XDREncoder()
        do {
            let target = try decodeHandle(&d)
            node = target
            let offset = try d.uint64()
            // A client may ask for more than we advertised; clamping is
            // allowed and is safer than trusting the number.
            let count = min(Int(try d.uint32()), export.transferSize)
            let data = try await vfs.read(target, offset: offset, count: count)
            let attributes = try? await vfs.getAttributes(target)
            // EOF is "this read reached the end of the file", not "the read
            // was short": a short read in the middle of a file is legal and a
            // client that sees eof there truncates the file it is copying.
            let eof: Bool
            if let attributes {
                eof = offset &+ UInt64(data.count) >= attributes.size
            } else {
                eof = data.count < count
            }
            e.uint32(NFSStatus.ok.rawValue)
            encodePostOpAttributes(&e, attributes.map { NFSFileAttributes($0, fsid: export.fsid) })
            e.uint32(UInt32(truncatingIfNeeded: data.count))
            e.bool(eof)
            e.opaqueVariable(data)
        } catch {
            try rethrowIfMalformed(error)
            e = XDREncoder()
            e.uint32(nfsStatus(for: error).rawValue)
            encodePostOpAttributes(&e, await postAttributes(node))
        }
        return e.bytes
    }

    private func write(_ d: inout XDRDecoder) async throws -> [UInt8] {
        var node: NodeID?
        var before: NFSWccAttributes?
        do {
            let target = try decodeHandle(&d)
            node = target
            let offset = try d.uint64()
            let declared = try d.uint32()
            let stable = try d.uint32()
            let data = try d.opaqueVariable(limit: export.transferSize)
            guard Int(declared) == data.count else { throw NFSStatus.inval.failure }
            before = await wccBefore(target)
            try requireWritable()

            // UNSTABLE means the client will COMMIT later; anything else must
            // be durable before the reply. We report back the level actually
            // achieved, which is what lets a client skip the COMMIT.
            let wantsSync = stable != NFSConstants.unstable
            let written = try await vfs.write(target, offset: offset, data: data, sync: wantsSync)
            let after = await postAttributes(target)

            var e = XDREncoder()
            e.uint32(NFSStatus.ok.rawValue)
            NFSWccData(before: before, after: after).encode(into: &e)
            e.uint32(UInt32(truncatingIfNeeded: written))
            e.uint32(wantsSync ? NFSConstants.fileSync : NFSConstants.unstable)
            e.opaqueFixed(export.boot.bytes)
            return e.bytes
        } catch {
            try rethrowIfMalformed(error)
            let after = await postAttributes(node)
            return wccReply(nfsStatus(for: error), NFSWccData(before: before, after: after))
        }
    }

    private func commit(_ d: inout XDRDecoder) async throws -> [UInt8] {
        var node: NodeID?
        var before: NFSWccAttributes?
        do {
            let target = try decodeHandle(&d)
            node = target
            _ = try d.uint64()  // offset: we always flush the whole file
            _ = try d.uint32()  // count
            before = await wccBefore(target)
            try requireWritable()
            try await vfs.fsync(target)
            var e = XDREncoder()
            e.uint32(NFSStatus.ok.rawValue)
            NFSWccData(before: before, after: await postAttributes(target)).encode(into: &e)
            // The same verifier every WRITE returned. A client that sees it
            // change knows the server restarted and that its unstable writes
            // are gone, so it replays them.
            e.opaqueFixed(export.boot.bytes)
            return e.bytes
        } catch {
            try rethrowIfMalformed(error)
            let after = await postAttributes(node)
            return wccReply(nfsStatus(for: error), NFSWccData(before: before, after: after))
        }
    }

    // MARK: - Creation

    /// The result shape shared by CREATE, MKDIR, SYMLINK and MKNOD:
    /// an optional handle, the new object's attributes, and the directory's
    /// wcc data.
    private func creationReply(
        _ status: NFSStatus, node: NodeID?, attributes: NFSFileAttributes?, directory: NFSWccData
    ) -> [UInt8] {
        var e = XDREncoder()
        e.uint32(status.rawValue)
        guard status == .ok else {
            directory.encode(into: &e)
            return e.bytes
        }
        if let node {
            e.bool(true)
            e.opaqueVariable(handleBytes(node))
        } else {
            e.bool(false)
        }
        encodePostOpAttributes(&e, attributes)
        directory.encode(into: &e)
        return e.bytes
    }

    private func create(_ d: inout XDRDecoder) async throws -> [UInt8] {
        var parent: NodeID?
        var before: NFSWccAttributes?
        do {
            let directory = try decodeHandle(&d)
            parent = directory
            let name = try decodeName(&d)
            let how = try d.uint32()
            var requested = NFSSetAttributes()
            var verifier: [UInt8]?
            switch how {
            case 0, 1:  // UNCHECKED, GUARDED
                requested = try NFSSetAttributes.decode(&d)
            case 2:  // EXCLUSIVE carries a verifier in place of sattr3
                verifier = try d.opaqueFixed(NFSConstants.verifierSize)
            default:
                throw NFSStatus.inval.failure
            }
            before = await wccBefore(directory)
            try requireWritable()

            let existing = try? await vfs.lookup(parent: directory, name: name)
            if let existing {
                switch how {
                case 0:
                    // UNCHECKED: reuse the file, but honour the requested
                    // attributes — this is how a client implements O_TRUNC.
                    let attributes = try await applySetAttributes(requested, to: existing.node)
                        ?? existing.attributes
                    return creationReply(
                        .ok, node: existing.node,
                        attributes: NFSFileAttributes(attributes, fsid: export.fsid),
                        directory: NFSWccData(before: before, after: await postAttributes(directory)))
                case 2 where exclusiveVerifiers[existing.node] == verifier:
                    // A retransmitted EXCLUSIVE create must look like it
                    // succeeded, or the client reports a spurious EEXIST for a
                    // file it actually created.
                    return creationReply(
                        .ok, node: existing.node,
                        attributes: NFSFileAttributes(existing.attributes, fsid: export.fsid),
                        directory: NFSWccData(before: before, after: await postAttributes(directory)))
                default:
                    throw NFSStatus.exist.failure
                }
            }

            let permissions = UInt16(truncatingIfNeeded: (requested.mode ?? 0o644) & 0o7777)
            let created = try await vfs.create(
                parent: directory, name: name, permissions: permissions)
            if let verifier { exclusiveVerifiers[created.node] = verifier }
            var attributes = created.attributes
            var remaining = requested
            remaining.mode = nil  // already applied by create
            if let updated = try await applySetAttributes(remaining, to: created.node) {
                attributes = updated
            }
            return creationReply(
                .ok, node: created.node,
                attributes: NFSFileAttributes(attributes, fsid: export.fsid),
                directory: NFSWccData(before: before, after: await postAttributes(directory)))
        } catch {
            try rethrowIfMalformed(error)
            let after = await postAttributes(parent)
            return creationReply(nfsStatus(for: error), node: nil, attributes: nil,
                                 directory: NFSWccData(before: before, after: after))
        }
    }

    private func mkdir(_ d: inout XDRDecoder) async throws -> [UInt8] {
        var parent: NodeID?
        var before: NFSWccAttributes?
        do {
            let directory = try decodeHandle(&d)
            parent = directory
            let name = try decodeName(&d)
            let requested = try NFSSetAttributes.decode(&d)
            before = await wccBefore(directory)
            try requireWritable()

            let permissions = UInt16(truncatingIfNeeded: (requested.mode ?? 0o755) & 0o7777)
            let created = try await vfs.mkdir(parent: directory, name: name, permissions: permissions)
            var attributes = created.attributes
            var remaining = requested
            remaining.mode = nil
            if let updated = try await applySetAttributes(remaining, to: created.node) {
                attributes = updated
            }
            return creationReply(
                .ok, node: created.node,
                attributes: NFSFileAttributes(attributes, fsid: export.fsid),
                directory: NFSWccData(before: before, after: await postAttributes(directory)))
        } catch {
            try rethrowIfMalformed(error)
            let after = await postAttributes(parent)
            return creationReply(nfsStatus(for: error), node: nil, attributes: nil,
                                 directory: NFSWccData(before: before, after: after))
        }
    }

    private func symlink(_ d: inout XDRDecoder) async throws -> [UInt8] {
        var parent: NodeID?
        var before: NFSWccAttributes?
        do {
            let directory = try decodeHandle(&d)
            parent = directory
            let name = try decodeName(&d)
            // symlinkdata3 puts the attributes *before* the target path.
            _ = try NFSSetAttributes.decode(&d)
            let target = try d.string(limit: NFSConstants.maximumPathLength)
            before = await wccBefore(directory)
            try requireWritable()
            guard export.supportsSymlinks else { throw NFSStatus.notsupp.failure }

            let created = try await vfs.symlink(parent: directory, name: name, target: target)
            return creationReply(
                .ok, node: created.node,
                attributes: NFSFileAttributes(created.attributes, fsid: export.fsid),
                directory: NFSWccData(before: before, after: await postAttributes(directory)))
        } catch {
            try rethrowIfMalformed(error)
            let after = await postAttributes(parent)
            return creationReply(nfsStatus(for: error), node: nil, attributes: nil,
                                 directory: NFSWccData(before: before, after: after))
        }
    }

    /// MKNOD is the one procedure we decline outright: 9P has no portable way
    /// to create a device node, and nothing on a macOS mount of a remote tree
    /// needs one.
    private func mknod(_ d: inout XDRDecoder) async throws -> [UInt8] {
        var parent: NodeID?
        var before: NFSWccAttributes?
        do {
            let directory = try decodeHandle(&d)
            parent = directory
            _ = try decodeName(&d)
            before = await wccBefore(directory)
            throw NFSStatus.notsupp.failure
        } catch {
            try rethrowIfMalformed(error)
            let after = await postAttributes(parent)
            return creationReply(nfsStatus(for: error), node: nil, attributes: nil,
                                 directory: NFSWccData(before: before, after: after))
        }
    }

    /// Applies whatever a `sattr3` asked for, returning the fresh attributes
    /// if anything changed.
    private func applySetAttributes(
        _ requested: NFSSetAttributes, to node: NodeID
    ) async throws -> FileAttributes? {
        guard !requested.isEmpty else { return nil }
        let times = requested.resolvedTimes(now: FileTime.now())
        return try await vfs.setAttributes(
            node,
            permissions: requested.mode.map { UInt16(truncatingIfNeeded: $0 & 0o7777) },
            uid: requested.uid,
            gid: requested.gid,
            size: requested.size,
            accessTime: times.access,
            modifyTime: times.modify)
    }

    // MARK: - Namespace changes

    private func remove(_ d: inout XDRDecoder, isDirectory: Bool) async throws -> [UInt8] {
        var parent: NodeID?
        var before: NFSWccAttributes?
        do {
            let directory = try decodeHandle(&d)
            parent = directory
            let name = try decodeName(&d)
            before = await wccBefore(directory)
            try requireWritable()
            try await vfs.remove(parent: directory, name: name, isDirectory: isDirectory)
            return wccReply(.ok, NFSWccData(before: before, after: await postAttributes(directory)))
        } catch {
            try rethrowIfMalformed(error)
            let after = await postAttributes(parent)
            return wccReply(nfsStatus(for: error), NFSWccData(before: before, after: after))
        }
    }

    private func rename(_ d: inout XDRDecoder) async throws -> [UInt8] {
        var source: NodeID?
        var destination: NodeID?
        var sourceBefore: NFSWccAttributes?
        var destinationBefore: NFSWccAttributes?

        func reply(_ status: NFSStatus) async -> [UInt8] {
            var e = XDREncoder()
            e.uint32(status.rawValue)
            let sourceAfter = await postAttributes(source)
            let destinationAfter = await postAttributes(destination)
            NFSWccData(before: sourceBefore, after: sourceAfter).encode(into: &e)
            NFSWccData(before: destinationBefore, after: destinationAfter).encode(into: &e)
            return e.bytes
        }

        do {
            let fromDirectory = try decodeHandle(&d)
            source = fromDirectory
            let fromName = try decodeName(&d)
            let toDirectory = try decodeHandle(&d)
            destination = toDirectory
            let toName = try decodeName(&d)
            sourceBefore = await wccBefore(fromDirectory)
            destinationBefore = await wccBefore(toDirectory)
            try requireWritable()
            try await vfs.rename(
                fromParent: fromDirectory, fromName: fromName,
                toParent: toDirectory, toName: toName)
            return await reply(.ok)
        } catch {
            try rethrowIfMalformed(error)
            return await reply(nfsStatus(for: error))
        }
    }

    private func link(_ d: inout XDRDecoder) async throws -> [UInt8] {
        var file: NodeID?
        var directory: NodeID?
        var before: NFSWccAttributes?

        func reply(_ status: NFSStatus, attributes: NFSFileAttributes?) async -> [UInt8] {
            var e = XDREncoder()
            e.uint32(status.rawValue)
            encodePostOpAttributes(&e, attributes)
            let after = await postAttributes(directory)
            NFSWccData(before: before, after: after).encode(into: &e)
            return e.bytes
        }

        do {
            let target = try decodeHandle(&d)
            file = target
            let parent = try decodeHandle(&d)
            directory = parent
            let name = try decodeName(&d)
            before = await wccBefore(parent)
            try requireWritable()
            guard export.supportsHardLinks else { throw NFSStatus.notsupp.failure }
            let attributes = try await vfs.link(parent: parent, name: name, to: target)
            return await reply(.ok, attributes: NFSFileAttributes(attributes, fsid: export.fsid))
        } catch {
            try rethrowIfMalformed(error)
            let attributes = await postAttributes(file)
            return await reply(nfsStatus(for: error), attributes: attributes)
        }
    }

    // MARK: - Volume information

    private func fsstat(_ d: inout XDRDecoder) async throws -> [UInt8] {
        var node: NodeID?
        var e = XDREncoder()
        do {
            let target = try decodeHandle(&d)
            node = target
            let stats = try await vfs.statfs()
            let blockSize = UInt64(stats.blockSize == 0 ? 4096 : stats.blockSize)
            // A 9P server that reports nothing would make the volume look
            // full, and macOS refuses to write to a full volume before it even
            // tries. Substitute a plausible large size instead.
            let total = stats.totalBlocks == 0
                ? export.options.fallbackTotalBytes : stats.totalBlocks * blockSize
            let free = stats.totalBlocks == 0
                ? export.options.fallbackTotalBytes / 2 : stats.freeBlocks * blockSize
            let available = stats.totalBlocks == 0
                ? export.options.fallbackTotalBytes / 2 : stats.availableBlocks * blockSize

            e.uint32(NFSStatus.ok.rawValue)
            encodePostOpAttributes(&e, await postAttributes(target))
            e.uint64(total)
            e.uint64(free)
            e.uint64(available)
            e.uint64(stats.totalFiles == 0 ? 1 << 20 : stats.totalFiles)
            e.uint64(stats.freeFiles == 0 ? 1 << 20 : stats.freeFiles)
            e.uint64(stats.freeFiles == 0 ? 1 << 20 : stats.freeFiles)
            // `invarsec`: how long these numbers are guaranteed not to change.
            // Zero means "no guarantee", which is the only honest answer for a
            // tree someone else may be writing to.
            e.uint32(0)
        } catch {
            try rethrowIfMalformed(error)
            e = XDREncoder()
            e.uint32(nfsStatus(for: error).rawValue)
            encodePostOpAttributes(&e, await postAttributes(node))
        }
        return e.bytes
    }

    private func fsinfo(_ d: inout XDRDecoder) async throws -> [UInt8] {
        var node: NodeID?
        var e = XDREncoder()
        do {
            let target = try decodeHandle(&d)
            node = target
            let size = UInt32(export.transferSize)
            e.uint32(NFSStatus.ok.rawValue)
            encodePostOpAttributes(&e, await postAttributes(target))
            e.uint32(size)   // rtmax
            e.uint32(size)   // rtpref
            e.uint32(512)    // rtmult: reads should be a multiple of this
            e.uint32(size)   // wtmax
            e.uint32(size)   // wtpref
            e.uint32(512)    // wtmult
            e.uint32(size)   // dtpref: preferred READDIR byte count
            e.uint64(UInt64(Int64.max))  // maxfilesize
            // time_delta {0, 1}: we can represent nanoseconds, so a client may
            // set any timestamp it likes rather than rounding to seconds.
            e.uint32(0)
            e.uint32(1)

            var properties = NFSConstants.fsfHomogeneous | NFSConstants.fsfCanSetTime
            if export.supportsHardLinks { properties |= NFSConstants.fsfLink }
            if export.supportsSymlinks { properties |= NFSConstants.fsfSymlink }
            e.uint32(properties)
        } catch {
            try rethrowIfMalformed(error)
            e = XDREncoder()
            e.uint32(nfsStatus(for: error).rawValue)
            encodePostOpAttributes(&e, await postAttributes(node))
        }
        return e.bytes
    }

    private func pathconf(_ d: inout XDRDecoder) async throws -> [UInt8] {
        var node: NodeID?
        var e = XDREncoder()
        do {
            let target = try decodeHandle(&d)
            node = target
            let stats = try? await vfs.statfs()
            e.uint32(NFSStatus.ok.rawValue)
            encodePostOpAttributes(&e, await postAttributes(target))
            // linkmax of 1 is how a server says "no hard links"; claiming more
            // than the 9P dialect can deliver produces failures much later.
            e.uint32(export.supportsHardLinks ? 32000 : 1)
            e.uint32(stats.map { $0.maximumNameLength } ?? 255)
            e.bool(true)   // no_trunc: an over-long name is an error, not a truncation
            e.bool(true)   // chown_restricted
            e.bool(false)  // case_insensitive
            e.bool(true)   // case_preserving
        } catch {
            try rethrowIfMalformed(error)
            e = XDREncoder()
            e.uint32(nfsStatus(for: error).rawValue)
            encodePostOpAttributes(&e, await postAttributes(node))
        }
        return e.bytes
    }
}
