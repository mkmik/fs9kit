import Foundation
import NineP
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Exports a real directory from the host filesystem.
///
/// Containment is the whole point of this type. Every path handed to the C
/// library is built by `realpath`-ing the parent chain and checking that the
/// result is still under the exported root, so neither a `..` component nor a
/// symbolic link — absolute or not — can reach a file outside it. `..` never
/// even reaches here (``NinePSession`` folds it while walking), but the check
/// does not rely on that.
public final class LocalDirectoryFileSystem: NinePFileServer, @unchecked Sendable {
    public struct Options: Sendable {
        /// Permit paths that resolve outside the exported root. Off by default;
        /// only useful when exporting a directory of curated symlinks.
        public var followExternalSymlinks: Bool = false
        /// Refuse every mutating operation.
        public var readOnly: Bool = false
        /// Owner name reported in 9P2000 stat structures, which have no numeric
        /// ids. Looking up real names would need NSS; the client rarely cares.
        public var ownerName: String = "nineP"
        public var groupName: String = "nineP"

        public init(followExternalSymlinks: Bool = false, readOnly: Bool = false,
                    ownerName: String = "nineP", groupName: String = "nineP") {
            self.followExternalSymlinks = followExternalSymlinks
            self.readOnly = readOnly
            self.ownerName = ownerName
            self.groupName = groupName
        }
    }

    /// The canonical, symlink-free path of the exported directory.
    public let root: String
    public let options: Options

    /// - Throws: ``NinePServerError`` when `path` does not exist or is not a
    ///   directory; a server that cannot resolve its own root is unusable, so
    ///   this is checked once up front instead of on every request.
    public init(root path: String, options: Options = Options()) throws {
        guard let resolved = sysRealpath(path) else {
            throw NinePServerError.fromHostErrno(sysErrno(), while: "resolving export root \(path)")
        }
        var st = stat()
        guard sysLstat(resolved, &st) == 0 else {
            throw NinePServerError.fromHostErrno(sysErrno(), while: "stat \(resolved)")
        }
        guard UInt32(st.st_mode) & PosixFileType.mask == PosixFileType.dir else {
            throw NinePServerError.notADirectory("export root \(resolved)")
        }
        self.root = resolved
        self.options = options
    }

    // MARK: - Path resolution

    private static func validate(name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw NinePServerError.invalidArgument("invalid file name \"\(name)\"")
        }
    }

    private func isInsideRoot(_ path: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private func canonical(_ path: String, describing what: String) throws -> String {
        guard let resolved = sysRealpath(path) else {
            throw NinePServerError.fromHostErrno(sysErrno(), while: what)
        }
        guard options.followExternalSymlinks || isInsideRoot(resolved) else {
            throw NinePServerError(errno: LinuxErrno.eacces,
                                   message: "\(what): path escapes the exported root")
        }
        return resolved
    }

    /// Maps a 9P path onto a host path.
    ///
    /// - Parameter followFinal: when false the last component is appended to
    ///   the canonicalised parent without being resolved, which is what
    ///   `lstat`, `readlink` and `unlink` need. The parent is always resolved,
    ///   so a symlink in the middle of the path cannot smuggle us out.
    private func systemPath(_ path: FilePath, followFinal: Bool) throws -> String {
        for component in path.components { try Self.validate(name: component) }
        guard let last = path.components.last else { return root }
        let parentJoined = ([root] + path.components.dropLast()).joined(separator: "/")
        let parent = try canonical(parentJoined, describing: "resolving \(path.posixString)")
        let full = parent + "/" + last
        guard followFinal else { return full }
        if let resolved = sysRealpath(full) {
            guard options.followExternalSymlinks || isInsideRoot(resolved) else {
                throw NinePServerError(errno: LinuxErrno.eacces,
                                       message: "\(path.posixString): path escapes the exported root")
            }
            return resolved
        }
        // A path that does not exist yet is fine — its parent was validated —
        // but a broken resolution for any other reason is not.
        let code = sysErrno()
        guard code == ENOENT else {
            throw NinePServerError.fromHostErrno(code, while: "resolving \(path.posixString)")
        }
        return full
    }

    private func directorySystemPath(_ path: FilePath) throws -> String {
        let system = try systemPath(path, followFinal: true)
        var st = stat()
        guard sysLstat(system, &st) == 0 else {
            throw NinePServerError.fromHostErrno(sysErrno(), while: path.posixString)
        }
        guard UInt32(st.st_mode) & PosixFileType.mask == PosixFileType.dir else {
            throw NinePServerError.notADirectory(path.posixString)
        }
        return system
    }

    private func requireWritable() throws {
        if options.readOnly {
            throw NinePServerError(errno: LinuxErrno.erofs, message: "read-only export")
        }
    }

    // MARK: - Metadata

    private func makeEntry(name: String, systemPath: String) throws -> FileEntry {
        var st = stat()
        guard sysLstat(systemPath, &st) == 0 else {
            throw NinePServerError.fromHostErrno(sysErrno(), while: name.isEmpty ? systemPath : name)
        }
        return entry(name: name, systemPath: systemPath, st: st)
    }

    private func entry(name: String, systemPath: String, st: stat) -> FileEntry {
        let mode = UInt32(st.st_mode)
        let times = sysStatTimes(st)
        // Two files on different devices can share an inode number, so fold the
        // device in; qid.path only has to be unique within this export.
        let qidPath = UInt64(st.st_ino) ^ (UInt64(UInt32(truncatingIfNeeded: st.st_dev)) << 40)
        // mtime is the cheapest stand-in for a content version counter.
        let version = UInt32(truncatingIfNeeded: UInt64(times.mtime.seconds) &* 1_000 &+ (times.mtime.nanoseconds / 1_000_000))
        let target = (mode & PosixFileType.mask == PosixFileType.lnk) ? sysReadlink(systemPath) : nil
        return FileEntry(
            name: name,
            qid: Qid(kind: FileEntry.qidKind(forMode: mode), version: version, path: qidPath),
            mode: mode, uid: UInt32(st.st_uid), gid: UInt32(st.st_gid),
            ownerName: options.ownerName, groupName: options.groupName,
            nlink: UInt64(st.st_nlink), size: UInt64(max(0, st.st_size)),
            rdev: UInt64(truncatingIfNeeded: st.st_rdev),
            blockSize: UInt64(max(1, st.st_blksize)), blocks: UInt64(max(0, st.st_blocks)),
            atime: times.atime, mtime: times.mtime, ctime: times.ctime,
            symlinkTarget: target)
    }

    // MARK: - NinePFileServer

    public func attach(uname: String, aname: String, uid: UInt32) throws -> (path: FilePath, entry: FileEntry) {
        let path = FilePath(posix: aname)
        let system = try directorySystemPath(path)
        return (path, try makeEntry(name: path.name, systemPath: system))
    }

    public func entry(at path: FilePath) throws -> FileEntry {
        try makeEntry(name: path.name, systemPath: try systemPath(path, followFinal: false))
    }

    public func list(_ path: FilePath) throws -> [FileEntry] {
        let system = try directorySystemPath(path)
        return try sysListDirectory(system).sorted().compactMap { name in
            // Entries that vanish between the readdir and the lstat are skipped
            // rather than failing the whole listing.
            try? makeEntry(name: name, systemPath: system + "/" + name)
        }
    }

    public func open(_ path: FilePath, flags: LinuxOpenFlags) throws -> NinePFileHandle {
        let system = try systemPath(path, followFinal: true)
        var st = stat()
        guard sysLstat(system, &st) == 0 else {
            throw NinePServerError.fromHostErrno(sysErrno(), while: path.posixString)
        }
        let isDirectory = UInt32(st.st_mode) & PosixFileType.mask == PosixFileType.dir
        var hostFlags = Self.hostOpenFlags(flags)
        if isDirectory {
            guard flags.accessMode == LinuxOpenFlags.rdonly.rawValue else {
                throw NinePServerError.isADirectory(path.posixString)
            }
            hostFlags = O_RDONLY
        } else if flags.accessMode != LinuxOpenFlags.rdonly.rawValue {
            try requireWritable()
        }
        let fd = sysOpen(system, hostFlags, 0)
        guard fd >= 0 else {
            throw NinePServerError.fromHostErrno(sysErrno(), while: "open \(path.posixString)")
        }
        return Handle(fd: fd, writable: !isDirectory && flags.accessMode != LinuxOpenFlags.rdonly.rawValue,
                      append: flags.contains(.append), isDirectory: isDirectory)
    }

    public func create(in directory: FilePath, name: String, mode: UInt32,
                       flags: LinuxOpenFlags, gid: UInt32) throws -> (entry: FileEntry, handle: NinePFileHandle) {
        try requireWritable()
        try Self.validate(name: name)
        let parent = try directorySystemPath(directory)
        let system = parent + "/" + name
        var hostFlags = Self.hostOpenFlags(flags) | O_CREAT
        if flags.accessMode == LinuxOpenFlags.rdonly.rawValue {
            // A create always needs write access even when the client asked to
            // read: it has to be able to place the file.
            hostFlags = (hostFlags & ~O_ACCMODE) | O_RDWR
        }
        let fd = sysOpen(system, hostFlags, mode_t(mode & 0o7777))
        guard fd >= 0 else {
            throw NinePServerError.fromHostErrno(sysErrno(), while: "create \(name)")
        }
        let handle = Handle(fd: fd, writable: true, append: flags.contains(.append), isDirectory: false)
        do {
            return (try makeEntry(name: name, systemPath: system), handle)
        } catch {
            handle.close()
            throw error
        }
    }

    public func mkdir(in directory: FilePath, name: String, mode: UInt32, gid: UInt32) throws -> FileEntry {
        try requireWritable()
        try Self.validate(name: name)
        let system = try directorySystemPath(directory) + "/" + name
        guard sysMkdir(system, mode_t(mode & 0o7777)) == 0 else {
            throw NinePServerError.fromHostErrno(sysErrno(), while: "mkdir \(name)")
        }
        return try makeEntry(name: name, systemPath: system)
    }

    public func symlink(in directory: FilePath, name: String, target: String, gid: UInt32) throws -> FileEntry {
        try requireWritable()
        try Self.validate(name: name)
        let system = try directorySystemPath(directory) + "/" + name
        guard sysSymlink(target, system) == 0 else {
            throw NinePServerError.fromHostErrno(sysErrno(), while: "symlink \(name)")
        }
        return try makeEntry(name: name, systemPath: system)
    }

    public func readlink(_ path: FilePath) throws -> String {
        let system = try systemPath(path, followFinal: false)
        guard let target = sysReadlink(system) else {
            throw NinePServerError.fromHostErrno(sysErrno(), while: "readlink \(path.posixString)")
        }
        return target
    }

    public func link(_ existing: FilePath, in directory: FilePath, name: String) throws {
        try requireWritable()
        try Self.validate(name: name)
        let source = try systemPath(existing, followFinal: true)
        let system = try directorySystemPath(directory) + "/" + name
        guard sysLink(source, system) == 0 else {
            throw NinePServerError.fromHostErrno(sysErrno(), while: "link \(name)")
        }
    }

    public func unlink(in directory: FilePath, name: String, isDirectory: Bool) throws {
        try requireWritable()
        try Self.validate(name: name)
        let system = try directorySystemPath(directory) + "/" + name
        let rc = isDirectory ? sysRmdir(system) : sysUnlink(system)
        guard rc == 0 else {
            throw NinePServerError.fromHostErrno(sysErrno(), while: "remove \(name)")
        }
    }

    public func rename(from: FilePath, name: String, to: FilePath, newName: String) throws {
        try requireWritable()
        try Self.validate(name: name)
        try Self.validate(name: newName)
        let source = try directorySystemPath(from) + "/" + name
        let destination = try directorySystemPath(to) + "/" + newName
        guard sysRename(source, destination) == 0 else {
            throw NinePServerError.fromHostErrno(sysErrno(), while: "rename \(name)")
        }
    }

    public func setattr(_ path: FilePath, _ request: SetattrRequest) throws {
        try requireWritable()
        let system = try systemPath(path, followFinal: true)
        if let mode = request.mode {
            guard sysChmod(system, mode_t(mode & 0o7777)) == 0 else {
                throw NinePServerError.fromHostErrno(sysErrno(), while: "chmod \(path.posixString)")
            }
        }
        if request.uid != nil || request.gid != nil {
            let uid = request.uid.map { uid_t($0) } ?? uid_t(bitPattern: Int32(-1))
            let gid = request.gid.map { gid_t($0) } ?? gid_t(bitPattern: Int32(-1))
            guard sysChown(system, uid, gid) == 0 else {
                throw NinePServerError.fromHostErrno(sysErrno(), while: "chown \(path.posixString)")
            }
        }
        if let size = request.size {
            guard sysTruncate(system, off_t(min(size, UInt64(Int64.max)))) == 0 else {
                throw NinePServerError.fromHostErrno(sysErrno(), while: "truncate \(path.posixString)")
            }
        }
        if request.atime != nil || request.mtime != nil {
            let times = [Self.hostTimespec(for: request.atime), Self.hostTimespec(for: request.mtime)]
            guard sysUtimensat(system, times) == 0 else {
                throw NinePServerError.fromHostErrno(sysErrno(), while: "utimes \(path.posixString)")
            }
        }
    }

    public func statfs(_ path: FilePath) throws -> StatFS {
        let system = try systemPath(path, followFinal: true)
        guard let vfs = sysStatvfs(system) else {
            throw NinePServerError.fromHostErrno(sysErrno(), while: "statfs \(path.posixString)")
        }
        return StatFS(
            type: LocalDirectoryFileSystem.magic,
            bsize: UInt32(truncatingIfNeeded: vfs.f_bsize),
            blocks: UInt64(vfs.f_blocks), bfree: UInt64(vfs.f_bfree), bavail: UInt64(vfs.f_bavail),
            files: UInt64(vfs.f_files), ffree: UInt64(vfs.f_ffree), fsid: 0,
            namelen: UInt32(truncatingIfNeeded: vfs.f_namemax))
    }

    public func sync(_ path: FilePath) throws {
        let system = try systemPath(path, followFinal: true)
        let fd = sysOpen(system, O_RDONLY, 0)
        guard fd >= 0 else {
            throw NinePServerError.fromHostErrno(sysErrno(), while: "open \(path.posixString)")
        }
        defer { sysClose(fd) }
        guard sysFsync(fd) == 0 else {
            throw NinePServerError.fromHostErrno(sysErrno(), while: "fsync \(path.posixString)")
        }
    }

    /// `f_type` we report: Linux's V9FS_MAGIC, which is what a client mounting
    /// us would see anyway.
    static let magic: UInt32 = 0x0102_1997

    private static func hostTimespec(for update: TimeUpdate?) -> timespec {
        switch update {
        case .none: return timespec(tv_sec: 0, tv_nsec: sysUtimeOmit)
        case .now: return timespec(tv_sec: 0, tv_nsec: sysUtimeNow)
        case .set(let t): return t.asTimespec
        }
    }

    /// Translates wire (Linux-numbered) open flags into the host's.
    private static func hostOpenFlags(_ flags: LinuxOpenFlags) -> Int32 {
        var host: Int32
        switch flags.accessMode {
        case LinuxOpenFlags.wronly.rawValue: host = O_WRONLY
        case LinuxOpenFlags.rdwr.rawValue: host = O_RDWR
        default: host = O_RDONLY
        }
        if flags.contains(.create) { host |= O_CREAT }
        if flags.contains(.excl) { host |= O_EXCL }
        if flags.contains(.trunc) { host |= O_TRUNC }
        if flags.contains(.append) { host |= O_APPEND }
        return host
    }

    /// An open host file. `pread`/`pwrite` keep the handle stateless, so the
    /// offsets in concurrent 9P requests cannot interleave.
    private final class Handle: NinePFileHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32
        private let writable: Bool
        private let append: Bool
        private let isDirectory: Bool

        init(fd: Int32, writable: Bool, append: Bool, isDirectory: Bool) {
            self.fd = fd
            self.writable = writable
            self.append = append
            self.isDirectory = isDirectory
        }

        deinit { close() }

        private func withFD<T>(_ body: (Int32) throws -> T) throws -> T {
            try lock.withLock {
                guard fd >= 0 else { throw NinePServerError.badFileDescriptor() }
                return try body(fd)
            }
        }

        func read(offset: UInt64, count: Int) throws -> [UInt8] {
            guard !isDirectory else { throw NinePServerError.isADirectory("directory read") }
            guard count > 0 else { return [] }
            return try withFD { fd in
                var buffer = [UInt8](repeating: 0, count: count)
                let n = buffer.withUnsafeMutableBytes {
                    sysPread(fd, $0.baseAddress!, count, off_t(min(offset, UInt64(Int64.max))))
                }
                guard n >= 0 else {
                    throw NinePServerError.fromHostErrno(sysErrno(), while: "read")
                }
                buffer.removeLast(count - n)
                return buffer
            }
        }

        func write(offset: UInt64, bytes: [UInt8]) throws -> Int {
            guard writable else { throw NinePServerError.badFileDescriptor("file not open for writing") }
            guard !bytes.isEmpty else { return 0 }
            return try withFD { fd in
                let n = bytes.withUnsafeBytes { raw -> Int in
                    if append {
                        // O_APPEND makes pwrite's offset advisory on Linux but
                        // not portably, so use write(2) for appending handles.
                        return sysWriteFile(fd, raw.baseAddress!, bytes.count)
                    }
                    return sysPwrite(fd, raw.baseAddress!, bytes.count,
                                     off_t(min(offset, UInt64(Int64.max))))
                }
                guard n >= 0 else {
                    throw NinePServerError.fromHostErrno(sysErrno(), while: "write")
                }
                return n
            }
        }

        func sync() throws {
            try withFD { fd in
                guard sysFsync(fd) == 0 else {
                    throw NinePServerError.fromHostErrno(sysErrno(), while: "fsync")
                }
            }
        }

        func close() {
            lock.withLock {
                if fd >= 0 { sysClose(fd) }
                fd = -1
            }
        }
    }
}
