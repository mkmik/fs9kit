import Testing
import Foundation
import NineP
@testable import NinePServer

@Suite("Version negotiation")
struct VersionNegotiationTests {
    private func session(_ configure: ((inout NinePServerConfiguration) -> Void)? = nil) -> NinePSession {
        var configuration = NinePServerConfiguration()
        configure?(&configuration)
        return NinePSession(fileSystem: MemoryFileSystem(), configuration: configuration)
    }

    @Test("each supported dialect is echoed back", arguments: NinePVersion.allCases)
    func supportedDialects(version: NinePVersion) throws {
        let s = session()
        let reply = s.negotiate(version, msize: 4096)
        #expect(reply == .rversion(msize: 4096, version: version.rawValue))
        #expect(s.negotiatedVersion == version)
        #expect(s.codec.version == version)
    }

    @Test("an unknown protocol is refused with \"unknown\"")
    func unknownProtocol() {
        let s = session()
        let reply = s.send(.tversion(msize: 4096, version: "SSH-2.0"), tag: P9.notag)
        #expect(reply == .rversion(msize: 4096, version: "unknown"))
        #expect(s.negotiatedVersion == nil)
    }

    @Test("an unrecognised member of the 9P2000 family degrades to base 9P2000")
    func unknownExtension() {
        let s = session()
        let reply = s.send(.tversion(msize: 4096, version: "9P2000.q"), tag: P9.notag)
        #expect(reply == .rversion(msize: 4096, version: "9P2000"))
        #expect(s.negotiatedVersion == .v9P2000)
    }

    @Test("a dialect the server does not offer falls back to base 9P2000")
    func unofferedDialect() {
        let s = session { $0.supportedVersions = [.v9P2000] }
        let reply = s.send(.tversion(msize: 4096, version: "9P2000.L"), tag: P9.notag)
        #expect(reply == .rversion(msize: 4096, version: "9P2000"))
    }

    @Test("msize is clamped to the server maximum but never raised")
    func msizeClamping() {
        let s = session { $0.maxMessageSize = 8192 }
        #expect(s.negotiate(.v9P2000L, msize: 1 << 20) == .rversion(msize: 8192, version: "9P2000.L"))
        #expect(s.msize == 8192)

        let small = session { $0.maxMessageSize = 8192 }
        #expect(small.negotiate(.v9P2000L, msize: 4096) == .rversion(msize: 4096, version: "9P2000.L"))
        #expect(small.msize == 4096)
    }

    @Test("an msize too small to carry a reply is refused")
    func msizeTooSmall() {
        let s = session { $0.minimumMessageSize = 512 }
        let reply = s.send(.tversion(msize: 32, version: "9P2000.L"), tag: P9.notag)
        #expect(reply == .rversion(msize: 32, version: "unknown"))
        #expect(s.negotiatedVersion == nil)
    }

    @Test("requests before Tversion are refused")
    func beforeNegotiation() {
        let s = session()
        let reply = s.send(.tattach(fid: 0, afid: P9.nofid, uname: "u", aname: "", numericUID: 0))
        #expect(replyErrno(reply) == LinuxErrno.einval)
    }

    @Test("Tversion clunks every fid")
    func versionResetsFids() throws {
        let s = try makeSession(try sampleTree())
        #expect(!isError(s.send(.tstat(fid: 0))))
        s.negotiate(.v9P2000L)
        #expect(replyErrno(s.send(.tstat(fid: 0))) == LinuxErrno.ebadf)
    }
}

@Suite("Attach and walk")
struct WalkTests {
    @Test("attach binds a fid to the root directory")
    func attach() throws {
        let s = try makeSession(try sampleTree())
        let reply = s.send(.tattach(fid: 1, afid: P9.nofid, uname: "u", aname: "", numericUID: 7))
        guard case let .rattach(qid) = reply else { Issue.record("got \(reply)"); return }
        #expect(qid.isDir)
    }

    @Test("attaching onto a fid already in use fails")
    func attachTwice() throws {
        let s = try makeSession(try sampleTree())
        let reply = s.send(.tattach(fid: 0, afid: P9.nofid, uname: "u", aname: "", numericUID: 7))
        #expect(replyErrno(reply) == LinuxErrno.einval)
    }

    @Test("attach can export a subtree by aname")
    func attachSubtree() throws {
        let s = try makeSession(try sampleTree())
        try s.attachRoot(fid: 5, aname: "/docs")
        guard case let .rwalk(qids) = s.send(.twalk(fid: 5, newfid: 6, names: ["a.txt"])) else {
            Issue.record("expected Rwalk"); return
        }
        #expect(qids.count == 1)
    }

    @Test("a full walk binds newfid and returns one qid per name")
    func fullWalk() throws {
        let s = try makeSession(try sampleTree())
        guard case let .rwalk(qids) = s.send(.twalk(fid: 0, newfid: 1, names: ["docs", "a.txt"])) else {
            Issue.record("expected Rwalk"); return
        }
        #expect(qids.count == 2)
        #expect(qids[0].isDir)
        #expect(!qids[1].isDir)
        #expect(!isError(s.send(.tstat(fid: 1))))
    }

    @Test("a walk of zero names clones the fid")
    func cloneWalk() throws {
        let s = try makeSession(try sampleTree())
        #expect(s.send(.twalk(fid: 0, newfid: 3, names: [])) == .rwalk(qids: []))
        guard case let .rstat(stat) = s.send(.tstat(fid: 3)) else { Issue.record("expected Rstat"); return }
        #expect(stat.qid.isDir)
    }

    @Test("a partial walk returns fewer qids and leaves newfid unbound")
    func partialWalk() throws {
        let s = try makeSession(try sampleTree())
        guard case let .rwalk(qids) = s.send(.twalk(fid: 0, newfid: 4, names: ["docs", "nope", "deeper"])) else {
            Issue.record("expected Rwalk"); return
        }
        #expect(qids.count == 1)
        #expect(replyErrno(s.send(.tstat(fid: 4))) == LinuxErrno.ebadf)
    }

    @Test("walking past a non-directory stops the walk without an error")
    func walkThroughFile() throws {
        let s = try makeSession(try sampleTree())
        guard case let .rwalk(qids) = s.send(.twalk(fid: 0, newfid: 4, names: ["hello.txt", "more"])) else {
            Issue.record("expected Rwalk"); return
        }
        #expect(qids.count == 1)
        #expect(replyErrno(s.send(.tstat(fid: 4))) == LinuxErrno.ebadf)
    }

    @Test("walking from a fid that is not a directory is ENOTDIR")
    func walkFromFile() throws {
        let s = try makeSession(try sampleTree())
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["hello.txt"]))
        #expect(replyErrno(s.send(.twalk(fid: 1, newfid: 2, names: ["x"]))) == LinuxErrno.enotdir)
    }

    @Test("a missing first element is an error, not a partial walk")
    func missingFirstElement() throws {
        let s = try makeSession(try sampleTree())
        #expect(replyErrno(s.send(.twalk(fid: 0, newfid: 1, names: ["nope"]))) == LinuxErrno.enoent)
    }

    @Test("sixteen names are allowed and seventeen are not")
    func walkLimit() throws {
        let fs = MemoryFileSystem()
        let deep = (0..<16).map { "d\($0)" }
        try fs.addDirectory("/" + deep.joined(separator: "/"))
        let s = try makeSession(fs)
        guard case let .rwalk(qids) = s.send(.twalk(fid: 0, newfid: 1, names: deep)) else {
            Issue.record("expected Rwalk"); return
        }
        #expect(qids.count == P9.maxWalkElements)
        #expect(replyErrno(s.send(.twalk(fid: 0, newfid: 2, names: deep + ["d16"]))) == LinuxErrno.einval)
    }

    @Test("newfid must not already be in use")
    func newfidInUse() throws {
        let s = try makeSession(try sampleTree())
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["docs"]))
        #expect(replyErrno(s.send(.twalk(fid: 0, newfid: 1, names: ["empty"]))) == LinuxErrno.einval)
    }

    @Test("newfid may equal fid, which moves the fid in place")
    func walkOntoSelf() throws {
        let s = try makeSession(try sampleTree())
        #expect(!isError(s.send(.twalk(fid: 0, newfid: 0, names: ["docs"]))))
        guard case let .rstat(stat) = s.send(.tstat(fid: 0)) else { Issue.record("expected Rstat"); return }
        #expect(stat.name == "docs")
    }

    @Test("dot-dot cannot climb above the attach point")
    func dotDotIsClamped() throws {
        let s = try makeSession(try sampleTree())
        try s.attachRoot(fid: 7, aname: "/docs")
        guard case let .rwalk(qids) = s.send(.twalk(fid: 7, newfid: 8, names: ["..", "..", "a.txt"])) else {
            Issue.record("expected Rwalk"); return
        }
        // "a.txt" still resolves, so the two ".."s stayed inside /docs.
        #expect(qids.count == 3)
    }

    @Test("an open fid cannot be walked")
    func walkOpenFid() throws {
        let s = try makeSession(try sampleTree())
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["docs"]))
        _ = s.send(.tlopen(fid: 1, flags: .rdonly))
        #expect(replyErrno(s.send(.twalk(fid: 1, newfid: 2, names: ["a.txt"]))) == LinuxErrno.einval)
    }
}
