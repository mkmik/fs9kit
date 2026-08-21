// READDIR and READDIRPLUS.
//
// These are the two procedures where a subtle bug becomes an infinite loop
// instead of an error, so they get their own file and a lot of comments.
//
// Three rules matter:
//
//  1. The `count` (or `maxcount`) in the request bounds the *whole encoded
//     reply*, not the number of entries. A reply that overflows it is dropped
//     by the client, which retries with the same cookie — forever.
//  2. `.` and `..` must appear when the cookie is zero. macOS tolerates their
//     absence; other clients do not, and `find` relies on them.
//  3. `eof` must be true only when the listing is genuinely finished. Setting
//     it early truncates directories; never setting it makes the client ask
//     again with the last cookie and get an empty page each time.

import Foundation
import FS9Core

extension NFSProgram {
    /// Where a listing resumes, decoded from the client's cookie.
    ///
    /// NFS cookies are opaque 64-bit values chosen by the server, so we encode
    /// our own meaning into them: the two low bits distinguish the synthetic
    /// `.`/`..` positions from a real 9P directory offset, which is shifted up
    /// out of the way. A cookie that does not fit the scheme is rejected with
    /// NFS3ERR_BAD_COOKIE rather than guessed at.
    struct DirectoryResume {
        var emitDot: Bool
        var emitDotDot: Bool
        var nineCookie: UInt64

        static let dotEmitted: UInt64 = 1
        static let dotDotEmitted: UInt64 = 2
        /// Marks a cookie that carries a 9P offset in its upper 62 bits.
        static let realEntryTag: UInt64 = 3

        init(cookie: UInt64) throws {
            switch cookie {
            case 0:
                self = DirectoryResume(emitDot: true, emitDotDot: true, nineCookie: 0)
            case Self.dotEmitted:
                self = DirectoryResume(emitDot: false, emitDotDot: true, nineCookie: 0)
            case Self.dotDotEmitted:
                self = DirectoryResume(emitDot: false, emitDotDot: false, nineCookie: 0)
            default:
                guard cookie & 3 == Self.realEntryTag else { throw NFSStatus.badCookie.failure }
                self = DirectoryResume(emitDot: false, emitDotDot: false, nineCookie: cookie >> 2)
            }
        }

        private init(emitDot: Bool, emitDotDot: Bool, nineCookie: UInt64) {
            self.emitDot = emitDot
            self.emitDotDot = emitDotDot
            self.nineCookie = nineCookie
        }

        /// The cookie a client sends back to resume *after* a real entry.
        static func cookie(afterNineCookie nine: UInt64) throws -> UInt64 {
            // 9P offsets are byte or index offsets into a directory, so this
            // never triggers in practice; it is here because silently wrapping
            // would hand the client a cookie that resumes somewhere else.
            guard nine < (UInt64(1) << 62) else { throw NFSStatus.serverfault.failure }
            return nine << 2 | realEntryTag
        }
    }

    /// One entry as it will be encoded.
    struct DirectoryItem {
        var name: String
        var fileID: UInt64
        var cookie: UInt64
        var node: NodeID?
        var attributes: NFSFileAttributes?
    }

    /// Bytes of `READDIR3resok` that are not entries: status, the directory's
    /// `post_op_attr`, the cookie verifier, the list terminator and `eof`.
    static var directoryReplyOverhead: Int { 4 + 4 + NFSFileAttributes.encodedSize + 8 + 4 + 4 }

    /// `entry3`: a `true` discriminant, the fileid, the name, and the cookie.
    static func entryCost(name: String) -> Int {
        4 + 8 + 4 + xdrPadded(name.utf8.count) + 8
    }

    /// The extra an `entryplus3` costs: `post_op_attr` and `post_op_fh3`.
    static func entryPlusExtraCost() -> Int {
        let attributes = 4 + NFSFileAttributes.encodedSize
        let handle = 4 + 4 + xdrPadded(NFSFileHandle.encodedSize)
        return attributes + handle
    }

    /// Verifies the cookie verifier the client echoed back.
    ///
    /// Ours is constant for the life of the server, so a mismatch means the
    /// cookie came from a previous instance and cannot be resumed.
    private func checkCookieVerifier(_ verifier: [UInt8], cookie: UInt64) throws {
        guard cookie != 0 else { return }
        guard verifier == export.boot.bytes || verifier.allSatisfy({ $0 == 0 }) else {
            throw NFSStatus.badCookie.failure
        }
    }

    /// Collects entries until a budget is spent or the directory ends.
    ///
    /// The price of a candidate is computed *before* it is accepted, so no
    /// budget is ever exceeded — the whole point of the exercise. READDIRPLUS
    /// has two budgets running at once, which is why they are parameters here
    /// rather than a closure the caller supplies.
    private func collect(
        directory: NodeID,
        resume: DirectoryResume,
        totalBudget: Int,
        nameBudget: Int?,
        perEntryExtra: Int,
        needsAttributes: Bool
    ) async throws -> (items: [DirectoryItem], eof: Bool) {
        var remainingTotal = totalBudget
        var remainingNames = nameBudget ?? Int.max
        var items: [DirectoryItem] = []
        var eof = false
        var full = false

        var synthetic: [(name: String, fileID: UInt64, cookie: UInt64, node: NodeID)] = []
        if resume.emitDot {
            synthetic.append((".", directory, DirectoryResume.dotEmitted, directory))
        }
        if resume.emitDotDot {
            // The parent of the export root is itself, which is what a local
            // filesystem reports for a mount point too.
            let parent = (try? await export.vfs.lookup(parent: directory, name: "..").node) ?? directory
            synthetic.append(("..", parent, DirectoryResume.dotDotEmitted, parent))
        }
        for entry in synthetic {
            let base = Self.entryCost(name: entry.name)
            guard base <= remainingNames, base + perEntryExtra <= remainingTotal else {
                full = true
                break
            }
            remainingNames -= base
            remainingTotal -= base + perEntryExtra
            var item = DirectoryItem(
                name: entry.name, fileID: entry.fileID, cookie: entry.cookie, node: entry.node)
            if needsAttributes { item.attributes = await postAttributes(entry.node) }
            items.append(item)
        }

        var nine = resume.nineCookie
        while !full {
            let chunk = try await export.vfs.readDirectory(directory, cookie: nine)
            if chunk.entries.isEmpty {
                eof = true
                break
            }
            for entry in chunk.entries {
                let base = Self.entryCost(name: entry.name)
                guard base <= remainingNames, base + perEntryExtra <= remainingTotal else {
                    full = true
                    break
                }
                remainingNames -= base
                remainingTotal -= base + perEntryExtra
                var item = DirectoryItem(
                    name: entry.name, fileID: entry.node,
                    cookie: try DirectoryResume.cookie(afterNineCookie: entry.cookie),
                    node: entry.node)
                if needsAttributes { item.attributes = await postAttributes(entry.node) }
                items.append(item)
                // Resume from the last entry we actually accepted, so a page
                // that stops early is continued exactly where it left off.
                nine = entry.cookie
            }
        }
        return (items, eof)
    }

    func readdir(_ d: inout XDRDecoder) async -> [UInt8] {
        var node: NodeID?
        var e = XDREncoder()
        do {
            let directory = try decodeHandle(&d)
            node = directory
            let cookie = try d.uint64()
            let verifier = try d.opaqueFixed(NFSConstants.verifierSize)
            let count = Int(try d.uint32())
            try checkCookieVerifier(verifier, cookie: cookie)
            let resume = try DirectoryResume(cookie: cookie)

            let budget = count - Self.directoryReplyOverhead
            guard budget >= Self.entryCost(name: "..") else { throw NFSStatus.toosmall.failure }

            let result = try await collect(
                directory: directory, resume: resume, totalBudget: budget,
                nameBudget: nil, perEntryExtra: 0, needsAttributes: false)
            guard !result.items.isEmpty || result.eof else { throw NFSStatus.toosmall.failure }

            e.uint32(NFSStatus.ok.rawValue)
            encodePostOpAttributes(&e, await postAttributes(directory))
            e.opaqueFixed(export.boot.bytes)
            for item in result.items {
                e.bool(true)
                e.uint64(item.fileID)
                e.string(item.name)
                e.uint64(item.cookie)
            }
            e.bool(false)
            e.bool(result.eof)
        } catch {
            e = XDREncoder()
            e.uint32(nfsStatus(for: error).rawValue)
            encodePostOpAttributes(&e, node == nil ? nil : await postAttributes(node!))
        }
        return e.bytes
    }

    func readdirPlus(_ d: inout XDRDecoder) async -> [UInt8] {
        var node: NodeID?
        var e = XDREncoder()
        do {
            let directory = try decodeHandle(&d)
            node = directory
            let cookie = try d.uint64()
            let verifier = try d.opaqueFixed(NFSConstants.verifierSize)
            // `dircount` bounds the name-and-cookie part alone; `maxcount`
            // bounds the entire reply including attributes and handles. Both
            // have to be honoured, so the effective budget is whichever runs
            // out first.
            let dircount = Int(try d.uint32())
            let maxcount = Int(try d.uint32())
            try checkCookieVerifier(verifier, cookie: cookie)
            let resume = try DirectoryResume(cookie: cookie)

            let extra = Self.entryPlusExtraCost()
            let byMax = maxcount - Self.directoryReplyOverhead
            // Convert the dircount limit into the same units as the full cost
            // so a single budget can enforce both.
            let names = max(0, dircount)
            let entries = max(0, byMax)
            guard entries >= Self.entryCost(name: "..") + extra,
                  names >= Self.entryCost(name: "..") else {
                throw NFSStatus.toosmall.failure
            }

            let result = try await collect(
                directory: directory, resume: resume, totalBudget: entries,
                nameBudget: names, perEntryExtra: extra, needsAttributes: true)
            guard !result.items.isEmpty || result.eof else { throw NFSStatus.toosmall.failure }

            e.uint32(NFSStatus.ok.rawValue)
            encodePostOpAttributes(&e, await postAttributes(directory))
            e.opaqueFixed(export.boot.bytes)
            for item in result.items {
                e.bool(true)
                e.uint64(item.fileID)
                e.string(item.name)
                e.uint64(item.cookie)
                encodePostOpAttributes(&e, item.attributes)
                if let itemNode = item.node {
                    e.bool(true)
                    e.opaqueVariable(handleBytes(itemNode))
                } else {
                    e.bool(false)
                }
            }
            e.bool(false)
            e.bool(result.eof)
        } catch {
            e = XDREncoder()
            e.uint32(nfsStatus(for: error).rawValue)
            encodePostOpAttributes(&e, node == nil ? nil : await postAttributes(node!))
        }
        return e.bytes
    }
}
