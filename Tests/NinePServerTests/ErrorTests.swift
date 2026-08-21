import Testing
import Foundation
import NineP
@testable import NinePServer

@Suite("Error mapping")
struct ErrorMappingTests {
    /// The same failure, asked for in each dialect: 9P2000.L must answer with a
    /// bare errno, the other two with a message a human can read.
    private func failure(_ version: NinePVersion,
                         _ body: (NinePSession) -> Message) throws -> Message {
        body(try makeSession(try sampleTree(), version: version))
    }

    @Test("a missing file is ENOENT")
    func missingFile() throws {
        let linux = try failure(.v9P2000L) { $0.send(.twalk(fid: 0, newfid: 1, names: ["nope"])) }
        #expect(linux == .rlerror(errno: LinuxErrno.enoent))

        let legacy = try failure(.v9P2000) { $0.send(.twalk(fid: 0, newfid: 1, names: ["nope"])) }
        #expect(replyErrorText(legacy)?.isEmpty == false)
        if case .rlerror = legacy { Issue.record("9P2000 must not use Rlerror") }
    }

    @Test("walking through a file is ENOTDIR")
    func notADirectory() throws {
        let linux = try failure(.v9P2000L) { s in
            _ = s.send(.twalk(fid: 0, newfid: 1, names: ["hello.txt"]))
            return s.send(.twalk(fid: 1, newfid: 2, names: ["deeper"]))
        }
        #expect(linux == .rlerror(errno: LinuxErrno.enotdir))

        let legacy = try failure(.v9P2000) { s in
            _ = s.send(.twalk(fid: 0, newfid: 1, names: ["hello.txt"]))
            return s.send(.twalk(fid: 1, newfid: 2, names: ["deeper"]))
        }
        #expect(replyErrorText(legacy)?.isEmpty == false)
    }

    @Test("an exclusive create over an existing file is EEXIST")
    func exclusiveCreate() throws {
        let linux = try failure(.v9P2000L) { s in
            _ = s.send(.twalk(fid: 0, newfid: 1, names: []))
            return s.send(.tlcreate(fid: 1, name: "hello.txt",
                                    flags: [.rdwr, .create, .excl], mode: 0o644, gid: 0))
        }
        #expect(linux == .rlerror(errno: LinuxErrno.eexist))

        // Base 9P2000 Tcreate is always exclusive.
        let legacy = try failure(.v9P2000) { s in
            s.send(.tcreate(fid: 0, name: "hello.txt", perm: FileMode(rawValue: 0o644),
                            mode: .write, extensionString: nil))
        }
        #expect(replyErrorText(legacy)?.isEmpty == false)
        #expect(replyErrno(legacy) == LinuxErrno.eexist)
    }

    @Test("removing a non-empty directory is ENOTEMPTY")
    func notEmpty() throws {
        let linux = try failure(.v9P2000L) {
            $0.send(.tunlinkat(dirfid: 0, name: "docs", flags: UnlinkAtFlags.removeDir))
        }
        #expect(linux == .rlerror(errno: LinuxErrno.enotempty))

        let legacy = try failure(.v9P2000) { s in
            _ = s.send(.twalk(fid: 0, newfid: 1, names: ["docs"]))
            return s.send(.tremove(fid: 1))
        }
        #expect(replyErrorText(legacy)?.isEmpty == false)
        #expect(replyErrno(legacy) == LinuxErrno.enotempty)
    }

    @Test("an unknown fid is EBADF in every dialect", arguments: NinePVersion.allCases)
    func unknownFid(version: NinePVersion) throws {
        let reply = try failure(version) { $0.send(.tclunk(fid: 77)) }
        #expect(replyErrno(reply) == LinuxErrno.ebadf)
    }

    @Test("an invalid file name is rejected")
    func invalidName() throws {
        let s = try makeSession(try sampleTree())
        #expect(replyErrno(s.send(.tmkdir(dfid: 0, name: "..", mode: 0o755, gid: 0))) == LinuxErrno.einval)
        #expect(replyErrno(s.send(.tmkdir(dfid: 0, name: "a/b", mode: 0o755, gid: 0))) == LinuxErrno.einval)
        #expect(replyErrno(s.send(.tmkdir(dfid: 0, name: "", mode: 0o755, gid: 0))) == LinuxErrno.einval)
    }

    /// The wire carries Linux numbering whatever the host uses. On Darwin
    /// ENOTEMPTY is 66 and EAGAIN is 11-as-EDEADLK, so a server that forwarded
    /// the host value would tell a Linux client something entirely different.
    @Test("host errno values go out with Linux numbering")
    func errnoTranslation() {
        #expect(LinuxErrno.wireValue(forHost: ENOENT) == 2)
        #expect(LinuxErrno.wireValue(forHost: ENOTEMPTY) == LinuxErrno.enotempty)
        #expect(LinuxErrno.enotempty == 39)
        #expect(LinuxErrno.wireValue(forHost: EAGAIN) == 11)
        #expect(LinuxErrno.wireValue(forHost: ENOSYS) == 38)
        #expect(NinePServerError.fromHostErrno(ENOTEMPTY).errno == 39)
        #expect(NinePServerError.fromHostErrno(ENOENT).message.isEmpty == false)
    }
}
