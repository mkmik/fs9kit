// What the two RPC programs share: the VFS being re-exported, the boot
// verifier that stamps its handles, and the sizes advertised by FSINFO.

import Foundation
import FS9Core
import NineP

/// Tuning for the exported tree.
public struct NFSExportOptions: Sendable {
    /// The path clients pass to MOUNT. There is exactly one export, so this is
    /// cosmetic apart from having to match.
    public var path: String
    /// Refuse every modifying procedure with NFS3ERR_ROFS. Independent of the
    /// VFS's own read-only flag; either one is enough to make the export
    /// read-only.
    public var readOnly: Bool
    /// Hard ceiling on the read/write sizes advertised by FSINFO.
    ///
    /// 64 KiB is the largest value macOS's client is known to accept without
    /// complaint; going higher is worth measuring but is not the default.
    public var maximumTransferSize: Int
    /// Reported by FSSTAT when the 9P server has no numbers of its own.
    public var fallbackTotalBytes: UInt64

    public init(path: String = "/", readOnly: Bool = false,
                maximumTransferSize: Int = 64 * 1024,
                fallbackTotalBytes: UInt64 = 1 << 40) {
        self.path = path
        self.readOnly = readOnly
        self.maximumTransferSize = maximumTransferSize
        self.fallbackTotalBytes = fallbackTotalBytes
    }
}

/// One exported 9P tree, shared by the MOUNT and NFS programs.
public final class NFSExport: Sendable {
    public let vfs: NineVFS
    public let options: NFSExportOptions
    /// Stamped into every file handle and returned as the write verifier.
    public let boot: BootVerifier
    /// `fsid` reported in every `fattr3`. Derived from the boot verifier so two
    /// bridges running at once look like two different filesystems.
    public let fsid: UInt64
    /// Largest READ and WRITE payload we advertise, a power of two.
    public let transferSize: Int

    public init(vfs: NineVFS, options: NFSExportOptions = NFSExportOptions(),
                boot: BootVerifier = .generate()) {
        self.vfs = vfs
        self.options = options
        self.boot = boot
        self.fsid = boot.value | 1
        self.transferSize = Self.preferredTransferSize(
            preferred: vfs.preferredIOSize, cap: options.maximumTransferSize)
    }

    public var path: String { options.path }

    /// The export root's node. Fixed by the VFS, so no actor hop is needed.
    public var rootNode: NodeID { NineVFS.rootNode }

    /// True when nothing may be modified through this export.
    public var isReadOnly: Bool { options.readOnly || vfs.options.readOnly }

    /// The 9P dialect decides which FSINFO properties we may claim: hard links
    /// are 9P2000.L only, and symlinks need at least 9P2000.u.
    public var supportsHardLinks: Bool { vfs.protocolVersion.isLinux }
    public var supportsSymlinks: Bool { vfs.protocolVersion != .v9P2000 }

    /// Rounds the negotiated 9P payload size down to a power of two and clamps
    /// it into a range clients accept.
    ///
    /// Rounding *down* matters: a transfer size the 9P layer cannot satisfy in
    /// one message turns every read into two, and NFS clients take the
    /// advertised preferred size literally.
    public static func preferredTransferSize(preferred: Int, cap: Int) -> Int {
        let ceiling = max(4096, min(cap, 1 << 20))
        let usable = max(4096, min(preferred, ceiling))
        var size = 4096
        while size << 1 <= usable { size <<= 1 }
        return size
    }
}
