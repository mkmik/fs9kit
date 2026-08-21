import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Where a 9P server can be reached, or where one listens.
///
/// Shared by the client and the server so a single value can be passed between
/// them and printed the same way on both sides.
public enum NinePEndpoint: Sendable, Hashable, CustomStringConvertible {
    /// A TCP host and port. 9P's registered port is 564.
    case tcp(host: String, port: Int)
    /// A Unix domain socket path.
    case unix(path: String)
    /// An already-connected file descriptor, which the user takes ownership of.
    /// Used for stdio-style transports such as `ssh host 9pserve`.
    case fileDescriptor(Int32)

    public var description: String {
        switch self {
        case let .tcp(host, port): "tcp!\(host)!\(port)"
        case let .unix(path): "unix!\(path)"
        case let .fileDescriptor(fd): "fd!\(fd)"
        }
    }

    /// The TCP port, if this is a TCP endpoint.
    public var port: Int? {
        if case let .tcp(_, port) = self { return port }
        return nil
    }

    /// Errors from ``parse(_:defaultPort:)``.
    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public let input: String
        public var description: String { "cannot parse 9P address '\(input)'" }
    }

    /// Parses the Plan 9 dial string forms plus a few conveniences:
    /// `tcp!host!port`, `unix!/path`, `host:port`, `host`, `/path/to/socket`.
    public static func parse(_ s: String, defaultPort: Int = P9.defaultPort) throws -> NinePEndpoint {
        if s.hasPrefix("/") || s.hasPrefix("./") { return .unix(path: s) }
        let parts = s.split(separator: "!", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 2 {
            switch parts[0] {
            case "tcp", "tcp4", "tcp6":
                let port = parts.count >= 3 ? Int(parts[2]) ?? defaultPort : defaultPort
                return .tcp(host: parts[1], port: port)
            case "unix":
                return .unix(path: parts.dropFirst().joined(separator: "!"))
            default:
                throw ParseError(input: s)
            }
        }
        // host:port, with IPv6 literals in brackets.
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) ?? defaultPort : defaultPort
            return .tcp(host: host, port: port)
        }
        if let colon = s.lastIndex(of: ":"), let port = Int(s[s.index(after: colon)...]) {
            return .tcp(host: String(s[s.startIndex..<colon]), port: port)
        }
        return .tcp(host: s, port: defaultPort)
    }
}
