import Foundation
import NineP

/// Hands out fid numbers and takes them back.
///
/// Fid numbers are chosen by the client, must be unique among the fids in use
/// on a connection, and may be reused once clunked. Reusing the lowest free
/// number keeps servers' fid tables small.
final class FidPool: @unchecked Sendable {
    private let lock = NSLock()
    private var next: Fid = 1  // fid 0 is reserved for the root attach
    private var free: [Fid] = []

    func allocate() throws -> Fid {
        lock.lock()
        defer { lock.unlock() }
        if let f = free.popLast() { return f }
        guard next < NineP.nofid else {
            throw NinePClientError.protocolViolation("out of fids")
        }
        let f = next
        next += 1
        return f
    }

    func release(_ fid: Fid) {
        guard fid != NineP.nofid else { return }
        lock.lock()
        free.append(fid)
        lock.unlock()
    }

    /// Fids currently handed out. Used by tests to catch leaks.
    var outstandingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(next) - 1 - free.count
    }
}
