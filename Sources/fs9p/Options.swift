import Foundation
import NineP
import NinePClient
import FS9Core

/// A very small option parser.
///
/// The project takes no external dependencies, and the surface here is small
/// enough that hand-parsing is clearer than vendoring an argument library.
struct Arguments {
    private(set) var positional: [String] = []
    private var flags: [String: String] = [:]
    private var present: Set<String> = []

    init(_ raw: [String]) {
        var it = raw.makeIterator()
        while let arg = it.next() {
            guard arg.hasPrefix("--") else { positional.append(arg); continue }
            let body = String(arg.dropFirst(2))
            if let eq = body.firstIndex(of: "=") {
                flags[String(body[body.startIndex..<eq])] = String(body[body.index(after: eq)...])
                present.insert(String(body[body.startIndex..<eq]))
            } else {
                present.insert(body)
            }
        }
    }

    func has(_ name: String) -> Bool { present.contains(name) }
    func string(_ name: String) -> String? { flags[name] }
    func int(_ name: String) -> Int? { flags[name].flatMap(Int.init) }

    /// Rejects flags the command does not understand, so a typo is an error
    /// rather than a silently ignored request.
    func rejectUnknown(_ known: Set<String>) throws {
        let unknown = present.subtracting(known)
        guard unknown.isEmpty else {
            throw CLIError("unknown option\(unknown.count > 1 ? "s" : ""): "
                + unknown.sorted().map { "--\($0)" }.joined(separator: ", "))
        }
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

/// Options shared by every command that opens a 9P connection.
struct ConnectionOptions {
    var endpoint: NinePEndpoint
    var credentials: NinePCredentials
    var session: NinePSessionOptions

    /// Flag names understood here, so commands can add their own and still
    /// reject typos.
    static let flagNames: Set<String> = [
        "uname", "aname", "uid", "gid", "msize", "version", "timeout", "debug",
    ]

    init(address: String, arguments: Arguments) throws {
        endpoint = try NinePEndpoint.parse(address)

        var credentials = NinePCredentials()
        if let uname = arguments.string("uname") { credentials.uname = uname }
        if let aname = arguments.string("aname") { credentials.aname = aname }
        if let uid = arguments.int("uid") {
            credentials.numericUID = UInt32(uid)
            credentials.defaultUID = UInt32(uid)
        }
        if let gid = arguments.int("gid") { credentials.defaultGID = UInt32(gid) }
        self.credentials = credentials

        var session = NinePSessionOptions()
        if let msize = arguments.int("msize") { session.msize = UInt32(msize) }
        if let version = arguments.string("version") {
            guard let v = NinePVersion(rawValue: version) else {
                throw CLIError("unknown 9P version '\(version)'; expected one of "
                    + NinePVersion.allCases.map(\.rawValue).joined(separator: ", "))
            }
            // Pinning matters: some servers cannot answer an offer they do not
            // understand and simply say nothing, costing a timeout per dial.
            session.versions = [v]
        }
        if let timeout = arguments.int("timeout") {
            session.connectTimeout = Double(timeout)
            session.handshakeTimeout = Double(timeout)
        }
        self.session = session
    }

    func connect() async throws -> NinePClient {
        try await NinePClient.connect(to: endpoint, credentials: credentials, options: session)
    }

    func openVFS(readOnly: Bool = false) async throws -> NineVFS {
        let client = try await connect()
        return NineVFS(client: client, options: VFSOptions(readOnly: readOnly))
    }
}

/// Formats a mode the way `ls -l` does, which is what a human reading this
/// output is comparing against.
func modeString(_ attrs: FileAttributes) -> String {
    let type: Character
    switch attrs.type {
    case .directory: type = "d"
    case .symlink: type = "l"
    case .fifo: type = "p"
    case .socket: type = "s"
    case .blockDevice: type = "b"
    case .characterDevice: type = "c"
    case .regular: type = "-"
    }
    var out = String(type)
    let bits = attrs.permissions
    for shift in stride(from: 6, through: 0, by: -3) {
        let group = (bits >> UInt16(shift)) & 7
        out.append(group & 4 != 0 ? "r" : "-")
        out.append(group & 2 != 0 ? "w" : "-")
        out.append(group & 1 != 0 ? "x" : "-")
    }
    return out
}

func humanSize(_ bytes: UInt64) -> String {
    let units = ["B", "K", "M", "G", "T", "P"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
    return unit == 0 ? "\(bytes)B" : String(format: "%.1f%@", value, units[unit])
}

func formatTime(_ t: FileTime) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: Date(timeIntervalSince1970: t.timeIntervalSince1970))
}
