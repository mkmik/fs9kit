// The mount driver: start the loopback NFS server, hand out the port, and
// build the `mount_nfs` command line.
//
// Running `mount` is deliberately *not* done here. It needs privileges, it
// belongs to a process's lifecycle rather than a library's, and a library that
// shells out to a setuid binary is a library that cannot be unit-tested. The
// CLI owns that step; this type only says what the arguments should be.

import Foundation
import FS9Core

/// Why a bridge refused to start.
public enum NFSBridgeError: Error, CustomStringConvertible, Equatable {
    /// Someone asked to listen somewhere other than loopback without saying
    /// they meant it.
    case nonLoopbackHost(String)

    public var description: String {
        switch self {
        case let .nonLoopbackHost(host):
            "refusing to serve an unauthenticated NFS export on \(host); "
                + "set allowNonLoopbackHost if that is really what you want"
        }
    }
}

/// Options for a whole bridge: the export plus where to listen.
public struct NFSBridgeOptions: Sendable {
    public var export: NFSExportOptions
    /// Where to listen. Enforced to be a loopback address unless
    /// ``allowNonLoopbackHost`` is set: this server performs no authentication
    /// whatsoever, so binding it to a routable address would hand the whole
    /// exported tree to anyone who can reach the port.
    public var host: String
    /// Deliberately expose the export beyond this machine. There is no
    /// authentication, so this is only ever right behind something else that
    /// does the authenticating.
    public var allowNonLoopbackHost: Bool = false
    /// 0 asks the kernel for a free port, which is the sensible default: the
    /// well-known NFS port 2049 usually needs privileges and may be taken.
    public var port: UInt16
    public var maximumRecordSize: Int

    public init(export: NFSExportOptions = NFSExportOptions(),
                host: String = "127.0.0.1", port: UInt16 = 0,
                maximumRecordSize: Int = 1 << 21,
                allowNonLoopbackHost: Bool = false) {
        self.export = export
        self.allowNonLoopbackHost = allowNonLoopbackHost
        self.host = host
        self.port = port
        self.maximumRecordSize = maximumRecordSize
    }
}

/// An NFSv3 + MOUNTv3 server on loopback that re-exports a 9P tree.
///
/// Both programs share one TCP port. There is no portmapper (rpcbind) on the
/// loopback address we bind, and asking the system one to register would need
/// privileges, so the client is told the port explicitly instead.
public final class NFSBridge: @unchecked Sendable {
    public let export: NFSExport
    public let options: NFSBridgeOptions
    public let nfs: NFSProgram
    public let mount: MountProgram

    private let server: RPCServer

    public init(vfs: NineVFS, options: NFSBridgeOptions = NFSBridgeOptions()) {
        self.options = options
        let export = NFSExport(vfs: vfs, options: options.export)
        self.export = export
        let nfs = NFSProgram(export: export)
        let mount = MountProgram(export: export)
        self.nfs = nfs
        self.mount = mount
        self.server = RPCServer(
            programs: [nfs, mount],
            options: RPCServerOptions(
                host: options.host, port: options.port,
                maximumRecordSize: options.maximumRecordSize))
    }

    /// Binds and starts serving, returning the port in use.
    public func start() throws -> UInt16 {
        guard options.allowNonLoopbackHost || NFSBridge.isLoopback(options.host) else {
            throw NFSBridgeError.nonLoopbackHost(options.host)
        }
        return try server.start()
    }

    /// True for addresses that only this machine can reach: 127.0.0.0/8 and
    /// the IPv6 loopback.
    public static func isLoopback(_ host: String) -> Bool {
        if host == "::1" || host == "localhost" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
        return parts[0] == "127"
    }

    /// The port NFS and MOUNT are served on, once started.
    public var port: UInt16? { server.boundPort }

    /// Stops serving and drops every connection. Safe to call twice.
    public func stop() {
        server.stop()
    }

    /// The read and write size the export advertises, for the matching
    /// `rsize`/`wsize` mount options.
    public var transferSize: Int { export.transferSize }

    /// Builds the argument list for `/sbin/mount_nfs`.
    ///
    /// - Parameters:
    ///   - mountPoint: an existing directory to mount onto.
    ///   - extraOptions: appended verbatim to `-o`, for callers that need one
    ///     more knob without this type growing a property for it.
    public func mountArguments(mountPoint: String, extraOptions: [String] = []) -> [String] {
        NFSMountCommand.arguments(
            host: options.host,
            port: port ?? options.port,
            exportPath: export.path,
            mountPoint: mountPoint,
            transferSize: transferSize,
            readOnly: export.isReadOnly,
            extraOptions: extraOptions)
    }
}

/// Builds `mount_nfs` command lines. Free-standing so the CLI can render one
/// without starting a server, and so the option set can be tested.
public enum NFSMountCommand {
    public static let executable = "/sbin/mount_nfs"

    /// The options we pass, and why each one is there:
    ///
    /// - `vers=3` — we implement NFSv3 only. Without it macOS 26 may try
    ///   NFSv4.1 first and fail slowly.
    /// - `tcp` — the record-marking layer above is TCP-only, and UDP NFS has
    ///   no reassembly story worth having.
    /// - `port=N,mountport=N` — there is no rpcbind listening on our loopback
    ///   address, so both programs must be named explicitly. They share a port.
    /// - `soft` — a hung bridge must surface as EIO to the application rather
    ///   than an uninterruptible process. This is a userspace server that can
    ///   exit; hard mounts would leave unkillable processes behind.
    /// - `timeo=50,retrans=2` — five seconds per attempt and two retries, so a
    ///   stalled bridge gives up in about fifteen seconds. `soft` alone leaves
    ///   the client on its defaults, which retry for long enough that a dead
    ///   bridge looks like a hang rather than an error — and an unmount of a
    ///   wedged mount inherits that wait.
    /// - `nolocks,locallocks` — we implement no NLM (lockd) at all. `nolocks`
    ///   stops the client trying to reach one; `locallocks` makes `flock` and
    ///   `fcntl` locks work between processes on this machine, which is what
    ///   applications on a single-client mount actually need.
    /// - `rsize`/`wsize` — matched to what FSINFO advertises, which is derived
    ///   from the negotiated 9P msize. Leaving them unset lets the client pick
    ///   something the 9P layer has to split.
    /// - `nobrowse` — keeps the volume out of the Finder sidebar and out of
    ///   Spotlight's indexer, which would otherwise walk the whole remote tree
    ///   the moment it is mounted.
    /// - `noresvport` — do not use a privileged source port; we do not check
    ///   for one, and needing it would make unprivileged mounts impossible.
    public static func options(
        port: UInt16, transferSize: Int, readOnly: Bool, extra: [String] = []
    ) -> [String] {
        var options = [
            "vers=3",
            "tcp",
            "port=\(port)",
            "mountport=\(port)",
            "soft",
            "timeo=50",
            "retrans=2",
            "nolocks",
            "locallocks",
            "rsize=\(transferSize)",
            "wsize=\(transferSize)",
            "nobrowse",
            "noresvport",
        ]
        if readOnly { options.append("rdonly") }
        options.append(contentsOf: extra)
        return options
    }

    public static func arguments(
        host: String, port: UInt16, exportPath: String, mountPoint: String,
        transferSize: Int, readOnly: Bool, extraOptions: [String] = []
    ) -> [String] {
        [
            "-o",
            options(port: port, transferSize: transferSize,
                    readOnly: readOnly, extra: extraOptions).joined(separator: ","),
            "\(host):\(exportPath)",
            mountPoint,
        ]
    }

    /// The whole command line, for logging or for a caller that runs it.
    public static func commandLine(
        host: String, port: UInt16, exportPath: String, mountPoint: String,
        transferSize: Int, readOnly: Bool, extraOptions: [String] = []
    ) -> [String] {
        [executable] + arguments(
            host: host, port: port, exportPath: exportPath, mountPoint: mountPoint,
            transferSize: transferSize, readOnly: readOnly, extraOptions: extraOptions)
    }
}
