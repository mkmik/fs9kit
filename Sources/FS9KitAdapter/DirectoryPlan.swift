import Foundation
import FS9Core

/// One entry as `FSDirectoryEntryPacker.packEntry` wants it.
public struct FS9DirectoryEntry: Sendable, Hashable {
    public var name: String
    public var kind: FS9ItemKind
    public var itemID: UInt64
    /// The cookie that resumes the listing *after* this entry.
    public var nextCookie: UInt64
    /// The VFS node, kept so the shim can fetch attributes if FSKit asked for
    /// them without re-resolving the name.
    public var node: NodeID

    public init(name: String, kind: FS9ItemKind, itemID: UInt64, nextCookie: UInt64, node: NodeID) {
        self.name = name
        self.kind = kind
        self.itemID = itemID
        self.nextCookie = nextCookie
        self.node = node
    }
}

/// Turns `NineVFS` directory chunks into what FSKit's packer expects.
///
/// The cookie is the 9P offset unchanged. That works because both sides treat
/// zero as "start" and neither ascribes any other meaning to the value: 9P2000.L
/// `Rreaddir` offsets are opaque server tokens and `FSDirectoryCookie` is an
/// opaque `UInt64`. Rewriting them — adding a bias to make room for synthesised
/// entries, say — would break the moment a server returned an offset near
/// `UInt64.max`, which `telldir`-based servers legitimately do.
///
/// `.` and `..` are dropped. 9P2000.L `Treaddir` includes them and FSKit's
/// sample code does not pack them, so passing them through would double them up
/// in the kernel's view. UNCONFIRMED that FSKit really synthesises them — if a
/// mount shows no `.`/`..`, this is the place to change.
public enum FS9DirectoryPlanner {
    /// True for the entries a directory listing must not repeat.
    public static func isDotEntry(_ name: String) -> Bool { name == "." || name == ".." }

    /// Converts one chunk. `parent` is only needed to keep dot entries out even
    /// when a server spells them oddly, which none do — it is unused today and
    /// deliberately not a parameter.
    public static func plan(_ chunk: DirectoryChunk) -> [FS9DirectoryEntry] {
        var entries: [FS9DirectoryEntry] = []
        entries.reserveCapacity(chunk.entries.count)
        for entry in chunk.entries where !isDotEntry(entry.name) {
            entries.append(FS9DirectoryEntry(
                name: entry.name,
                kind: FS9ItemKind(entry.type),
                itemID: FS9ItemIdentifier.itemID(for: entry.node),
                nextCookie: entry.cookie,
                node: entry.node))
        }
        return entries
    }

    /// The cookie to ask the VFS for next, given what FSKit handed back.
    public static func offset(forCookie cookie: UInt64) -> UInt64 { cookie }

    /// Whether a chunk means the listing is finished.
    ///
    /// A chunk can be non-empty and still yield no packable entries — a
    /// directory holding only `.` and `..` — so "finished" has to come from the
    /// chunk, not from the planned entries.
    public static func isFinished(_ chunk: DirectoryChunk) -> Bool {
        chunk.atEnd || chunk.entries.isEmpty
    }

    /// The cookie that resumes after a chunk, or `nil` when there is nothing
    /// left to resume from.
    public static func resumeCookie(after chunk: DirectoryChunk) -> UInt64? {
        chunk.entries.last?.cookie
    }
}
