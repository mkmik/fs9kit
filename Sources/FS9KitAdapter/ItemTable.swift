import Foundation
import FS9Core

/// The live `FSItem` objects for a mount, keyed by VFS node.
///
/// FSKit hands an `FSItem` back on every call and expects the *same* object for
/// the same file: two objects for one inode make the kernel treat them as two
/// files, and `reclaimItem` then frees state the other one still needs. So the
/// volume interns items here.
///
/// Generic over the item type only so it can be exercised on Linux, where
/// `FSItem` does not exist. The lock is an `NSLock` rather than an actor because
/// every caller is an FSKit reply handler that must not suspend just to read a
/// dictionary.
public final class FS9ItemTable<Item: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [NodeID: Item] = [:]

    public init() {}

    public var count: Int {
        lock.withLock { items.count }
    }

    /// Returns the interned item for `node`, creating it with `make` if this is
    /// the first sighting. `make` runs under the lock, so it must not call back
    /// into the table.
    public func item(for node: NodeID, make: () -> Item) -> Item {
        lock.withLock {
            if let existing = items[node] { return existing }
            let fresh = make()
            items[node] = fresh
            return fresh
        }
    }

    public func existing(_ node: NodeID) -> Item? {
        lock.withLock { items[node] }
    }

    /// Forgets one item. Returns it so the caller can finish tearing it down
    /// outside the lock.
    @discardableResult
    public func remove(_ node: NodeID) -> Item? {
        lock.withLock { items.removeValue(forKey: node) }
    }

    /// Everything currently interned. A snapshot: the caller may act on it
    /// without holding the lock.
    public func all() -> [Item] {
        lock.withLock { Array(items.values) }
    }

    /// Empties the table, returning everything it held. Used at unmount, where
    /// each item still needs its fid clunked.
    public func drain() -> [Item] {
        lock.withLock {
            let all = Array(items.values)
            items.removeAll()
            return all
        }
    }
}
