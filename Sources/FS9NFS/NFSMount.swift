// The mount driver: start the loopback NFS server, hand out the port, and
// build the `mount_nfs` command line.
//
// Running `mount` is deliberately *not* done here. It needs privileges, it
// belongs to a process's lifecycle rather than a library's, and a library that
// shells out to a setuid binary is a library that cannot be unit-tested. The
// CLI owns that step; this type only says what the arguments should be.

import Foundation
import FS9Core

/// Options for a whole bridge: the export plus where to listen.
public struct NFSBridgeOptions: Sendable {
    public var export: NFSExportOptions
    /// Always a loopback address. Binding anywhere else would expose an
    /// unauthenticated filesystem to the network.
    public var host: String
    /// 0 asks the kernel for a free port, which is the sensible default: the
    /// well-known NFS port 2049 usually needs privileges and may be taken.
    public var port: UInt16
    public var maximumRecordSize: Int

    public init(export: NFSExportOptions = NFSExportOptions(),
                host: String = "127.0.0.1", port: UInt16 = 0,
                maximumRecordSize: Int = 1 << 21) {
        self.export = export
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
    @discardableResult
    public func start() throws -> UInt16 {
        try server.start()
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
