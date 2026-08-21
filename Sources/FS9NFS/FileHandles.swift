// NFSv3 file handles.
//
// A handle is opaque to the client and at most 64 bytes (RFC 1813, NFS3_FHSIZE),
// and the client will hand the same bytes back for the whole life of the mount
// — including across a restart of *our* process, because the kernel has no idea
// we went away. That is why every handle carries a boot verifier: after a
// restart the node numbering is meaningless, and a handle minted by the
// previous instance must be rejected with NFS3ERR_STALE rather than quietly
// resolving to whatever file now happens to have that node number.

import Foundation
import FS9Core

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Largest handle NFSv3 permits.
public let nfsFileHandleSize = 64

/// A per-server-instance random value stamped into every file handle and used
/// as the NFS write verifier.
///
/// Both uses need the same property: constant while the server runs, different
/// after a restart.
public struct BootVerifier: Sendable, Hashable {
    public let value: UInt64

    public init(value: UInt64) { self.value = value }

    /// Draws a fresh verifier. The time component keeps two instances started
    /// in the same second apart even if the random source is poor.
    public static func generate() -> BootVerifier {
        var raw = UInt64.random(in: UInt64.min...UInt64.max)
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        raw ^= UInt64(bitPattern: Int64(ts.tv_sec)) << 20
        raw ^= UInt64(bitPattern: Int64(ts.tv_nsec))
        return BootVerifier(value: raw)
    }

    /// The eight-byte form NFS calls a `writeverf3` / `cookieverf3`.
    public var bytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * $0)) }
    }
}

/// The parsed contents of one of our file handles.
public struct NFSFileHandle: Sendable, Hashable {
    /// `"9NFS"`, so a handle from some other server on the same port is
    /// rejected instead of misread.
    public static let magic: UInt32 = 0x394E_4653
    public static let currentVersion: UInt8 = 1
    /// magic(4) + version(1) + boot verifier(8) + node(8).
    public static let encodedSize = 21

    public var boot: BootVerifier
    public var node: NodeID

    public init(boot: BootVerifier, node: NodeID) {
        self.boot = boot
        self.node = node
    }

    public var bytes: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(Self.encodedSize)
        for shift in stride(from: 24, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: Self.magic >> UInt32(shift)))
        }
        out.append(Self.currentVersion)
        out.append(contentsOf: boot.bytes)
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: node >> UInt64(shift)))
        }
        return out
    }

    /// Parses a handle, rejecting anything not minted by this instance.
    ///
    /// Every failure mode is the same to the client — NFS3ERR_STALE — because
    /// the correct client response to all of them is identical: throw the
    /// handle away and look the file up again.
    public static func decode(_ raw: [UInt8], boot: BootVerifier) -> NFSFileHandle? {
        guard raw.count == encodedSize else { return nil }
        var magicValue: UInt32 = 0
        for i in 0..<4 { magicValue = magicValue << 8 | UInt32(raw[i]) }
        guard magicValue == magic, raw[4] == currentVersion else { return nil }
        var bootValue: UInt64 = 0
        for i in 5..<13 { bootValue = bootValue << 8 | UInt64(raw[i]) }
        guard bootValue == boot.value else { return nil }
        var node: NodeID = 0
        for i in 13..<21 { node = node << 8 | UInt64(raw[i]) }
        return NFSFileHandle(boot: boot, node: node)
    }
}
