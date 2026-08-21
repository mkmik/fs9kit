import Foundation
import NineP

/// An in-memory file tree.
///
/// Built for tests and for exercising a client without touching the host
/// filesystem: everything is deterministic — inode numbers are handed out in
/// creation order starting at 1, directory listings come back sorted by name,
/// and new files get a fixed default timestamp unless the caller supplies a
/// clock.
public final class MemoryFileSystem: NinePFileServer, @unchecked Sendable {
    /// One file. Reference type so that an open handle keeps pointing at the
    /// same object after the tree around it changes.
    private final class Node {
        let ino: UInt64
        var mode: UInt32
        var uid: UInt32
        var gid: UInt32
        var ownerName: String
        var groupName: String
        var atime: TimeSpec
        var mtime: TimeSpec
        var ctime: TimeSpec
        /// Bumped on every content change so clients can invalidate caches.
        var version: UInt32 = 0
        var content: [UInt8] = []
        var target: String = ""
        var children: [String: Node] = [:]
        /// Hard-link count for regular files; directories compute theirs.
        var linkCount: UInt64 = 1

        init(ino: UInt64, mode: UInt32, uid: UInt32, gid: UInt32,
             ownerName: String, groupName: String, time: TimeSpec) {
            self.ino = ino
            self.mode = mode
            self.uid = uid
            self.gid = gid
            self.ownerName = ownerName
            self.groupName = groupName
            self.atime = time
            self.mtime = time
            self.ctime = time
        }

        var isDirectory: Bool { mode & PosixFileType.mask == PosixFileType.dir }
        var isSymlink: Bool { mode & PosixFileType.mask == PosixFileType.lnk }
    }

    /// `f_type` reported by statfs: Linux's V9FS_MAGIC, so a mounted client
    /// sees the filesystem it expects.
    static let magic: UInt32 = 0x0102_1997

    private let lock = NSLock()
    private var nextIno: UInt64 = 1
    private var root: Node!
    private let clock: @Sendable () -> TimeSpec
    private let defaultOwner: String
    private let defaultGroup: String

    /// - Parameters:
    ///   - owner: name reported as uid/gid in 9P2000 stat structures.
    ///   - clock: source of timestamps. The default is a *fixed* instant so
    ///     that tests comparing stat output do not have to tolerate drift.
    public init(
        owner: String = "nineP", group: String = "nineP",
        clock: (@Sendable () -> TimeSpec)? = nil
    ) {
        self.defaultOwner = owner
        self.defaultGroup = group
        self.clock = clock ?? { TimeSpec(seconds: 1_700_000_000, nanoseconds: 0) }
        self.root = makeNode(mode: PosixFileType.dir | 0o755)
    }

    private func makeNode(mode: UInt32) -> Node {
        let node = Node(ino: nextIno, mode: mode, uid: 0, gid: 0,
                        ownerName: defaultOwner, groupName: defaultGroup, time: clock())
        nextIno += 1
        return node
    }

    // MARK: - Test construction helpers

    /// Creates a directory and any missing parents.
    @discardableResult
    public func addDirectory(_ path: String, mode: UInt32 = 0o755) throws -> Qid {
        try lock.withLock { try makeDirectories(FilePath(posix: path), mode: mode).qid() }
    }

    /// Creates (or replaces the contents of) a regular file, making parents.
    @discardableResult
    public func addFile(_ path: String, contents: [UInt8] = [], mode: UInt32 = 0o644) throws -> Qid {
        let p = FilePath(posix: path)
        guard let parent = p.parent, !p.isRoot else {
            throw NinePServerError.invalidArgument("cannot create the root as a file")
        }
        return try lock.withLock {
            let dir = try makeDirectories(parent, mode: 0o755)
            let node: Node
            if let existing = dir.children[p.name] {
                guard !existing.isDirectory else { throw NinePServerError.isADirectory(path) }
                node = existing
            } else {
                node = makeNode(mode: PosixFileType.reg | (mode & 0o7777))
                dir.children[p.name] = node
            }
            node.content = contents
            node.version &+= 1
            return node.qid()
        }
    }

    @discardableResult
    public func addFile(_ path: String, text: String, mode: UInt32 = 0o644) throws -> Qid {
        try addFile(path, contents: Array(text.utf8), mode: mode)
    }

    @discardableResult
    public func addSymlink(_ path: String, target: String) throws -> Qid {
        let p = FilePath(posix: path)
        guard let parent = p.parent, !p.isRoot else {
            throw NinePServerError.invalidArgument("cannot create the root as a symlink")
        }
        return try lock.withLock {
            let dir = try makeDirectories(parent, mode: 0o755)
            guard dir.children[p.name] == nil else { throw NinePServerError.alreadyExists(path) }
            let node = makeNode(mode: PosixFileType.lnk | 0o777)
            node.target = target
            dir.children[p.name] = node
            return node.qid()
        }
    }

    /// Contents of a regular file, for assertions.
    public func contents(of path: String) throws -> [UInt8] {
        try lock.withLock {
            let node = try resolve(FilePath(posix: path))
            guard !node.isDirectory else { throw NinePServerError.isADirectory(path) }
            return node.content
        }
    }

    public func text(at path: String) throws -> String {
        String(decoding: try contents(of: path), as: UTF8.self)
    }

    public func exists(_ path: String) -> Bool {
        lock.withLock { (try? resolve(FilePath(posix: path))) != nil }
    }

    /// Sorted child names of a directory, for assertions.
    public func names(in path: String) throws -> [String] {
        try lock.withLock {
            let node = try resolve(FilePath(posix: path))
            guard node.isDirectory else { throw NinePServerError.notADirectory(path) }
            return node.children.keys.sorted()
        }
    }

    // MARK: - Tree navigation (callers hold the lock)

    private func resolve(_ path: FilePath) throws -> Node {
        var node = root!
        for component in path.components {
            guard node.isDirectory else { throw NinePServerError.notADirectory(path.posixString) }
            guard let next = node.children[component] else {
                throw NinePServerError.noSuchFile(path.posixString)
            }
            node = next
        }
        return node
    }

    private func resolveDirectory(_ path: FilePath) throws -> Node {
        let node = try resolve(path)
        guard node.isDirectory else { throw NinePServerError.notADirectory(path.posixString) }
        return node
    }

    private func makeDirectories(_ path: FilePath, mode: UInt32) throws -> Node {
        var node = root!
        for component in path.components {
            guard node.isDirectory else { throw NinePServerError.notADirectory(path.posixString) }
            if let next = node.children[component] {
                node = next
            } else {
                let dir = makeNode(mode: PosixFileType.dir | (mode & 0o7777))
                node.children[component] = dir
                node = dir
            }
        }
        return node
    }

    private static func validate(name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw NinePServerError.invalidArgument("invalid file name \"\(name)\"")
        }
    }

    // MARK: - NinePFileServer

    public func attach(uname: String, aname: String, uid: UInt32) throws -> (path: FilePath, entry: FileEntry) {
        let path = FilePath(posix: aname)
        return try lock.withLock {
            let node = try resolveDirectory(path)
            return (path, node.entry(named: path.name))
        }
    }

    public func entry(at path: FilePath) throws -> FileEntry {
        try lock.withLock { try resolve(path).entry(named: path.name) }
    }

    public func list(_ path: FilePath) throws -> [FileEntry] {
        try lock.withLock {
            let dir = try resolveDirectory(path)
            return dir.children.keys.sorted().map { name in
                dir.children[name]!.entry(named: name)
            }
        }
    }

    public func open(_ path: FilePath, flags: LinuxOpenFlags) throws -> NinePFileHandle {
        try lock.withLock {
            let node = try resolve(path)
            if node.isDirectory {
                guard flags.accessMode == LinuxOpenFlags.rdonly.rawValue else {
                    throw NinePServerError.isADirectory(path.posixString)
                }
                return Handle(fs: self, node: node, writable: false, append: false)
            }
            let writable = flags.accessMode != LinuxOpenFlags.rdonly.rawValue
            if flags.contains(.trunc) && writable {
                node.content = []
                node.version &+= 1
                node.mtime = clock()
            }
            return Handle(fs: self, node: node, writable: writable, append: flags.contains(.append))
        }
    }

    public func create(in directory: FilePath, name: String, mode: UInt32,
                       flags: LinuxOpenFlags, gid: UInt32) throws -> (entry: FileEntry, handle: NinePFileHandle) {
        try Self.validate(name: name)
        return try lock.withLock {
            let dir = try resolveDirectory(directory)
            if let existing = dir.children[name] {
                if flags.contains(.excl) { throw NinePServerError.alreadyExists(name) }
                guard !existing.isDirectory else { throw NinePServerError.isADirectory(name) }
                if flags.contains(.trunc) {
                    existing.content = []
                    existing.version &+= 1
                }
                let handle = Handle(fs: self, node: existing, writable: true,
                                    append: flags.contains(.append))
                return (existing.entry(named: name), handle)
            }
            let node = makeNode(mode: PosixFileType.reg | (mode & 0o7777))
            node.gid = gid
            dir.children[name] = node
            touch(dir)
            let handle = Handle(fs: self, node: node, writable: true, append: flags.contains(.append))
            return (node.entry(named: name), handle)
        }
    }

    public func mkdir(in directory: FilePath, name: String, mode: UInt32, gid: UInt32) throws -> FileEntry {
        try Self.validate(name: name)
        return try lock.withLock {
            let dir = try resolveDirectory(directory)
            guard dir.children[name] == nil else { throw NinePServerError.alreadyExists(name) }
            let node = makeNode(mode: PosixFileType.dir | (mode & 0o7777))
            node.gid = gid
            dir.children[name] = node
            touch(dir)
            return node.entry(named: name)
        }
    }

    public func symlink(in directory: FilePath, name: String, target: String, gid: UInt32) throws -> FileEntry {
        try Self.validate(name: name)
        return try lock.withLock {
            let dir = try resolveDirectory(directory)
            guard dir.children[name] == nil else { throw NinePServerError.alreadyExists(name) }
            let node = makeNode(mode: PosixFileType.lnk | 0o777)
            node.target = target
            node.gid = gid
            dir.children[name] = node
            touch(dir)
            return node.entry(named: name)
        }
    }

    public func readlink(_ path: FilePath) throws -> String {
        try lock.withLock {
            let node = try resolve(path)
            guard node.isSymlink else { throw NinePServerError.invalidArgument("not a symbolic link") }
            return node.target
        }
    }

    public func link(_ existing: FilePath, in directory: FilePath, name: String) throws {
        try Self.validate(name: name)
        try lock.withLock {
            let target = try resolve(existing)
            guard !target.isDirectory else { throw NinePServerError.permissionDenied("hard link to a directory") }
            let dir = try resolveDirectory(directory)
            guard dir.children[name] == nil else { throw NinePServerError.alreadyExists(name) }
            dir.children[name] = target
            target.linkCount += 1
            touch(dir)
        }
    }

    public func unlink(in directory: FilePath, name: String, isDirectory: Bool) throws {
        try Self.validate(name: name)
        try lock.withLock {
            let dir = try resolveDirectory(directory)
            guard let victim = dir.children[name] else {
                throw NinePServerError.noSuchFile(directory.appending(name).posixString)
            }
            if isDirectory {
                guard victim.isDirectory else { throw NinePServerError.notADirectory(name) }
                guard victim.children.isEmpty else { throw NinePServerError.notEmpty(name) }
            } else {
                guard !victim.isDirectory else { throw NinePServerError.isADirectory(name) }
            }
            dir.children.removeValue(forKey: name)
            if victim.linkCount > 0 { victim.linkCount -= 1 }
            touch(dir)
        }
    }

    public func rename(from: FilePath, name: String, to: FilePath, newName: String) throws {
        try Self.validate(name: name)
        try Self.validate(name: newName)
        try lock.withLock {
            let source = try resolveDirectory(from)
            let destination = try resolveDirectory(to)
            guard let node = source.children[name] else {
                throw NinePServerError.noSuchFile(from.appending(name).posixString)
            }
            // Moving a directory into itself would detach the subtree from the
            // root and leak it, so refuse the way rename(2) does.
            if node.isDirectory && to.appending(newName).isInside(from.appending(name)) {
                throw NinePServerError.invalidArgument("cannot move a directory into itself")
            }
            if let existing = destination.children[newName] {
                if existing.isDirectory {
                    guard existing.children.isEmpty else { throw NinePServerError.notEmpty(newName) }
                }
                guard existing.isDirectory == node.isDirectory else {
                    throw NinePServerError(errno: existing.isDirectory ? LinuxErrno.eisdir : LinuxErrno.enotdir,
                                           message: "rename would replace a file of a different type")
                }
            }
            source.children.removeValue(forKey: name)
            destination.children[newName] = node
            touch(source)
            touch(destination)
        }
    }

    public func setattr(_ path: FilePath, _ request: SetattrRequest) throws {
        try lock.withLock {
            let node = try resolve(path)
            if let mode = request.mode {
                node.mode = (node.mode & PosixFileType.mask) | (mode & 0o7777)
            }
            if let uid = request.uid, uid != UInt32.max { node.uid = uid }
            if let gid = request.gid, gid != UInt32.max { node.gid = gid }
            if let owner = request.ownerName { node.ownerName = owner }
            if let group = request.groupName { node.groupName = group }
            if let size = request.size {
                guard !node.isDirectory else { throw NinePServerError.isADirectory(path.posixString) }
                let n = Int(min(size, UInt64(Int.max)))
                if n < node.content.count {
                    node.content.removeLast(node.content.count - n)
                } else if n > node.content.count {
                    node.content.append(contentsOf: repeatElement(0, count: n - node.content.count))
                }
                node.version &+= 1
            }
            switch request.atime {
            case .none: break
            case .now: node.atime = clock()
            case .set(let t): node.atime = t
            }
            switch request.mtime {
            case .none: break
            case .now: node.mtime = clock()
            case .set(let t): node.mtime = t
            }
            node.ctime = clock()
        }
    }

    public func statfs(_ path: FilePath) throws -> StatFS {
        lock.withLock {
            var files: UInt64 = 0
            var bytes: UInt64 = 0
            var stack = [root!]
            while let node = stack.popLast() {
                files += 1
                bytes += UInt64(node.content.count)
                stack.append(contentsOf: node.children.values)
            }
            let blockSize: UInt64 = 4096
            let capacity: UInt64 = 1 << 20      // a nominal 4 GiB of 4 KiB blocks
            let used = (bytes + blockSize - 1) / blockSize
            return StatFS(
                type: MemoryFileSystem.magic, bsize: UInt32(blockSize), blocks: capacity,
                bfree: capacity > used ? capacity - used : 0,
                bavail: capacity > used ? capacity - used : 0,
                files: files, ffree: capacity, fsid: 0, namelen: 255)
        }
    }

    public func sync(_ path: FilePath) throws {
        // Nothing is buffered; the call exists so clients can fsync harmlessly.
        _ = try lock.withLock { try resolve(path) }
    }

    // MARK: - Internals

    private func touch(_ node: Node) {
        let now = clock()
        node.mtime = now
        node.ctime = now
    }

    fileprivate func currentTime() -> TimeSpec { clock() }

    /// An open regular file. All state lives in the node, so two handles on the
    /// same file see each other's writes, as they would on a real filesystem.
    private final class Handle: NinePFileHandle, @unchecked Sendable {
        private let fs: MemoryFileSystem
        private let node: Node
        private let writable: Bool
        private let append: Bool

        init(fs: MemoryFileSystem, node: Node, writable: Bool, append: Bool) {
            self.fs = fs
            self.node = node
            self.writable = writable
            self.append = append
        }

        func read(offset: UInt64, count: Int) throws -> [UInt8] {
            try fs.lock.withLock {
                guard !node.isDirectory else { throw NinePServerError.isADirectory("directory read") }
                guard offset < UInt64(node.content.count) else { return [] }
                let start = Int(offset)
                let end = min(node.content.count, start + max(0, count))
                return Array(node.content[start..<end])
            }
        }

        func write(offset: UInt64, bytes: [UInt8]) throws -> Int {
            try fs.lock.withLock {
                guard writable else { throw NinePServerError.badFileDescriptor("file not open for writing") }
                guard !node.isDirectory else { throw NinePServerError.isADirectory("directory write") }
                let start = append ? node.content.count : Int(min(offset, UInt64(Int.max)))
                if start > node.content.count {
                    node.content.append(contentsOf: repeatElement(0, count: start - node.content.count))
                }
                let end = start + bytes.count
                if end > node.content.count {
                    node.content.append(contentsOf: repeatElement(0, count: end - node.content.count))
                }
                node.content.replaceSubrange(start..<end, with: bytes)
                node.version &+= 1
                let now = fs.currentTime()
                node.mtime = now
                node.ctime = now
                return bytes.count
            }
        }

        func sync() throws {}
        func close() {}
    }
}

private extension MemoryFileSystem.Node {
    func qid() -> Qid {
        Qid(kind: FileEntry.qidKind(forMode: mode), version: version, path: ino)
    }

    func entry(named name: String) -> FileEntry {
        let size: UInt64 = isDirectory ? 4096 : (isSymlink ? UInt64(target.utf8.count) : UInt64(content.count))
        let links: UInt64 = isDirectory
            ? UInt64(2 + children.values.filter { $0.isDirectory }.count)
            : linkCount
        return FileEntry(
            name: name, qid: qid(), mode: mode, uid: uid, gid: gid,
            ownerName: ownerName, groupName: groupName, nlink: links, size: size,
            atime: atime, mtime: mtime, ctime: ctime,
            symlinkTarget: isSymlink ? target : nil)
    }
}
