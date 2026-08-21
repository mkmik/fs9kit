// Compiled only where the macOS 26 SDK is in play.
//
// `canImport(FSKit)` alone is not a strong enough gate: the framework exists in
// the macOS 15.4 SDK too, but there it has no FSGenericURLResource — the class
// that makes it possible to mount something with no block device behind it —
// and its protocol reply handlers differ. Compiling this against that SDK fails
// on both counts.
//
// There is no `#if` that asks the SDK's version directly, so the compiler
// version stands in for it: the macOS 26 SDK ships with Xcode 26, whose Swift
// is 6.2 or later, while the 15.4 SDK ships with Xcode 16.4 and Swift 6.1. A
// deliberately mismatched pairing — a standalone 6.2 toolchain aimed at the
// 15.4 SDK — would defeat this, but that combination cannot build the backend
// anyway.
#if canImport(FSKit) && compiler(>=6.2)
import Foundation
// FSKit's protocol reply handlers are not `@Sendable`, so a witness that
// declares them `@Sendable` does not satisfy the requirement — which then makes
// the whole type fail to conform, and the extension entry point fail its
// associated-type constraint. The handlers are therefore spelled exactly as the
// framework spells them, and the import is `@preconcurrency` so that capturing
// one in a Task is a warning about Apple's annotations rather than an error in
// ours.
@preconcurrency import FSKit
import FS9Core

/// One file in a mounted 9P tree, as FSKit sees it.
///
/// FSKit hands the same `FSItem` object back on every call about a file and
/// uses object identity to decide what is what, so exactly one of these exists
/// per VFS node for as long as the kernel holds a reference. `FS9Volume` interns
/// them in an `FS9ItemTable`; nothing else should construct one.
///
/// The item deliberately caches almost nothing. Attributes live in `NineVFS`,
/// which already has a TTL on them; duplicating that here would mean two caches
/// to invalidate and one of them would go stale.
@available(macOS 26.0, *)
final class FS9Item: FSItem, @unchecked Sendable {
    /// The VFS node this stands for. Immutable: a rename changes the name, not
    /// the identity.
    let node: NodeID
    /// What FSKit knows this file as. Fixed for the item's lifetime because
    /// FSKit derives `fileID` from it and expects that to be stable.
    let itemID: UInt64

    private let lock = NSLock()
    private var storedName: String
    private var storedParent: NodeID?
    private var storedKind: FS9ItemKind
    /// How many times FSKit has opened this item and not yet closed it. The
    /// underlying 9P fid is released when this reaches zero.
    private var openCount = 0

    init(node: NodeID, name: String, kind: FS9ItemKind, parent: NodeID?) {
        self.node = node
        self.itemID = FS9ItemIdentifier.itemID(for: node)
        self.storedName = name
        self.storedKind = kind
        self.storedParent = parent
        super.init()
    }

    var name: String { lock.withLock { storedName } }
    var parent: NodeID? { lock.withLock { storedParent } }
    var kind: FS9ItemKind { lock.withLock { storedKind } }
    var isDirectory: Bool { kind == .directory }

    /// Refreshes what a rename or a fresh `getattr` taught us.
    func update(name: String? = nil, parent: NodeID?? = .none, kind: FS9ItemKind? = nil) {
        lock.withLock {
            if let name { storedName = name }
            if case let .some(parent) = parent { storedParent = parent }
            if let kind, kind != .unknown { storedKind = kind }
        }
    }

    /// Returns true when this is the first open, so the caller knows to do the
    /// work that only needs doing once.
    func retainOpen() -> Bool {
        lock.withLock {
            openCount += 1
            return openCount == 1
        }
    }

    /// Returns true when the last open has been closed and the fid may go.
    func releaseOpen() -> Bool {
        lock.withLock {
            guard openCount > 0 else { return false }
            openCount -= 1
            return openCount == 0
        }
    }

    var isOpen: Bool { lock.withLock { openCount > 0 } }
}
#endif
