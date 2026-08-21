import Foundation
import NineP

/// Somewhere a server listens.
public enum NinePEndpoint: Sendable, Hashable, CustomStringConvertible {
    case tcp(host: String, port: UInt16)
    /// A Unix domain socket. The path is removed when the server stops.
    case unix(path: String)

    public var description: String {
        switch self {
        case let .tcp(host, port): return "tcp://\(host):\(port)"
        case let .unix(path): return "unix:\(path)"
        }
    }

    public var port: UInt16? {
        if case let .tcp(_, port) = self { return port }
        return nil
    }
}

/// Knobs for ``NinePServer`` and ``NinePSession``.
public struct NinePServerConfiguration: Sendable {
    /// Largest frame the server will accept or emit. Tversion clamps the
    /// client's proposal to this.
    public var maxMessageSize: UInt32 = NineP.defaultMsize
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
