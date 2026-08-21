import Testing
import Foundation
import NineP
@testable import NinePServer

// MARK: - Session driving

extension NinePServerSession {
    /// Sends one request and returns the reply body.
    func send(_ message: Message, tag: NineP.Tag = 1) -> Message {
        handle(Frame(tag: tag, message: message)).message
    }

    @discardableResult
    func negotiate(_ version: NinePVersion, msize: UInt32 = 8192) -> Message {
        send(.tversion(msize: msize, version: version.rawValue), tag: P9.notag)
    }

    /// Attaches fid 0 to the root and returns its qid.
    @discardableResult
    func attachRoot(fid: NineP.Fid = 0, aname: String = "") throws -> Qid {
        let reply = send(.tattach(fid: fid, afid: P9.nofid, uname: "tester",
                                  aname: aname, numericUID: 1000))
        guard case let .rattach(qid) = reply else {
            Issue.record("expected Rattach, got \(reply)")
            throw TestFailure.unexpectedReply
        }
        return qid
    }
}

enum TestFailure: Error { case unexpectedReply }

/// Builds a session that has already negotiated `version` and attached fid 0.
func makeSession(
    _ fileSystem: any NinePFileServer,
    version: NinePVersion = .v9P2000L,
    msize: UInt32 = 8192,
    configure: ((inout NinePServerConfiguration) -> Void)? = nil
) throws -> NinePServerSession {
    var configuration = NinePServerConfiguration()
    configure?(&configuration)
    let session = NinePServerSession(fileSystem: fileSystem, configuration: configuration)
    session.negotiate(version, msize: msize)
    try session.attachRoot()
    return session
}

// MARK: - Reply inspection

/// The errno carried by any of the three error replies, or nil if `message`
/// is not an error at all.
func replyErrno(_ message: Message) -> UInt32? {
    switch message {
    case let .rlerror(errno): return errno
    case let .rerror(_, errno): return errno
    default: return nil
    }
}

func replyErrorText(_ message: Message) -> String? {
    if case let .rerror(text, _) = message { return text }
    return nil
}

func isError(_ message: Message) -> Bool {
    if case .rlerror = message { return true }
    if case .rerror = message { return true }
    return false
}

/// Decodes a base-9P2000 directory read: stat structures back to back.
func decodeStats(_ bytes: [UInt8], dotu: Bool = false) throws -> [Stat] {
    var reader = ByteReader(bytes)
    var stats: [Stat] = []
    while !reader.isAtEnd {
        stats.append(try reader.stat(dotu: dotu))
    }
    return stats
}

// MARK: - Fixtures

/// ```
/// /            dir
///   hello.txt  "hello, 9P"
///   docs/      dir
///     a.txt    "alpha"
///     b.txt    "beta"
///   empty/     dir
///   link       -> hello.txt
/// ```
func sampleTree() throws -> MemoryFileSystem {
    let fs = MemoryFileSystem()
    try fs.addFile("/hello.txt", text: "hello, 9P")
    try fs.addFile("/docs/a.txt", text: "alpha")
    try fs.addFile("/docs/b.txt", text: "beta")
    try fs.addDirectory("/empty")
    try fs.addSymlink("/link", target: "hello.txt")
    return fs
}

/// A directory holding `count` files named `file000`, `file001`, ...
func wideTree(count: Int) throws -> MemoryFileSystem {
    let fs = MemoryFileSystem()
    for i in 0..<count {
        try fs.addFile("/many/\(String(format: "file%03d", i))", text: "\(i)")
    }
    return fs
}

/// Creates a scratch directory that is removed when `body` returns.
///
/// Deliberately short, and rooted at `/tmp` rather than at the per-user
/// temporary directory. A `sockaddr_un` holds 104 bytes of path on Darwin, and
/// macOS's `NSTemporaryDirectory()` is something like
/// `/var/folders/_5/zjnzxgh147qcg3bb5cg2wvqw0000gn/T/` — 48 characters before
/// anything of ours — so a UUID-named subdirectory leaves no room for a socket
/// name. Tests that only need files would not care; the one that binds a Unix
/// socket does.
func withTemporaryDirectory<T>(_ body: (String) throws -> T) throws -> T {
    var name = ""
    for _ in 0..<8 { name.append("0123456789abcdef".randomElement()!) }
    let path = "/tmp/9pt-" + name
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: path) }
    return try body(path)
}
