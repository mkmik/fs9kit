import Foundation
import NineP
import NinePClient
import FS9Core
import FS9NFS

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Mounting a 9P server through the loopback NFS bridge.
///
/// The process stays alive for the life of the mount: it *is* the filesystem.
/// When it exits, the mount is unmounted, so a crash leaves a dead mount point
/// rather than a wedged one.
enum Mount {
    static let flagNames: Set<String> = ConnectionOptions.flagNames.union([
        "read-only", "nfs-port", "mount-option", "no-sudo", "background",
        "log", "attr-timeout", "help",
    ])

    static let usage = """
    usage: fs9p mount <address> <mountpoint> [options]

      --read-only          refuse writes
      --nfs-port=N         port for the loopback NFS server (default: any free port)
      --mount-option=OPT   extra option passed through to mount_nfs; repeatable
                           by comma-separating, e.g. --mount-option=intr,timeo=30
      --no-sudo            run mount_nfs directly instead of via sudo
      --background         detach once the mount is up
      --log=PATH           where a detached process writes its log
      --attr-timeout=SECS  how long to cache attributes (default: 1)

    plus the common connection options; see `fs9p help`.
    """

    static func run(_ arguments: Arguments) async throws {
        if arguments.has("help") { print(usage); return }
        try arguments.rejectUnknown(flagNames)
        guard arguments.positional.count >= 2 else { throw CLIError(usage) }

        let address = arguments.positional[0]
        let mountPoint = try resolveMountPoint(arguments.positional[1])

        if arguments.has("background") {
            try relaunchDetached(arguments: arguments, mountPoint: mountPoint)
            return
        }

        let readOnly = arguments.has("read-only")
        let connection = try ConnectionOptions(address: address, arguments: arguments)

        var vfsOptions = VFSOptions(readOnly: readOnly)
        if let seconds = arguments.int("attr-timeout") {
            vfsOptions.attributeCacheDuration = Double(seconds)
        }
        // The kernel presents whatever uid the NFS layer reports; a remote
        // server's ids rarely mean anything locally, so default to this user's.
        vfsOptions.forcedUID = UInt32(getuid())
        vfsOptions.forcedGID = UInt32(getgid())

        let client = try await connection.connect()
        note("connected to \(connection.endpoint), speaking \(client.version.rawValue)")
        let vfs = NineVFS(client: client, options: vfsOptions)

        var bridgeOptions = NFSBridgeOptions()
        bridgeOptions.port = UInt16(arguments.int("nfs-port") ?? 0)
        bridgeOptions.export.readOnly = readOnly
        let bridge = NFSBridge(vfs: vfs, options: bridgeOptions)

        let port = try bridge.start()
        note("NFS bridge listening on 127.0.0.1:\(port)")

        let extra = (arguments.string("mount-option")?
            .split(separator: ",").map(String.init)) ?? []
        let mountArguments = bridge.mountArguments(mountPoint: mountPoint, extraOptions: extra)

        do {
            try runMount(arguments: mountArguments, useSudo: !arguments.has("no-sudo"))
        } catch {
            bridge.stop()
            await vfs.shutdown()
            throw error
        }
        note("mounted \(address) on \(mountPoint)")
        note("unmount with: fs9p umount \(mountPoint)")

        // Hold the mount open. Unmounting from elsewhere makes the kernel stop
        // sending requests, but nothing tells us directly, so poll for the
        // mount going away as well as for a signal.
        installInterruptHandler {}
        while !Interrupt.requested {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !isMounted(mountPoint) {
                note("mount point went away; shutting down")
                break
            }
        }

        if isMounted(mountPoint) {
            try? unmount(mountPoint, useSudo: !arguments.has("no-sudo"))
        }
        bridge.stop()
        await vfs.shutdown()
        note("stopped")
    }

    // MARK: - unmount

    static func unmount(_ arguments: Arguments) throws {
        try arguments.rejectUnknown(["no-sudo", "force"])
        guard let target = arguments.positional.first else {
            throw CLIError("usage: fs9p umount <mountpoint>")
        }
        let path = (target as NSString).expandingTildeInPath
        guard isMounted(path) else { throw CLIError("'\(path)' is not mounted") }
        try unmount(path, useSudo: !arguments.has("no-sudo"), force: arguments.has("force"))
        print("unmounted \(path)")
    }

    private static func unmount(_ path: String, useSudo: Bool, force: Bool = false) throws {
        var argv = ["/sbin/umount"]
        if force { argv.append("-f") }
        argv.append(path)
        if useSudo && geteuid() != 0 { argv.insert("/usr/bin/sudo", at: 0) }
        let result = try execute(argv)
        guard result.status == 0 else {
            throw CLIError("umount failed: \(result.errorText.isEmpty ? "status \(result.status)" : result.errorText)")
        }
    }

    // MARK: - helpers

    private static func resolveMountPoint(_ raw: String) throws -> String {
        let path = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw CLIError("mount point '\(path)' does not exist; create it first")
        }
        guard isDir.boolValue else { throw CLIError("mount point '\(path)' is not a directory") }
        guard !isMounted(path) else { throw CLIError("'\(path)' already has something mounted on it") }
        // mount_nfs resolves symlinks and reports the real path; matching it
        // here keeps `isMounted` comparisons honest.
        return (path as NSString).resolvingSymlinksInPath
    }

    /// True when something is mounted at `path`.
    ///
    /// Comparing device numbers with the parent is the portable way to ask:
    /// a mount point's `st_dev` differs from its parent's.
    static func isMounted(_ path: String) -> Bool {
        var here = stat()
        var parent = stat()
        guard stat(path, &here) == 0 else { return false }
        let parentPath = (path as NSString).deletingLastPathComponent
        guard stat(parentPath.isEmpty ? "/" : parentPath, &parent) == 0 else { return false }
        return here.st_dev != parent.st_dev
    }

    private static func runMount(arguments: [String], useSudo: Bool) throws {
        var argv = [NFSMountCommand.executable] + arguments
        if useSudo && geteuid() != 0 {
            // mount(2) needs privileges on macOS. Say so plainly rather than
            // letting sudo's own prompt appear with no explanation.
            note("running mount_nfs under sudo; it may ask for your password")
            argv.insert("/usr/bin/sudo", at: 0)
        }
        note("+ " + argv.joined(separator: " "))
        let result = try execute(argv)
        guard result.status == 0 else {
            var message = "mount_nfs failed with status \(result.status)"
            if !result.errorText.isEmpty { message += ": \(result.errorText)" }
            #if canImport(Darwin)
            if result.errorText.contains("Operation not permitted") {
                message += "\n  On macOS 26, mounting a network volume can need "
                    + "explicit consent; check System Settings → Privacy & Security."
            }
            #endif
            throw CLIError(message)
        }
    }

    /// Re-runs this command as a detached process and waits for the mount to
    /// appear.
    ///
    /// Forking a process that already has threads and an async runtime is a
    /// good way to inherit a deadlock, so the background mode starts a fresh
    /// process instead.
    private static func relaunchDetached(arguments: Arguments, mountPoint: String) throws {
        let logPath = arguments.string("log")
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("fs9p-\(getpid()).log").path

        var argv = CommandLine.arguments
        argv.removeAll { $0 == "--background" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        _ = FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        process.standardOutput = log
        process.standardError = log
        try process.run()

        note("detached as pid \(process.processIdentifier), logging to \(logPath)")
        // Wait for the mount rather than reporting success optimistically.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if isMounted(mountPoint) {
                print("mounted on \(mountPoint)")
                return
            }
            if !process.isRunning {
                let text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
                throw CLIError("the background mount exited:\n\(text)")
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw CLIError("the mount did not come up within 30s; see \(logPath)")
    }

    struct ExecutionResult {
        var status: Int32
        var outputText: String
        var errorText: String
    }

    @discardableResult
    static func execute(_ argv: [String]) throws -> ExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read before waiting: a full pipe buffer would deadlock the child.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ExecutionResult(
            status: process.terminationStatus,
            outputText: String(decoding: outData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            errorText: String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Progress goes to stderr so `fs9p cat` and friends can be piped.
func note(_ message: String) {
    FileHandle.standardError.write(Data("fs9p: \(message)\n".utf8))
}
