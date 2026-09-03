// MOUNT protocol version 3, RFC 1813 appendix I.
//
// The mount protocol exists only to turn a path into the root file handle; all
// real work happens over NFS afterwards. It is served on the *same* port as
// NFS here, which is why `mount_nfs` is invoked with both `port=` and
// `mountport=` — without a portmapper on 127.0.0.1 there is nothing to ask.

import Foundation

/// Program and version numbers, and the procedure list.
public enum MountConstants {
    public static let program: UInt32 = 100_005
    public static let version: UInt32 = 3

    public static let procedureNull: UInt32 = 0
    public static let procedureMount: UInt32 = 1
    public static let procedureDump: UInt32 = 2
    public static let procedureUnmount: UInt32 = 3
    public static let procedureUnmountAll: UInt32 = 4
    public static let procedureExport: UInt32 = 5

    /// MNTPATHLEN from the RFC.
    public static let maximumPathLength = 1024
    /// MNTNAMLEN from the RFC.
    public static let maximumNameLength = 255
}

/// `mountstat3`. A separate numbering from `nfsstat3` even though the values
/// overlap for the errno-shaped ones.
public enum MountStatus: UInt32, Sendable {
    case ok = 0
    case perm = 1
    case noent = 2
    case io = 5
    case acces = 13
    case notdir = 20
    case inval = 22
    case nametoolong = 63
    case notsupp = 10004
    case serverfault = 10006
}

/// One client's record of a live mount, as reported by DUMP.
public struct MountEntry: Sendable, Hashable {
    public var hostname: String
    public var directory: String
}

/// The MOUNTv3 server.
///
/// State (who has mounted what) is small and touched once per mount, so it
/// lives in the actor rather than behind a lock.
public actor MountProgram: RPCProgram {
    public nonisolated let program = MountConstants.program
    public nonisolated let versions = MountConstants.version...MountConstants.version

    private let export: NFSExport
    private var mounts: [MountEntry] = []

    public init(export: NFSExport) {
        self.export = export
    }

    /// The clients currently holding a mount, most recent last.
    public var currentMounts: [MountEntry] { mounts }

    public func call(procedure: UInt32, arguments: XDRDecoder, context: RPCContext) async throws -> [UInt8] {
        var args = arguments
        switch procedure {
        case MountConstants.procedureNull:
            return []
        case MountConstants.procedureMount:
            return try mount(&args, context)
        case MountConstants.procedureDump:
            return dump()
        case MountConstants.procedureUnmount:
            return try unmount(&args, context)
        case MountConstants.procedureUnmountAll:
            mounts.removeAll { $0.hostname == hostname(for: context) }
            return []
        case MountConstants.procedureExport:
            return exports()
        default:
            throw RPCProgramError.procedureUnavailable
        }
    }

    /// AUTH_SYS is the only place a hostname appears — the accepted socket is
    /// always 127.0.0.1, so the peer address tells us nothing useful.
    private nonisolated func hostname(for context: RPCContext) -> String {
        let name = context.credentials?.machineName ?? ""
        return name.isEmpty ? "localhost" : name
    }

    private func mount(_ args: inout XDRDecoder, _ context: RPCContext) throws -> [UInt8] {
        let path = try args.string(limit: MountConstants.maximumPathLength)
        var e = XDREncoder()

        // Only the exported path is mountable. Both the bare export and the
        // export with a trailing slash are accepted, because clients normalise
        // differently and rejecting one of them is a mysterious mount failure.
        let wanted = normalize(path)
        guard wanted == normalize(export.path) else {
            e.uint32(MountStatus.noent.rawValue)
            return e.bytes
        }

        let handle = NFSFileHandle(boot: export.boot, node: export.rootNode)
        e.uint32(MountStatus.ok.rawValue)
        e.opaqueVariable(handle.bytes)
        // The flavors we will accept on subsequent NFS calls, in preference
        // order. AUTH_NONE is offered so a client that cannot build AUTH_SYS
        // credentials still gets in; nothing here is a security boundary,
        // since the socket is bound to loopback.
        e.array([RPCConstants.authSys, RPCConstants.authNone]) { $0.uint32($1) }

        let entry = MountEntry(hostname: hostname(for: context), directory: path)
        if !mounts.contains(entry) { mounts.append(entry) }
        return e.bytes
    }

    private func unmount(_ args: inout XDRDecoder, _ context: RPCContext) throws -> [UInt8] {
        let path = try args.string(limit: MountConstants.maximumPathLength)
        let host = hostname(for: context)
        mounts.removeAll { $0.hostname == host && $0.directory == path }
        return []
    }

    /// `mountlist` is an XDR linked list: each element is preceded by a `true`
    /// discriminant and the chain is terminated by `false`.
    private func dump() -> [UInt8] {
        var e = XDREncoder()
        for entry in mounts {
            e.bool(true)
            e.string(entry.hostname)
            e.string(entry.directory)
        }
        e.bool(false)
        return e.bytes
    }

    /// `exportlist`, also a linked list, where each entry carries its own
    /// linked list of allowed groups. We export one tree to everybody, which
    /// is expressed as an empty group list.
    private func exports() -> [UInt8] {
        var e = XDREncoder()
        e.bool(true)
        e.string(export.path)
        e.bool(false)  // no group restrictions
        e.bool(false)  // end of the export list
        return e.bytes
    }

    private nonisolated func normalize(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty ? "/" : trimmed
    }
}
