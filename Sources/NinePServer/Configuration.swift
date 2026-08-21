import Foundation
import NineP

/// Knobs for ``NinePServer`` and ``NinePServerSession``.
public struct NinePServerConfiguration: Sendable {
    /// Largest frame the server will accept or emit. Tversion clamps the
    /// client's proposal to this.
    public var maxMessageSize: UInt32 = P9.defaultMsize
    /// Smallest msize worth negotiating. Below this a single directory entry
    /// may not fit in a reply, so the server answers `unknown` instead of
    /// agreeing to something it cannot serve.
    public var minimumMessageSize: UInt32 = 512
    /// Dialects offered, most preferred first.
    public var supportedVersions: [NinePVersion] = [.v9P2000L, .v9P2000u, .v9P2000]
    /// Where to listen. The default is an ephemeral loopback TCP port, which is
    /// what tests want; ``NinePServer/boundEndpoints`` reports the real one.
    public var endpoints: [NinePEndpoint] = [.tcp(host: "127.0.0.1", port: 0)]
    public var backlog: Int32 = 64
    /// An oversized frame is drained (so the connection stays usable) only up
    /// to this many bytes; beyond it the connection is dropped rather than
    /// letting a peer make us read forever.
    public var maxDrainBytes: Int = 1 << 20
    /// Receive timeout for a connection, in seconds. Zero blocks forever, which
    /// is fine because ``NinePServer/stop()`` shuts sockets down to wake reads.
    public var receiveTimeout: TimeInterval = 0

    public init() {}
}
