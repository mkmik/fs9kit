import Foundation
import NineP
import NinePClient
import FS9Core

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Everything a mount needs, recovered from the URL `mount(8)` handed us.
///
/// `mount -F -t fs9kit 9p://host:564/aname /Volumes/x` reaches the extension as
/// an `FSGenericURLResource` carrying exactly one string, so the URL has to
/// carry the attach parameters and the tuning knobs as well as the address.
/// Parsing lives here, apart from FSKit, because it is the part most likely to
/// be wrong and the only part that can be tested off a Mac.
public struct MountSpec: Sendable, Hashable {
    /// Where to dial.
    public var endpoint: NinePEndpoint
    /// The 9P `aname`: which tree on the server to attach to.
    public var aname: String
    /// The 9P `uname`. `nil` means "whoever is running the extension".
    public var uname: String?
    /// Negotiated message size ceiling, `nil` for the client default.
    public var msize: UInt32?
    /// Force a single dialect instead of offering all three.
    public var version: NinePVersion?
    public var readOnly: Bool
    /// Report every file as owned by this uid/gid, for servers whose numbers
    /// mean nothing on this machine.
    public var forcedUID: UInt32?
    public var forcedGID: UInt32?
    public var debug: Bool
    /// What the volume should be called in Finder.
    public var volumeName: String
    /// A normalised `scheme://host:port/aname` string, with the options
    /// stripped. The container UUID is derived from this, so two mounts of the
    /// same tree with different options stay one container — which is what
    /// `fskitd` expects — while two different trees do not collide.
    public var canonicalTarget: String

    public init(
        endpoint: NinePEndpoint,
        aname: String = "",
        uname: String? = nil,
        msize: UInt32? = nil,
        version: NinePVersion? = nil,
        readOnly: Bool = false,
        forcedUID: UInt32? = nil,
        forcedGID: UInt32? = nil,
        debug: Bool = false,
        volumeName: String = "fs9kit",
        canonicalTarget: String = ""
    ) {
        self.endpoint = endpoint
        self.aname = aname
        self.uname = uname
        self.msize = msize
        self.version = version
        self.readOnly = readOnly
        self.forcedUID = forcedUID
        self.forcedGID = forcedGID
        self.debug = debug
        self.volumeName = volumeName
        self.canonicalTarget = canonicalTarget
    }
}

/// Why a mount URL could not be turned into a `MountSpec`.
///
/// Every case names the offending text: `probeResource` is never called for a
/// URL resource, so this error is the user's only feedback and it arrives as an
/// errno through `mount(8)`. The message goes to the log.
public enum MountURLError: Error, Equatable, CustomStringConvertible {
    case empty
    case notAURL(String)
    case unsupportedScheme(String)
    case missingHost
    case invalidPort(String)
    case unexpectedAuthority(String)
    case missingSocketPath
    case invalidPercentEncoding(String)
    case unknownOption(String)
    case invalidOptionValue(option: String, value: String)

    public var description: String {
        switch self {
        case .empty: "empty mount URL"
        case let .notAURL(s): "'\(s)' is not scheme://... form"
        case let .unsupportedScheme(s): "unsupported URL scheme '\(s)'"
        case .missingHost: "no host in the mount URL"
        case let .invalidPort(s): "'\(s)' is not a TCP port"
        case let .unexpectedAuthority(s): "a unix-socket URL takes no host, got '\(s)'"
        case .missingSocketPath: "no socket path in the mount URL"
        case let .invalidPercentEncoding(s): "'\(s)' is not valid percent-encoding"
        case let .unknownOption(k): "unknown option '\(k)'"
        case let .invalidOptionValue(k, v): "'\(v)' is not a valid value for '\(k)'"
        }
    }

    /// What `mount(8)` should print. Every one of these is the caller's fault.
    public var errnoValue: Int32 { EINVAL }
}

extension MountSpec {
    /// Schemes that mean "dial TCP". `9p` is the natural one and the one the
    /// `Info.plist` advertises first, but note that it is not a legal RFC 3986
    /// scheme — schemes must start with a letter — so a strict `NSURL` parser
    /// rejects `9p://…` outright. `mount(8)` builds the resource with
    /// `[NSURL URLWithString:]`, so `p9://` is registered as a spelling that
    /// cannot be rejected. See `docs/design/fskit-backend.md`.
    public static let tcpSchemes: Set<String> = ["9p", "9pfs", "p9"]
    /// Schemes that mean "dial a unix socket"; the path is the socket.
    public static let unixSchemes: Set<String> = ["9p+unix", "9pfs+unix", "p9+unix"]

    public static var allSchemes: [String] {
        (tcpSchemes.union(unixSchemes)).sorted()
    }

    /// Parses a mount URL.
    ///
    /// Hand-rolled rather than `URL(string:)` on purpose: Foundation's RFC 3986
    /// parser rejects a scheme starting with a digit, so `URL(string: "9p://h/a")`
    /// is `nil` on Linux and on any Foundation built with the strict parser.
    /// This parser accepts what a user will actually type.
    public static func parse(_ text: String) throws -> MountSpec {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MountURLError.empty }
        guard let separator = trimmed.range(of: "://") else {
            throw MountURLError.notAURL(trimmed)
        }
        let scheme = String(trimmed[trimmed.startIndex..<separator.lowerBound]).lowercased()
        guard tcpSchemes.contains(scheme) || unixSchemes.contains(scheme) else {
            throw MountURLError.unsupportedScheme(scheme)
        }

        // Strip the fragment first: nothing after '#' is ours, and a '?' inside
        // a fragment must not be read as the query.
        var rest = Substring(trimmed[separator.upperBound...])
        if let hash = rest.firstIndex(of: "#") { rest = rest[rest.startIndex..<hash] }
        var query = Substring("")
        if let mark = rest.firstIndex(of: "?") {
            query = rest[rest.index(after: mark)...]
            rest = rest[rest.startIndex..<mark]
        }

        let authority: Substring
        let rawPath: Substring
        if let slash = rest.firstIndex(of: "/") {
            authority = rest[rest.startIndex..<slash]
            rawPath = rest[slash...]
        } else {
            authority = rest
            rawPath = ""
        }

        var options = try Options(query: query)

        let endpoint: NinePEndpoint
        let canonicalTarget: String
        var defaultVolumeName: String
        var aname = ""

        if unixSchemes.contains(scheme) {
            guard authority.isEmpty else {
                throw MountURLError.unexpectedAuthority(String(authority))
            }
            let path = try percentDecoded(String(rawPath))
            guard !path.isEmpty, path != "/" else { throw MountURLError.missingSocketPath }
            endpoint = .unix(path: path)
            canonicalTarget = "9p+unix://\(path)"
            defaultVolumeName = path.split(separator: "/").last.map(String.init) ?? "fs9kit"
            // A unix-socket URL spends its path on the socket, so the tree to
            // attach to can only come from ?aname=.
            aname = options.take("aname") ?? ""
        } else {
            var hostPart = authority
            // userinfo doubles as the 9P uname: 9p://alice@host/tree.
            if let at = hostPart.lastIndex(of: "@") {
                let user = try percentDecoded(String(hostPart[hostPart.startIndex..<at]))
                if !user.isEmpty { options.userInfoName = user }
                hostPart = hostPart[hostPart.index(after: at)...]
            }
            let (host, port) = try splitHostPort(hostPart)
            guard !host.isEmpty else { throw MountURLError.missingHost }
            endpoint = .tcp(host: host, port: port ?? P9.defaultPort)
            let canonicalHost = host.contains(":") ? "[\(host)]" : host
            aname = try percentDecoded(String(rawPath.dropFirst()))
            if let override = options.take("aname") { aname = override }
            canonicalTarget = "9p://\(canonicalHost.lowercased()):\(port ?? P9.defaultPort)/\(aname)"
            defaultVolumeName = host
        }

        // A tree name makes a better volume name than the host: mounting two
        // trees off one server would otherwise give two identical volumes.
        if let last = aname.split(separator: "/").last, !last.isEmpty {
            defaultVolumeName = String(last)
        }

        try options.rejectLeftovers()

        return MountSpec(
            endpoint: endpoint,
            aname: aname,
            uname: options.uname ?? options.userInfoName,
            msize: options.msize,
            version: options.version,
            readOnly: options.readOnly,
            forcedUID: options.uid,
            forcedGID: options.gid,
            debug: options.debug,
            volumeName: sanitizeVolumeName(options.volumeName ?? defaultVolumeName),
            canonicalTarget: canonicalTarget)
    }

    /// A Finder-safe volume name: no separators, never empty, never longer than
    /// a filesystem name may be.
    static func sanitizeVolumeName(_ raw: String) -> String {
        var cleaned = ""
        for character in raw {
            switch character {
            case "/", ":", "\0": cleaned.append("-")
            default: cleaned.append(character)
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "fs9kit" }
        if cleaned.utf8.count <= 255 { return cleaned }
        return String(decoding: Array(cleaned.utf8.prefix(255)), as: UTF8.self)
    }

    private static func splitHostPort(_ authority: Substring) throws -> (host: String, port: Int?) {
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else {
                throw MountURLError.invalidPort(String(authority))
            }
            let host = String(authority[authority.index(after: authority.startIndex)..<close])
            let tail = authority[authority.index(after: close)...]
            if tail.isEmpty { return (host, nil) }
            guard tail.hasPrefix(":") else { throw MountURLError.invalidPort(String(tail)) }
            return (host, try port(String(tail.dropFirst())))
        }
        guard let colon = authority.lastIndex(of: ":") else {
            return (String(authority), nil)
        }
        return (String(authority[authority.startIndex..<colon]),
                try port(String(authority[authority.index(after: colon)...])))
    }

    private static func port(_ text: String) throws -> Int {
        guard let value = Int(text), (1...65535).contains(value) else {
            throw MountURLError.invalidPort(text)
        }
        return value
    }

    static func percentDecoded(_ text: String) throws -> String {
        guard text.contains("%") else { return text }
        guard let decoded = text.removingPercentEncoding else {
            throw MountURLError.invalidPercentEncoding(text)
        }
        return decoded
    }
}

// MARK: - Query options

extension MountSpec {
    /// The `?k=v&flag` half of a mount URL.
    ///
    /// Unknown keys are an error rather than being ignored: a silently dropped
    /// `?readonly` on a filesystem the user believed was read-only is worse
    /// than a failed mount.
    struct Options {
        var uname: String?
        var userInfoName: String?
        var msize: UInt32?
        var version: NinePVersion?
        var readOnly = false
        var uid: UInt32?
        var gid: UInt32?
        var debug = false
        var volumeName: String?
        private var pending: [String: String] = [:]
        private var unknown: [String] = []

        init(query: Substring) throws {
            for field in query.split(whereSeparator: { $0 == "&" || $0 == ";" }) {
                let key: String
                let value: String?
                if let equals = field.firstIndex(of: "=") {
                    key = String(field[field.startIndex..<equals]).lowercased()
                    value = try MountSpec.percentDecoded(String(field[field.index(after: equals)...]))
                } else {
                    key = String(field).lowercased()
                    value = nil
                }
                if key.isEmpty { continue }
                switch key {
                case "uname", "user": uname = value
                case "aname", "tree", "volname", "name":
                    // Consumed later: aname handling differs per scheme.
                    pending[key] = value ?? ""
                case "msize":
                    msize = try Self.msizeValue(key: key, value)
                case "version", "dialect":
                    version = try Self.versionValue(key: key, value)
                case "ro", "rdonly", "readonly":
                    readOnly = try Self.flag(key: key, value)
                case "rw":
                    readOnly = try !Self.flag(key: key, value)
                case "uid": uid = try Self.number(key: key, value)
                case "gid": gid = try Self.number(key: key, value)
                case "debug", "verbose":
                    debug = try Self.flag(key: key, value)
                default:
                    unknown.append(key)
                }
            }
            if let name = pending["volname"] ?? pending["name"] {
                volumeName = name
                pending.removeValue(forKey: "volname")
                pending.removeValue(forKey: "name")
            }
        }

        /// Removes and returns a deferred option, so the scheme-specific code
        /// can decide what it means.
        mutating func take(_ key: String) -> String? {
            if let value = pending.removeValue(forKey: key) { return value }
            if key == "aname", let value = pending.removeValue(forKey: "tree") { return value }
            return nil
        }

        func rejectLeftovers() throws {
            if let first = unknown.sorted().first { throw MountURLError.unknownOption(first) }
        }

        private static func flag(key: String, _ value: String?) throws -> Bool {
            guard let value, !value.isEmpty else { return true }
            switch value.lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: throw MountURLError.invalidOptionValue(option: key, value: value)
            }
        }

        private static func number(key: String, _ value: String?) throws -> UInt32 {
            guard let value, let parsed = UInt32(value) else {
                throw MountURLError.invalidOptionValue(option: key, value: value ?? "")
            }
            return parsed
        }

        /// `msize` bounds are the client's, not the protocol's: below 4 KiB a
        /// single directory entry may not fit in a message, and above 16 MiB a
        /// server is entitled to refuse the whole session.
        private static func msizeValue(key: String, _ value: String?) throws -> UInt32 {
            guard let value else { throw MountURLError.invalidOptionValue(option: key, value: "") }
            var digits = value.lowercased()
            var multiplier: UInt64 = 1
            if digits.hasSuffix("k") { multiplier = 1024; digits.removeLast() }
            else if digits.hasSuffix("m") { multiplier = 1024 * 1024; digits.removeLast() }
            guard let base = UInt64(digits) else {
                throw MountURLError.invalidOptionValue(option: key, value: value)
            }
            let bytes = base.multipliedReportingOverflow(by: multiplier)
            guard !bytes.overflow, (4096...(16 * 1024 * 1024)).contains(bytes.partialValue) else {
                throw MountURLError.invalidOptionValue(option: key, value: value)
            }
            return UInt32(bytes.partialValue)
        }

        private static func versionValue(key: String, _ value: String?) throws -> NinePVersion {
            guard let value else { throw MountURLError.invalidOptionValue(option: key, value: "") }
            switch value.lowercased() {
            case "9p2000.l", "l", ".l", "linux": return .v9P2000L
            case "9p2000.u", "u", ".u", "unix": return .v9P2000u
            case "9p2000", "legacy", "plain": return .v9P2000
            default: throw MountURLError.invalidOptionValue(option: key, value: value)
            }
        }
    }
}

// MARK: - Turning a spec into client configuration

extension MountSpec {
    public func makeCredentials() -> NinePCredentials {
        NinePCredentials(
            uname: uname ?? NinePCredentials.currentUserName(),
            aname: aname,
            numericUID: forcedUID)
    }

    public func makeSessionOptions() -> NinePSessionOptions {
        var options = NinePSessionOptions()
        if let msize { options.msize = msize }
        if let version { options.versions = [version] }
        return options
    }

    public func makeVFSOptions() -> VFSOptions {
        VFSOptions(
            forcedUID: forcedUID,
            forcedGID: forcedGID,
            readOnly: readOnly)
    }
}
