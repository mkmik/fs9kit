// Compiled only when FS9KIT_FSKIT is defined, which the Xcode project sets and
// SwiftPM does not.
//
// `canImport(FSKit)` is not a strong enough gate: the framework exists in the
// macOS 15.4 SDK too, but there it has no FSGenericURLResource — the class that
// makes it possible to mount something with no block device behind it — and its
// protocol reply handlers are not Sendable. Compiling this against that SDK
// fails on both counts. The whole backend needs macOS 26 or later, so it is
// gated on a flag the macOS 26 build turns on rather than on the framework
// merely being present.
#if FS9KIT_FSKIT && canImport(FSKit)
import Foundation
import FSKit
import os
import FS9Core
import NineP
import NinePClient

/// One mounted 9P tree.
///
/// Every method is the completion-handler form of the `FSVolume.*Operations`
/// protocols, because all the real work is a network round trip and FSKit's
/// reply handlers are the shape that lets it be one. Each hands off to a `Task`
/// that talks to `NineVFS` — the actor that owns fids, node numbers and the
/// attribute cache — and then replies.
///
/// Nothing here caches anything `NineVFS` already caches. The one exception is
/// `volumeStatistics`, which FSKit reads *synchronously* and which costs a
/// `Tstatfs` round trip; see `refreshStatistics()`.
@available(macOS 26.0, *)
final class FS9Volume: FSVolume, @unchecked Sendable {
    let vfs: NineVFS
    let spec: MountSpec

    private let items = FS9ItemTable<FS9Item>()
    private let rootItem: FS9Item
    private let stateLock = NSLock()
    private var cachedStatistics: FilesystemStats
    private var isShutDown = false

    init(volumeID: FSVolume.Identifier, spec: MountSpec, vfs: NineVFS, statistics: FilesystemStats) {
        self.vfs = vfs
        self.spec = spec
        self.cachedStatistics = statistics
        self.rootItem = FS9Item(
            node: NineVFS.rootNode, name: "/", kind: .directory, parent: nil)
        super.init(volumeID: volumeID, volumeName: FSFileName(string: spec.volumeName))
        _ = items.item(for: NineVFS.rootNode) { [rootItem] in rootItem }
    }

    private var readOnly: Bool { spec.readOnly }

    // MARK: - Item interning

    private func item(node: NodeID, name: String, kind: FS9ItemKind, parent: NodeID?) -> FS9Item {
        let item = items.item(for: node) {
            FS9Item(node: node, name: name, kind: kind, parent: parent)
        }
        item.update(name: name, parent: .some(parent), kind: kind)
        return item
    }

    /// Rejects an `FSItem` that is not ours or that names a node we have
    /// forgotten. FSKit should never do either; a module that trusts it anyway
    /// crashes instead of returning an errno.
    private func resolve(_ item: FSItem) throws -> FS9Item {
        guard let item = item as? FS9Item else {
            throw FSError(EINVAL, "item does not belong to this volume")
        }
        return item
    }

    /// Fetches attributes and shapes them the way FSKit wants them.
    private func attributes(of item: FS9Item) async throws -> FS9ItemAttributes {
        let attributes = try await vfs.getAttributes(item.node)
        item.update(kind: FS9ItemKind(attributes.type))
        return FS9ItemAttributes(attributes, parent: item.parent)
    }

    /// Refreshes the statfs snapshot in the background.
    ///
    /// `volumeStatistics` is a synchronous property and 9P `Tstatfs` is a round
    /// trip, so the answer has to be pre-computed. Stale free-space numbers are
    /// the accepted cost; the alternative is blocking an FSKit thread on the
    /// network inside a property getter.
    func refreshStatistics() {
        Task { [self] in
            guard let stats = try? await vfs.statfs() else { return }
            stateLock.withLock { cachedStatistics = stats }
        }
    }

    /// Tears the session down once, however FSKit chooses to end the mount.
    private func shutdown() async {
        let alreadyDone = stateLock.withLock { () -> Bool in
            if isShutDown { return true }
            isShutDown = true
            return false
        }
        guard !alreadyDone else { return }
        for item in items.drain() where item.isOpen {
            await vfs.closeHandle(item.node)
        }
        await vfs.shutdown()
        Logger.fs9kit.info("volume \(self.spec.canonicalTarget, privacy: .public) torn down")
    }
}

// MARK: - FSVolume.PathConfOperations

@available(macOS 26.0, *)
extension FS9Volume: FSVolume.PathConfOperations {
    /// 9P2000.L has `Tlink`, so hard links exist; the ceiling is the server's
    /// and it never tells us. `LINK_MAX` on the platforms 9P servers run on.
    var maximumLinkCount: Int { 32767 }

    /// The 9P wire format counts a name in bytes with a 16-bit length, but every
    /// server behind it is a POSIX one.
    var maximumNameLength: Int { 255 }

    /// Advertised, and also enforced in `setAttributes`: FSKit does not act on
    /// this flag (FB24419911), so a module that only advertises it lets any
    /// user chown any file.
    var restrictsOwnershipChanges: Bool { true }

    /// A too-long name is an error, not something to silently shorten — a
    /// truncating filesystem loses files.
    var truncatesLongNames: Bool { false }

    var maximumFileSizeInBits: Int { 64 }
}

// MARK: - FSVolume.Operations

@available(macOS 26.0, *)
extension FS9Volume: FSVolume.Operations {

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsPersistentObjectIDs = true
        capabilities.supports64BitObjectIDs = true
        capabilities.supports2TBFiles = true
        capabilities.supportsSymbolicLinks = true
        // Only the Linux dialect has Tlink; base 9P2000 and 9P2000.u cannot
        // make a hard link at all, so do not claim it.
        capabilities.supportsHardLinks = vfs.protocolVersion.isLinux
        capabilities.supportsHiddenFiles = true
        capabilities.supportsJournal = false
        capabilities.supportsActiveJournal = false
        // 9P has no way to ask about holes, so every file reads as dense.
        capabilities.supportsSparseFiles = false
        // Every statfs is a round trip; claiming otherwise invites the kernel
        // to call it on a hot path.
        capabilities.supportsFastStatFS = false
        capabilities.doesNotSupportImmutableFiles = true
        capabilities.doesNotSupportSettingFilePermissions = readOnly
        // Servers are overwhelmingly case-sensitive, and guessing "insensitive"
        // on a sensitive server hides files whose names differ only in case.
        capabilities.caseFormat = .sensitive
        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        let stats = stateLock.withLock { cachedStatistics }
        let result = FSStatFSResult(fileSystemTypeName: "fs9kit")
        result.blockSize = Int(stats.blockSize)
        // The largest payload that fits in one 9P message, so the kernel's
        // preferred I/O size matches what we can actually do in one round trip.
        result.ioSize = vfs.preferredIOSize
        result.totalBlocks = stats.totalBlocks
        result.freeBlocks = stats.freeBlocks
        result.availableBlocks = stats.availableBlocks
        result.usedBlocks = stats.totalBlocks >= stats.freeBlocks
            ? stats.totalBlocks - stats.freeBlocks : 0
        result.totalFiles = stats.totalFiles
        result.freeFiles = stats.freeFiles
        return result
    }

    func activate(options: FSTaskOptions, replyHandler reply: @escaping @Sendable (FSItem?, (any Error)?) -> Void) {
        // Returns the root and nothing else. Anything that can fail — dialling
        // the server, the 9P attach — has already happened in `loadResource`,
        // because a throw from here wedges the resource URL until `fskitd` is
        // killed (FB24419932) and the usual trigger is a bad hostname.
        Logger.fs9kit.info("activate \(self.spec.canonicalTarget, privacy: .public)")
        refreshStatistics()
        reply(rootItem, nil)
    }

    func deactivate(options: FSDeactivateOptions = [], replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        Task { [self] in
            await shutdown()
            reply(nil)
        }
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping @Sendable () -> Void) {
        Task { [self] in
            await shutdown()
            reply()
        }
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        // On a URL-backed volume FSKit never calls this (FB24419870): fsync(2),
        // F_FULLFSYNC and sync(8) all return success without reaching the
        // module. It is implemented anyway so that durability works the day the
        // bug is fixed, and so a `synchronize` from some other path is honoured.
        Task { [self] in
            var firstFailure: (any Error)?
            for item in items.all() where item.isOpen {
                do { try await vfs.fsync(item.node) }
                catch { firstFailure = firstFailure ?? error }
            }
            reply(firstFailure.map(fs9Error))
        }
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        guard let item = try? resolve(item) else { return reply(fs9Error(errno: EINVAL)) }
        guard item !== rootItem else { return reply(nil) }
        items.remove(item.node)
        Task { [self] in
            await vfs.closeHandle(item.node)
            reply(nil)
        }
    }

    func lookupItem(
        named name: FSFileName, inDirectory directory: FSItem,
        replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        do {
            let directory = try resolve(directory)
            guard directory.isDirectory else { throw FSError.notDirectory }
            let name = try name.fs9String()
            Task { [self] in
                do {
                    // An ENOENT from here is cached by the kernel for the
                    // vnode's lifetime (FB24419825): a file the server grows
                    // afterwards will be listed by `ls` and still fail to open.
                    // Nothing the module can do fixes it; remounting does.
                    let (node, attributes) = try await vfs.lookup(parent: directory.node, name: name)
                    let item = self.item(
                        node: node, name: name,
                        kind: FS9ItemKind(attributes.type), parent: directory.node)
                    reply(item, FSFileName(string: name), nil)
                } catch {
                    reply(nil, nil, fs9Error(error))
                }
            }
        } catch {
            reply(nil, nil, fs9Error(error))
        }
    }

    func getAttributes(
        _ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem,
        replyHandler reply: @escaping @Sendable (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        // `desiredAttributes` is deliberately ignored: everything is filled in
        // regardless. See `FSItem.Attributes.init(fs9:)`.
        do {
            let item = try resolve(item)
            Task { [self] in
                do {
                    reply(FSItem.Attributes(fs9: try await attributes(of: item)), nil)
                } catch {
                    reply(nil, fs9Error(error))
                }
            }
        } catch {
            reply(nil, fs9Error(error))
        }
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest, on item: FSItem,
        replyHandler reply: @escaping @Sendable (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        do {
            let item = try resolve(item)
            // FSKit never reads back `consumedAttributes` (FB24419894), so a
            // caller cannot tell which of these actually took. Refusing the
            // whole request when one field is impossible is the honest answer.
            let request = try newAttributes.fs9Requested.validated(
                readOnly: readOnly, isPrivileged: false)
            guard !request.isEmpty else {
                // Nothing to change. Answer with what is already true rather
                // than with an error: chmod(2) with no effective change is not
                // a failure.
                Task { [self] in
                    do { reply(FSItem.Attributes(fs9: try await attributes(of: item)), nil) }
                    catch { reply(nil, fs9Error(error)) }
                }
                return
            }
            Task { [self] in
                do {
                    _ = try await vfs.setAttributes(
                        item.node,
                        permissions: request.mode.map(fs9PermissionBits),
                        uid: request.uid, gid: request.gid, size: request.size,
                        accessTime: request.accessTime, modifyTime: request.modifyTime)
                    reply(FSItem.Attributes(fs9: try await attributes(of: item)), nil)
                } catch {
                    reply(nil, fs9Error(error))
                }
            }
        } catch {
            reply(nil, fs9Error(error))
        }
    }

    func enumerateDirectory(
        _ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker,
        replyHandler reply: @escaping @Sendable (FSDirectoryVerifier, (any Error)?) -> Void
    ) {
        // Verifier zero throughout: 9P gives no directory generation number, so
        // there is nothing to verify a cookie against and claiming otherwise
        // would make the kernel restart listings it did not need to.
        let noVerifier = FSDirectoryVerifier(0)
        do {
            let directory = try resolve(directory)
            guard directory.isDirectory else { throw FSError.notDirectory }
            let wantsAttributes = attributes != nil
            let packer = UncheckedBox(packer)
            Task { [self] in
                do {
                    var offset = FS9DirectoryPlanner.offset(forCookie: cookie.rawValue)
                    while true {
                        let chunk = try await vfs.readDirectory(directory.node, cookie: offset)
                        for entry in FS9DirectoryPlanner.plan(chunk) {
                            var packed: FSItem.Attributes?
                            if wantsAttributes,
                               let attributes = try? await vfs.getAttributes(entry.node) {
                                packed = FSItem.Attributes(
                                    fs9: FS9ItemAttributes(attributes, parent: directory.node))
                            }
                            let accepted = packer.value.packEntry(
                                name: FSFileName(string: entry.name),
                                itemType: entry.kind.fsItemType,
                                itemID: .fs9(entry.itemID),
                                nextCookie: FSDirectoryCookie(entry.nextCookie),
                                attributes: packed)
                            // The packer's buffer is full. Stop here; the kernel
                            // comes back with the cookie of the last entry that
                            // fitted.
                            if !accepted { return reply(noVerifier, nil) }
                        }
                        guard !FS9DirectoryPlanner.isFinished(chunk),
                              let next = FS9DirectoryPlanner.resumeCookie(after: chunk),
                              next != offset
                        else { break }
                        offset = next
                    }
                    reply(noVerifier, nil)
                } catch {
                    reply(noVerifier, fs9Error(error))
                }
            }
        } catch {
            reply(noVerifier, fs9Error(error))
        }
    }

    func readSymbolicLink(
        _ item: FSItem, replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void
    ) {
        do {
            let item = try resolve(item)
            Task { [self] in
                do {
                    reply(FSFileName(string: try await vfs.readlink(item.node)), nil)
                } catch {
                    reply(nil, fs9Error(error))
                }
            }
        } catch {
            reply(nil, fs9Error(error))
        }
    }

    func createItem(
        named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        do {
            guard !readOnly else { throw fs9ReadOnlyError() }
            let directory = try resolve(directory)
            guard directory.isDirectory else { throw FSError.notDirectory }
            let name = try name.fs9String()
            let kind = FS9ItemKind(type)
            let requested = newAttributes.fs9Requested
            // A caller that names no mode gets the conventional default; the
            // server applies its own umask on top.
            let permissions = requested.mode.map(fs9PermissionBits)
                ?? (kind == .directory ? 0o755 : 0o644)
            Task { [self] in
                do {
                    let created: (node: NodeID, attributes: FileAttributes)
                    switch kind {
                    case .file:
                        created = try await vfs.create(
                            parent: directory.node, name: name, permissions: permissions)
                    case .directory:
                        created = try await vfs.mkdir(
                            parent: directory.node, name: name, permissions: permissions)
                    default:
                        // 9P2000.L has Tmknod, but the client does not expose it
                        // and neither .u nor base 9P2000 can make a device node
                        // or a socket at all.
                        throw FSError(ENOTSUP, "cannot create \(kind) over 9P")
                    }
                    let item = self.item(
                        node: created.node, name: name,
                        kind: FS9ItemKind(created.attributes.type), parent: directory.node)
                    self.refreshStatistics()
                    reply(item, FSFileName(string: name), nil)
                } catch {
                    reply(nil, nil, fs9Error(error))
                }
            }
        } catch {
            reply(nil, nil, fs9Error(error))
        }
    }

    func createSymbolicLink(
        named name: FSFileName, inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName,
        replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        do {
            guard !readOnly else { throw fs9ReadOnlyError() }
            let directory = try resolve(directory)
            let name = try name.fs9String()
            let target = try contents.fs9String()
            Task { [self] in
                do {
                    let created = try await vfs.symlink(
                        parent: directory.node, name: name, target: target)
                    let item = self.item(
                        node: created.node, name: name, kind: .symlink, parent: directory.node)
                    reply(item, FSFileName(string: name), nil)
                } catch {
                    reply(nil, nil, fs9Error(error))
                }
            }
        } catch {
            reply(nil, nil, fs9Error(error))
        }
    }

    func createLink(
        to item: FSItem, named name: FSFileName, inDirectory directory: FSItem,
        replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void
    ) {
        do {
            guard !readOnly else { throw fs9ReadOnlyError() }
            guard vfs.protocolVersion.isLinux else {
                throw FSError(ENOTSUP, "hard links need 9P2000.L")
            }
            let target = try resolve(item)
            let directory = try resolve(directory)
            let name = try name.fs9String()
            Task { [self] in
                do {
                    _ = try await vfs.link(parent: directory.node, name: name, to: target.node)
                    reply(FSFileName(string: name), nil)
                } catch {
                    reply(nil, fs9Error(error))
                }
            }
        } catch {
            reply(nil, fs9Error(error))
        }
    }

    func removeItem(
        _ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem,
        replyHandler reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        do {
            guard !readOnly else { throw fs9ReadOnlyError() }
            let item = try resolve(item)
            let directory = try resolve(directory)
            let name = try name.fs9String()
            Task { [self] in
                do {
                    // 9P has no open-unlink: the server drops the file the
                    // moment it is unlinked, whoever still has it open. FSKit
                    // can emulate that for us — see `enableOpenUnlinkEmulation`
                    // on the file system object.
                    try await vfs.remove(
                        parent: directory.node, name: name, isDirectory: item.isDirectory)
                    self.items.remove(item.node)
                    self.refreshStatistics()
                    reply(nil)
                } catch {
                    reply(fs9Error(error))
                }
            }
        } catch {
            reply(fs9Error(error))
        }
    }

    func renameItem(
        _ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
        to destinationName: FSFileName, inDirectory destinationDirectory: FSItem,
        overItem: FSItem?,
        replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void
    ) {
        do {
            guard !readOnly else { throw fs9ReadOnlyError() }
            let item = try resolve(item)
            let source = try resolve(sourceDirectory)
            let destination = try resolve(destinationDirectory)
            let from = try sourceName.fs9String()
            let to = try destinationName.fs9String()
            let clobbered = try overItem.map(resolve)
            Task { [self] in
                do {
                    // WARNING: `renameatx_np(RENAME_SWAP)` arrives here
                    // indistinguishable from an ordinary clobbering rename —
                    // FSKit passes no flags (FB24419773) — so a swap silently
                    // destroys the destination. There is nothing to check
                    // against; the only defence is not to promise atomic swap
                    // in the volume capabilities, which we do not.
                    try await vfs.rename(
                        fromParent: source.node, fromName: from,
                        toParent: destination.node, toName: to)
                    if let clobbered, clobbered !== item { self.items.remove(clobbered.node) }
                    item.update(name: to, parent: .some(destination.node))
                    reply(FSFileName(string: to), nil)
                } catch {
                    reply(nil, fs9Error(error))
                }
            }
        } catch {
            reply(nil, fs9Error(error))
        }
    }
}

// MARK: - FSVolume.OpenCloseOperations

@available(macOS 26.0, *)
extension FS9Volume: FSVolume.OpenCloseOperations {
    func openItem(
        _ item: FSItem, modes: FSVolume.OpenModes,
        replyHandler reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        do {
            let item = try resolve(item)
            // Validate here so `open(2)` fails at open time rather than at the
            // first read. `NineVFS` opens the fid lazily, so a server-side
            // permission error still arrives late; see the design note.
            _ = try ninePOpenFlags(
                for: FS9OpenModes(modes), isDirectory: item.isDirectory, readOnly: readOnly)
            _ = item.retainOpen()
            reply(nil)
        } catch {
            reply(fs9Error(error))
        }
    }

    func closeItem(
        _ item: FSItem, modes: FSVolume.OpenModes,
        replyHandler reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        guard let item = try? resolve(item) else { return reply(fs9Error(errno: EINVAL)) }
        guard item.releaseOpen() else { return reply(nil) }
        Task { [self] in
            // Last close: give the fid back. Servers have finite fid tables and
            // a long-lived mount that never clunks will exhaust them.
            await vfs.closeHandle(item.node)
            reply(nil)
        }
    }
}

// MARK: - FSVolume.ReadWriteOperations

@available(macOS 26.0, *)
extension FS9Volume: FSVolume.ReadWriteOperations {
    func read(
        from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer,
        replyHandler reply: @escaping @Sendable (Int, (any Error)?) -> Void
    ) {
        do {
            let item = try resolve(item)
            guard offset >= 0 else { throw FSError.invalidArgument }
            let buffer = UncheckedBox(buffer)
            Task { [self] in
                do {
                    let wanted = min(length, buffer.value.length)
                    let bytes = try await vfs.read(
                        item.node, offset: UInt64(offset), count: wanted)
                    let copied = buffer.value.withUnsafeMutableBytes { raw -> Int in
                        let count = min(bytes.count, raw.count)
                        guard count > 0 else { return 0 }
                        bytes.withUnsafeBytes { source in
                            UnsafeMutableRawBufferPointer(rebasing: raw[0..<count])
                                .copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<count]))
                        }
                        return count
                    }
                    reply(copied, nil)
                } catch {
                    reply(0, fs9Error(error))
                }
            }
        } catch {
            reply(0, fs9Error(error))
        }
    }

    func write(
        contents: Data, to item: FSItem, at offset: off_t,
        replyHandler reply: @escaping @Sendable (Int, (any Error)?) -> Void
    ) {
        do {
            guard !readOnly else { throw fs9ReadOnlyError() }
            let item = try resolve(item)
            guard offset >= 0 else { throw FSError.invalidArgument }
            let bytes = [UInt8](contents)
            Task { [self] in
                do {
                    let written = try await vfs.write(
                        item.node, offset: UInt64(offset), data: bytes)
                    reply(written, nil)
                } catch {
                    reply(0, fs9Error(error))
                }
            }
        } catch {
            reply(0, fs9Error(error))
        }
    }
}

// MARK: - FSVolume.ItemDeactivation

@available(macOS 26.0, *)
extension FS9Volume: FSVolume.ItemDeactivation {
    /// Ask to hear about every item going inactive. A 9P fid is server-side
    /// state with a hard limit, so learning early that nobody wants a file any
    /// more is worth the extra calls.
    var itemDeactivationPolicy: FSVolume.ItemDeactivationOptions { .always }

    func deactivateItem(
        _ item: FSItem, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        guard let item = try? resolve(item), item !== rootItem else { return reply(nil) }
        Task { [self] in
            // Drop the open fid but keep the item interned: FSKit may still
            // reclaim it, and `reclaimItem` is what forgets it for good.
            await vfs.closeHandle(item.node)
            reply(nil)
        }
    }
}
#endif
