import Foundation
import NineP
import NinePClient

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Our own identifier for a file in the mounted tree, used as its inode number.
///
/// 9P qid paths are supposed to be unique per server, but plenty of servers
/// derive them from something weaker, and both mount backends need identifiers
/// that stay valid for the life of the mount. So the VFS numbers files itself.
public typealias NodeID = UInt64

/// Tuning for the VFS layer.
public struct VFSOptions: Sendable {
    /// How long a cached attribute stays fresh. Zero disables the cache.
    public var attributeCacheDuration: Double
    /// How many unopened fids to keep walked before clunking the least
    /// recently used one. Servers have finite fid tables.
    public var maximumCachedFids: Int
    /// How long an idle open fid is kept before being clunked.
    public var openFidIdleTimeout: Double
    /// Reported as the owner of every file, overriding the server, when the
    /// server's uids are meaningless on this machine.
    public var forcedUID: UInt32?
    public var forcedGID: UInt32?
    /// Refuse writes.
    public var readOnly: Bool

    public init(
        attributeCacheDuration: Double = 1.0,
        maximumCachedFids: Int = 256,
        openFidIdleTimeout: Double = 60,
        forcedUID: UInt32? = nil,
        forcedGID: UInt32? = nil,
        readOnly: Bool = false
    ) {
        self.attributeCacheDuration = attributeCacheDuration
        self.maximumCachedFids = maximumCachedFids
        self.openFidIdleTimeout = openFidIdleTimeout
        self.forcedUID = forcedUID
        self.forcedGID = forcedGID
        self.readOnly = readOnly
    }
}

/// One directory entry as the mount backends want it.
public struct DirectoryEntry: Sendable, Hashable {
    public var name: String
    public var node: NodeID
    public var type: FileType
    /// Opaque cookie: pass it back to resume the listing after this entry.
    public var cookie: UInt64

    public init(name: String, node: NodeID, type: FileType, cookie: UInt64) {
        self.name = name
        self.node = node
        self.type = type
        self.cookie = cookie
    }
}

/// A page of directory entries.
public struct DirectoryChunk: Sendable {
    public var entries: [DirectoryEntry]
    /// True when the server had nothing more to give.
    public var atEnd: Bool

    public init(entries: [DirectoryEntry], atEnd: Bool) {
        self.entries = entries
        self.atEnd = atEnd
    }
}

/// A filesystem view of a 9P server: stable node identifiers, cached fids and
/// attributes, and POSIX-shaped operations.
///
/// Both mount backends — the NFS loopback bridge and the FSKit extension — talk
/// to this and nothing below it, so protocol quirks and caching live in one
/// place and are tested once.
public actor NineVFS {
    private let client: NinePClient
    public nonisolated let options: VFSOptions

    /// The inode number of the mount root. Fixed at 1, as tradition and several
    /// NFS clients expect.
    public static let rootNode: NodeID = 1

    private final class Node {
        let id: NodeID
        var parent: NodeID?
        var name: String
        var qid: Qid
        /// A walked, unopened fid for this file.
        var fid: Fid?
        /// A fid opened for I/O, with the access it was opened for.
        var openFid: Fid?
        var openFlags: OpenFlags = []
        var openedAt: Double = 0
        var attributes: FileAttributes?
        var attributesExpireAt: Double = 0
        /// Name -> child node, populated by lookups and directory reads.
        var children: [String: NodeID] = [:]
        var lastUsed: UInt64 = 0
        /// Set once the file is removed, so a stale reference reports ESTALE
        /// rather than silently resolving to something new with the same name.
        var removed = false

        init(id: NodeID, parent: NodeID?, name: String, qid: Qid) {
            self.id = id
            self.parent = parent
            self.name = name
            self.qid = qid
        }
    }

    private var nodes: [NodeID: Node] = [:]
    private var nextNodeID: NodeID = 2
    private var clock: UInt64 = 0
    private var cachedFidCount = 0

    public init(client: NinePClient, options: VFSOptions = VFSOptions()) {
        self.client = client
        self.options = options
        let root = Node(id: Self.rootNode, parent: nil, name: "", qid: client.rootQid)
        root.fid = client.rootFid
        nodes[Self.rootNode] = root
    }

    public func shutdown() async {
        for node in nodes.values {
            if let f = node.openFid { await client.clunk(f) }
            if let f = node.fid, f != client.rootFid { await client.clunk(f) }
        }
        nodes.removeAll()
        client.close()
    }

    /// The dialect in use, so backends can advertise what they support.
    public nonisolated var protocolVersion: NinePVersion { client.version }
    /// Preferred transfer size, from the negotiated msize.
    public nonisolated var preferredIOSize: Int { client.ioSize }

    // MARK: - Node bookkeeping

    private func node(_ id: NodeID) throws -> Node {
        guard let n = nodes[id], !n.removed else { throw FSError.staleHandle }
        clock += 1
        n.lastUsed = clock
        return n
    }

    /// Returns the path from the root to `node`, as name components.
    private func path(of node: Node) -> [String] {
        var components: [String] = []
        var current: Node? = node
        while let n = current, let parent = n.parent {
            components.append(n.name)
            current = nodes[parent]
        }
        return components.reversed()
    }

    /// Returns a walked fid for `node`, walking it from the root if the cached
    /// one has been evicted.
    private func fid(for node: Node) async throws -> Fid {
        if let f = node.fid { return f }
        let components = path(of: node)
        let (fid, _) = try await client.walk(from: client.rootFid, to: components)
        node.fid = fid
        cachedFidCount += 1
        await evictFidsIfNeeded(keeping: node.id)
        return fid
    }

    /// Clunks the least recently used cached fids once we hold too many.
    private func evictFidsIfNeeded(keeping: NodeID) async {
        guard cachedFidCount > options.maximumCachedFids else { return }
        let victims = nodes.values
            .filter { $0.fid != nil && $0.id != keeping && $0.id != Self.rootNode }
            .sorted { $0.lastUsed < $1.lastUsed }
            .prefix(max(1, cachedFidCount - options.maximumCachedFids))
        for victim in victims {
            guard let f = victim.fid else { continue }
            victim.fid = nil
            cachedFidCount -= 1
            await client.clunk(f)
        }
    }

    /// Finds or creates the node for `name` under `parent`.
    private func adopt(parent: Node, name: String, qid: Qid) -> Node {
        if let existing = parent.children[name], let node = nodes[existing], !node.removed {
            // The server may have replaced the file behind the name; if the qid
            // changed, the old identity is gone.
            if node.qid.path == qid.path && node.qid.kind == qid.kind {
                node.qid = qid
                return node
            }
            forget(node)
        }
        let node = Node(id: nextNodeID, parent: parent.id, name: name, qid: qid)
        nextNodeID += 1
        nodes[node.id] = node
        parent.children[name] = node.id
        return node
    }

    /// Drops a node and everything under it, clunking whatever it held.
    private func forget(_ node: Node) {
        var stack = [node]
        while let n = stack.popLast() {
            for child in n.children.values {
                if let c = nodes[child] { stack.append(c) }
            }
            n.removed = true
            if let parent = n.parent, let p = nodes[parent], p.children[n.name] == n.id {
                p.children.removeValue(forKey: n.name)
            }
            nodes.removeValue(forKey: n.id)
            let openFid = n.openFid
            let pathFid = n.fid
            if pathFid != nil { cachedFidCount -= 1 }
            n.openFid = nil
            n.fid = nil
            // Clunking is fire-and-forget: the caller is usually in the middle
            // of an operation and cannot wait, and a leaked fid is recovered
            // when the session ends.
            Task { [client] in
                if let f = openFid { await client.clunk(f) }
                if let f = pathFid, f != client.rootFid { await client.clunk(f) }
            }
        }
    }

    private func now() -> Double { Date().timeIntervalSince1970 }

    private func apply(_ attrs: FileAttributes) -> FileAttributes {
        var a = attrs
        if let uid = options.forcedUID { a.uid = uid }
        if let gid = options.forcedGID { a.gid = gid }
        return a
    }

    private func cache(_ attrs: FileAttributes, on node: Node) -> FileAttributes {
        let final = apply(attrs)
        node.attributes = final
        node.attributesExpireAt = now() + options.attributeCacheDuration
        return final
    }

    // MARK: - Lookup and attributes

    public func root() -> NodeID { Self.rootNode }

    /// Resolves one path component.
    public func lookup(parent: NodeID, name: String) async throws -> (node: NodeID, attributes: FileAttributes) {
        guard !name.isEmpty, name != ".", !name.contains("/") else {
            throw FSError.invalidArgument
        }
        guard name != ".." else {
            let child = try node(parent)
            let up = child.parent ?? Self.rootNode
            return (up, try await getAttributes(up))
        }
        let parentNode = try node(parent)
        let parentFid = try await fid(for: parentNode)
        do {
            let (fid, qids) = try await client.walk(from: parentFid, to: [name])
            guard let qid = qids.last else {
                await client.clunk(fid)
                throw FSError.notFound
            }
            let child = adopt(parent: parentNode, name: name, qid: qid)
            if let old = child.fid, old != fid {
                await client.clunk(old)
                cachedFidCount -= 1
            }
            child.fid = fid
            cachedFidCount += 1
            let attrs = try await fetchAttributes(child)
            await evictFidsIfNeeded(keeping: child.id)
            return (child.id, attrs)
        } catch {
            throw FSError.from(error)
        }
    }

    /// Resolves a whole slash-separated path from the root. Convenience for
    /// tools and tests; the mount backends resolve one component at a time.
    public func resolve(_ path: String) async throws -> (node: NodeID, attributes: FileAttributes) {
        var current = Self.rootNode
        var attrs = try await getAttributes(current)
        for component in path.split(separator: "/").map(String.init) where component != "." {
            (current, attrs) = try await lookup(parent: current, name: component)
        }
        return (current, attrs)
    }

    public func getAttributes(_ id: NodeID) async throws -> FileAttributes {
        let n = try node(id)
        if let cached = n.attributes, now() < n.attributesExpireAt { return cached }
        return try await fetchAttributes(n)
    }

    private func fetchAttributes(_ n: Node) async throws -> FileAttributes {
        do {
            let fid = try await fid(for: n)
            let attr = try await client.getattr(fid)
            return cache(FileAttributes(fileID: n.id, attr: attr), on: n)
        } catch {
            throw FSError.from(error)
        }
    }

    /// Drops cached attributes for a node, forcing the next read to go to the
    /// server. Backends call this when they know something changed elsewhere.
    public func invalidate(_ id: NodeID) {
        nodes[id]?.attributesExpireAt = 0
    }

    public func setAttributes(
        _ id: NodeID,
        permissions: UInt16? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        size: UInt64? = nil,
        accessTime: FileTime? = nil,
        modifyTime: FileTime? = nil
    ) async throws -> FileAttributes {
        try checkWritable()
        let n = try node(id)
        do {
            // Truncation has to go through a fid the server considers open for
            // writing on some implementations, but setattr-on-a-walked-fid is
            // what the protocol specifies, so use the plain path fid.
            let fid = try await fid(for: n)
            try await client.setattr(
                fid,
                mode: permissions.map { UInt32($0) },
                uid: uid, gid: gid, size: size,
                atime: accessTime.map { (sec: $0.seconds, nsec: UInt64($0.nanoseconds)) },
                mtime: modifyTime.map { (sec: $0.seconds, nsec: UInt64($0.nanoseconds)) })
            n.attributesExpireAt = 0
            return try await fetchAttributes(n)
        } catch {
            throw FSError.from(error)
        }
    }

    private func checkWritable() throws {
        if options.readOnly { throw FSError(EROFS) }
    }

    // MARK: - Open fids

    /// Returns a fid open for at least `flags`, opening or re-opening as needed.
    private func openFid(for n: Node, flags: OpenFlags) async throws -> Fid {
        let wanted = flags.intersection([.read, .write])
        if let existing = n.openFid, n.openFlags.isSuperset(of: wanted) {
            n.openedAt = now()
            return existing
        }
        // Re-open with the union of what is already open and what is wanted, so
        // a file read then written does not need two fids.
        let combined = n.openFlags.union(wanted)
        let pathFid = try await fid(for: n)
        let scratch = try await client.clone(pathFid)
        do {
            _ = try await client.open(scratch, flags: combined)
        } catch {
            await client.clunk(scratch)
            // A file opened read-only on the server (or a read-only export)
            // should report the server's error, not a generic one.
            throw FSError.from(error)
        }
        if let old = n.openFid { await client.clunk(old) }
        n.openFid = scratch
        n.openFlags = combined
        n.openedAt = now()
        return scratch
    }

    /// Closes a node's open fid, if any. Backends call this on last close.
    public func closeHandle(_ id: NodeID) async {
        guard let n = nodes[id], let f = n.openFid else { return }
        n.openFid = nil
        n.openFlags = []
        await client.clunk(f)
    }

    // MARK: - I/O

    public func read(_ id: NodeID, offset: UInt64, count: Int) async throws -> [UInt8] {
        let n = try node(id)
        guard n.qid.kind.contains(.dir) == false else { throw FSError.isDirectory }
        do {
            let fid = try await openFid(for: n, flags: .read)
            return try await client.readFully(fid, offset: offset, count: count)
        } catch {
            throw FSError.from(error)
        }
    }

    @discardableResult
    public func write(_ id: NodeID, offset: UInt64, data: [UInt8], sync: Bool = false) async throws -> Int {
        try checkWritable()
        let n = try node(id)
        do {
            let fid = try await openFid(for: n, flags: .write)
            try await client.writeFully(fid, offset: offset, data: data)
            if sync { try await client.fsync(fid) }
            // The size and mtime we have cached are now wrong.
            n.attributesExpireAt = 0
            return data.count
        } catch {
            throw FSError.from(error)
        }
    }

    public func fsync(_ id: NodeID) async throws {
        let n = try node(id)
        guard let fid = n.openFid else { return }
        do { try await client.fsync(fid) } catch { throw FSError.from(error) }
    }

    // MARK: - Directories

    /// Reads a page of directory entries starting at `cookie` (zero to start).
    ///
    /// Entries carry their own cookie; pass the last one back to continue. The
    /// `.` and `..` entries are not included — backends synthesise them, since
    /// only they know the parent's identifier in their own numbering.
    public func readDirectory(_ id: NodeID, cookie: UInt64 = 0, maxBytes: Int? = nil) async throws -> DirectoryChunk {
        let n = try node(id)
        guard n.qid.kind.contains(.dir) else { throw FSError.notDirectory }
        do {
            let fid = try await openFid(for: n, flags: [.read, .directory])
            let want = UInt32(min(maxBytes ?? client.ioSize, client.ioSize))
            let raw = try await client.readdir(fid, offset: cookie, count: want)
            var entries: [DirectoryEntry] = []
            entries.reserveCapacity(raw.count)
            for d in raw {
                let child = adopt(parent: n, name: d.name, qid: d.qid)
                entries.append(DirectoryEntry(
                    name: d.name, node: child.id,
                    type: entryType(dirent: d), cookie: d.offset))
            }
            return DirectoryChunk(entries: entries, atEnd: raw.isEmpty)
        } catch {
            throw FSError.from(error)
        }
    }

    /// Prefers the qid's own type bit over `d_type`, because base 9P2000 has no
    /// `d_type` and the client synthesises it from the qid anyway.
    private func entryType(dirent d: Dirent) -> FileType {
        if d.qid.kind.contains(.dir) { return .directory }
        if d.qid.kind.contains(.symlink) { return .symlink }
        return FileType(direntType: d.type)
    }

    /// Reads a whole directory. Convenient for tests and small directories.
    public func readDirectoryAll(_ id: NodeID) async throws -> [DirectoryEntry] {
        var all: [DirectoryEntry] = []
        var cookie: UInt64 = 0
        while true {
            let chunk = try await readDirectory(id, cookie: cookie)
            guard let last = chunk.entries.last else { break }
            all.append(contentsOf: chunk.entries)
            cookie = last.cookie
        }
        return all
    }

    // MARK: - Namespace changes

    public func create(
        parent: NodeID, name: String, permissions: UInt16, flags: OpenFlags = [.read, .write]
    ) async throws -> (node: NodeID, attributes: FileAttributes) {
        try checkWritable()
        try validate(name: name)
        let p = try node(parent)
        do {
            // Both dialects' create turns the directory fid into the new file's
            // fid, so hand them a clone and keep the result as the open fid.
            let parentFid = try await fid(for: p)
            let scratch = try await client.clone(parentFid)
            let (qid, _) = try await client.createFile(
                dirFid: scratch, name: name, flags: flags, mode: UInt32(permissions))
            let child = adopt(parent: p, name: name, qid: qid)
            if let old = child.openFid { await client.clunk(old) }
            child.openFid = scratch
            child.openFlags = flags.intersection([.read, .write])
            child.openedAt = now()
            child.attributesExpireAt = 0
            let attrs = try await fetchAttributes(child)
            return (child.id, attrs)
        } catch {
            throw FSError.from(error)
        }
    }

    public func mkdir(
        parent: NodeID, name: String, permissions: UInt16
    ) async throws -> (node: NodeID, attributes: FileAttributes) {
        try checkWritable()
        try validate(name: name)
        let p = try node(parent)
        do {
            let parentFid = try await fid(for: p)
            _ = try await client.mkdir(dirFid: parentFid, name: name, mode: UInt32(permissions))
            p.attributesExpireAt = 0
            return try await lookup(parent: parent, name: name)
        } catch {
            throw FSError.from(error)
        }
    }

    public func symlink(
        parent: NodeID, name: String, target: String
    ) async throws -> (node: NodeID, attributes: FileAttributes) {
        try checkWritable()
        try validate(name: name)
        let p = try node(parent)
        do {
            let parentFid = try await fid(for: p)
            _ = try await client.symlink(dirFid: parentFid, name: name, target: target)
            p.attributesExpireAt = 0
            return try await lookup(parent: parent, name: name)
        } catch {
            throw FSError.from(error)
        }
    }

    public func readlink(_ id: NodeID) async throws -> String {
        let n = try node(id)
        do {
            let fid = try await fid(for: n)
            return try await client.readlink(fid)
        } catch {
            throw FSError.from(error)
        }
    }

    public func link(parent: NodeID, name: String, to target: NodeID) async throws -> FileAttributes {
        try checkWritable()
        try validate(name: name)
        let p = try node(parent)
        let t = try node(target)
        do {
            let parentFid = try await fid(for: p)
            let targetFid = try await fid(for: t)
            try await client.link(dirFid: parentFid, targetFid: targetFid, name: name)
            p.attributesExpireAt = 0
            t.attributesExpireAt = 0
            return try await lookup(parent: parent, name: name).attributes
        } catch {
            throw FSError.from(error)
        }
    }

    public func remove(parent: NodeID, name: String, isDirectory: Bool) async throws {
        try checkWritable()
        try validate(name: name)
        let p = try node(parent)
        do {
            let parentFid = try await fid(for: p)
            try await client.unlink(dirFid: parentFid, name: name, isDirectory: isDirectory)
            if let childID = p.children[name], let child = nodes[childID] { forget(child) }
            p.attributesExpireAt = 0
        } catch {
            throw FSError.from(error)
        }
    }

    public func rename(
        fromParent: NodeID, fromName: String, toParent: NodeID, toName: String
    ) async throws {
        try checkWritable()
        try validate(name: fromName)
        try validate(name: toName)
        let source = try node(fromParent)
        let destination = try node(toParent)
        do {
            let sourceFid = try await fid(for: source)
            let destinationFid = try await fid(for: destination)
            try await client.rename(
                oldDirFid: sourceFid, oldName: fromName,
                newDirFid: destinationFid, newName: toName)

            // Anything the destination name used to refer to is gone, and the
            // moved file's cached path is no longer valid.
            if let clobbered = destination.children[toName], let n = nodes[clobbered] { forget(n) }
            if let movedID = source.children[fromName], let moved = nodes[movedID] {
                source.children.removeValue(forKey: fromName)
                if let f = moved.fid {
                    moved.fid = nil
                    cachedFidCount -= 1
                    await client.clunk(f)
                }
                moved.parent = destination.id
                moved.name = toName
                destination.children[toName] = moved.id
                moved.attributesExpireAt = 0
            }
            source.attributesExpireAt = 0
            destination.attributesExpireAt = 0
        } catch {
            throw FSError.from(error)
        }
    }

    // MARK: - Volume

    public func statfs() async throws -> FilesystemStats {
        do {
            return FilesystemStats(try await client.statfs())
        } catch {
            throw FSError.from(error)
        }
    }

    private func validate(name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.utf8.contains(0) else {
            throw FSError.invalidArgument
        }
        guard name.utf8.count <= 255 else { throw FSError.nameTooLong }
    }
}
