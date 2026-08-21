import Testing
import Foundation
import NineP
@testable import NinePServer

@Suite("9P2000.L mutations")
struct LinuxMutationTests {
    @Test("Tlcreate makes a file and leaves the fid open on it")
    func lcreate() throws {
        let fs = try sampleTree()
        let s = try makeSession(fs)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["docs"]))
        guard case .rlcreate = s.send(.tlcreate(fid: 1, name: "new.txt", flags: .rdwr, mode: 0o644, gid: 0)) else {
            Issue.record("expected Rlcreate"); return
        }
        #expect(s.send(.twrite(fid: 1, offset: 0, data: Array("fresh".utf8))) == .rwrite(count: 5))
        #expect(try fs.text(at: "/docs/new.txt") == "fresh")
    }

    @Test("Tmkdir makes a directory")
    func mkdir() throws {
        let fs = try sampleTree()
        let s = try makeSession(fs)
        guard case let .rmkdir(qid) = s.send(.tmkdir(dfid: 0, name: "sub", mode: 0o750, gid: 3)) else {
            Issue.record("expected Rmkdir"); return
        }
        #expect(qid.isDir)
        #expect(try fs.names(in: "/").contains("sub"))
    }

    @Test("Tunlinkat removes files and, with AT_REMOVEDIR, directories")
    func unlinkat() throws {
        let fs = try sampleTree()
        let s = try makeSession(fs)
        #expect(s.send(.tunlinkat(dirfid: 0, name: "hello.txt", flags: 0)) == .runlinkat)
        #expect(!fs.exists("/hello.txt"))
        #expect(s.send(.tunlinkat(dirfid: 0, name: "empty", flags: UnlinkAtFlags.removeDir)) == .runlinkat)
        #expect(!fs.exists("/empty"))
    }

    @Test("Tunlinkat refuses a directory without AT_REMOVEDIR")
    func unlinkatWrongType() throws {
        let s = try makeSession(try sampleTree())
        #expect(replyErrno(s.send(.tunlinkat(dirfid: 0, name: "empty", flags: 0))) == LinuxErrno.eisdir)
    }

    @Test("Trename moves a file and follows it with the fid")
    func rename() throws {
        let fs = try sampleTree()
        let s = try makeSession(fs)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["hello.txt"]))
        _ = s.send(.twalk(fid: 0, newfid: 2, names: ["docs"]))
        #expect(s.send(.trename(fid: 1, dfid: 2, name: "moved.txt")) == .rrename)
        #expect(try fs.text(at: "/docs/moved.txt") == "hello, 9P")
        #expect(!fs.exists("/hello.txt"))
        guard case let .rstat(stat) = s.send(.tstat(fid: 1)) else { Issue.record("expected Rstat"); return }
        #expect(stat.name == "moved.txt")
    }

    @Test("Trenameat moves by name between two directory fids")
    func renameat() throws {
        let fs = try sampleTree()
        let s = try makeSession(fs)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["docs"]))
        #expect(s.send(.trenameat(olddirfid: 1, oldname: "a.txt",
                                  newdirfid: 0, newname: "top.txt")) == .rrenameat)
        #expect(try fs.text(at: "/top.txt") == "alpha")
        #expect(try fs.names(in: "/docs") == ["b.txt"])
    }

    @Test("Tsymlink and Treadlink round-trip a target")
    func symlink() throws {
        let s = try makeSession(try sampleTree())
        guard case let .rsymlink(qid) = s.send(.tsymlink(dfid: 0, name: "ln", target: "docs/a.txt", gid: 0)) else {
            Issue.record("expected Rsymlink"); return
        }
        #expect(qid.isSymlink)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["ln"]))
        #expect(s.send(.treadlink(fid: 1)) == .rreadlink(target: "docs/a.txt"))
    }

    @Test("Treadlink on a plain file fails")
    func readlinkNotALink() throws {
        let s = try makeSession(try sampleTree())
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["hello.txt"]))
        #expect(replyErrno(s.send(.treadlink(fid: 1))) == LinuxErrno.einval)
    }

    @Test("Tlink creates a second name for a file")
    func hardLink() throws {
        let fs = try sampleTree()
        let s = try makeSession(fs)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["hello.txt"]))
        _ = s.send(.twalk(fid: 0, newfid: 2, names: ["docs"]))
        #expect(s.send(.tlink(dfid: 2, fid: 1, name: "same.txt")) == .rlink)
        #expect(try fs.text(at: "/docs/same.txt") == "hello, 9P")
    }

    @Test("Tsetattr truncates, chmods and sets times")
    func setattr() throws {
        let fs = try sampleTree()
        let s = try makeSession(fs)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["hello.txt"]))

        #expect(s.send(.tsetattr(fid: 1, valid: .size, mode: 0, uid: 0, gid: 0, size: 5,
                                 atimeSec: 0, atimeNsec: 0, mtimeSec: 0, mtimeNsec: 0)) == .rsetattr)
        #expect(try fs.text(at: "/hello.txt") == "hello")

        #expect(s.send(.tsetattr(fid: 1, valid: .mode, mode: 0o600, uid: 0, gid: 0, size: 0,
                                 atimeSec: 0, atimeNsec: 0, mtimeSec: 0, mtimeNsec: 0)) == .rsetattr)

        let valid = SetattrMask([.mtime, .mtimeSet, .atime, .atimeSet])
        #expect(s.send(.tsetattr(fid: 1, valid: valid, mode: 0, uid: 0, gid: 0, size: 0,
                                 atimeSec: 111, atimeNsec: 222,
                                 mtimeSec: 333, mtimeNsec: 444)) == .rsetattr)

        guard case let .rgetattr(attr) = s.send(.tgetattr(fid: 1, requestMask: .all)) else {
            Issue.record("expected Rgetattr"); return
        }
        #expect(attr.mode & 0o777 == 0o600)
        #expect(attr.mode & PosixFileType.mask == PosixFileType.reg)
        #expect(attr.size == 5)
        #expect(attr.atimeSec == 111 && attr.atimeNsec == 222)
        #expect(attr.mtimeSec == 333 && attr.mtimeNsec == 444)
        #expect(attr.valid == GetattrMask.all.intersection(.basic))
    }

    @Test("Tgetattr reports directories and symlinks with the right type bits")
    func getattrTypes() throws {
        let s = try makeSession(try sampleTree())
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["docs"]))
        _ = s.send(.twalk(fid: 0, newfid: 2, names: ["link"]))
        guard case let .rgetattr(dir) = s.send(.tgetattr(fid: 1, requestMask: .basic)),
              case let .rgetattr(link) = s.send(.tgetattr(fid: 2, requestMask: .basic)) else {
            Issue.record("expected Rgetattr"); return
        }
        #expect(dir.mode & PosixFileType.mask == PosixFileType.dir)
        #expect(dir.qid.isDir)
        #expect(link.mode & PosixFileType.mask == PosixFileType.lnk)
        #expect(link.qid.isSymlink)
    }

    @Test("Tstatfs answers with plausible numbers")
    func statfs() throws {
        let s = try makeSession(try sampleTree())
        guard case let .rstatfs(info) = s.send(.tstatfs(fid: 0)) else {
            Issue.record("expected Rstatfs"); return
        }
        #expect(info.namelen == 255)
        #expect(info.bsize == 4096)
        #expect(info.blocks > 0)
        #expect(info.files >= 6)
    }

    @Test("Tfsync, Tlock, Tgetlock and Txattrwalk answer benignly")
    func softOperations() throws {
        let s = try makeSession(try sampleTree())
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["hello.txt"]))
        #expect(s.send(.tfsync(fid: 1, dataSync: 0)) == .rfsync)
        #expect(s.send(.tlock(fid: 1, type: LockType.write, flags: 0, start: 0, length: 0,
                              procID: 7, clientID: "c")) == .rlock(status: LockStatus.success))
        #expect(s.send(.tgetlock(fid: 1, type: LockType.write, start: 0, length: 0,
                                 procID: 7, clientID: "c"))
                == .rgetlock(type: LockType.unlock, start: 0, length: 0, procID: 7, clientID: "c"))
        #expect(s.send(.txattrwalk(fid: 1, newfid: 9, name: "user.x")) == .rxattrwalk(size: 0))
        // The xattr fid exists only so the client's clunk succeeds.
        #expect(replyErrno(s.send(.tgetattr(fid: 9, requestMask: .basic))) == LinuxErrno.eopnotsupp)
        #expect(s.send(.tclunk(fid: 9)) == .rclunk)
    }

    @Test("9P2000.L messages are refused on a base 9P2000 connection")
    func linuxOnlyMessages() throws {
        let s = try makeSession(try sampleTree(), version: .v9P2000)
        #expect(replyErrno(s.send(.tgetattr(fid: 0, requestMask: .basic))) == LinuxErrno.eopnotsupp)
        #expect(replyErrno(s.send(.tstatfs(fid: 0))) == LinuxErrno.eopnotsupp)
    }

    @Test("Tmknod is not supported")
    func mknod() throws {
        let s = try makeSession(try sampleTree())
        let reply = s.send(.tmknod(dfid: 0, name: "dev", mode: 0o20666, major: 1, minor: 3, gid: 0))
        #expect(replyErrno(reply) == LinuxErrno.eopnotsupp)
    }
}

@Suite("Base 9P2000 mutations")
struct LegacyMutationTests {
    @Test("Tcreate makes and opens a regular file")
    func create() throws {
        let fs = try sampleTree()
        let s = try makeSession(fs, version: .v9P2000)
        guard case let .rcreate(qid, _) = s.send(
            .tcreate(fid: 0, name: "made.txt", perm: FileMode(rawValue: 0o644),
                     mode: .write, extensionString: nil)) else {
            Issue.record("expected Rcreate"); return
        }
        #expect(!qid.isDir)
        #expect(s.send(.twrite(fid: 0, offset: 0, data: Array("body".utf8))) == .rwrite(count: 4))
        #expect(try fs.text(at: "/made.txt") == "body")
    }

    @Test("Tcreate with DMDIR makes a directory")
    func createDirectory() throws {
        let fs = try sampleTree()
        let s = try makeSession(fs, version: .v9P2000)
        guard case let .rcreate(qid, _) = s.send(
            .tcreate(fid: 0, name: "made", perm: FileMode(rawValue: 0o755).union(.dir),
                     mode: .read, extensionString: nil)) else {
            Issue.record("expected Rcreate"); return
        }
        #expect(qid.isDir)
        #expect(try fs.names(in: "/").contains("made"))
    }

    @Test("9P2000.u Tcreate with DMSYMLINK makes a symlink")
    func createSymlink() throws {
        let fs = try sampleTree()
        let s = try makeSession(fs, version: .v9P2000u)
        guard case let .rcreate(qid, _) = s.send(
            .tcreate(fid: 0, name: "ln", perm: FileMode(rawValue: 0o777).union(.symlink),
                     mode: .read, extensionString: "docs/a.txt")) else {
            Issue.record("expected Rcreate"); return
        }
        #expect(qid.isSymlink)
    }

    @Test("Tstat describes a file, and 9P2000.u carries the symlink target")
    func stat() throws {
        let s = try makeSession(try sampleTree(), version: .v9P2000u)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["hello.txt"]))
        guard case let .rstat(file) = s.send(.tstat(fid: 1)) else { Issue.record("expected Rstat"); return }
        #expect(file.name == "hello.txt")
        #expect(file.length == 9)
        #expect(file.mode.permissions == 0o644)
        #expect(!file.mode.isDir)

        _ = s.send(.twalk(fid: 0, newfid: 2, names: ["link"]))
        guard case let .rstat(link) = s.send(.tstat(fid: 2)) else { Issue.record("expected Rstat"); return }
        #expect(link.mode.isSymlink)
        #expect(link.extensionString == "hello.txt")
    }

    @Test("Twstat renames, truncates and chmods")
    func wstat() throws {
        let fs = try sampleTree()
        let s = try makeSession(fs, version: .v9P2000)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["hello.txt"]))

        var request = Stat.noTouch()
        request.length = 5
        request.mode = FileMode(rawValue: 0o600)
        request.name = "renamed.txt"
        #expect(s.send(.twstat(fid: 1, stat: request)) == .rwstat)
        #expect(try fs.text(at: "/renamed.txt") == "hello")
        #expect(!fs.exists("/hello.txt"))

        guard case let .rstat(after) = s.send(.tstat(fid: 1)) else { Issue.record("expected Rstat"); return }
        #expect(after.name == "renamed.txt")
        #expect(after.mode.permissions == 0o600)
    }

    @Test("a Twstat with nothing set asks for a flush and succeeds")
    func wstatSync() throws {
        let s = try makeSession(try sampleTree(), version: .v9P2000)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["hello.txt"]))
        #expect(s.send(.twstat(fid: 1, stat: Stat.noTouch())) == .rwstat)
    }

    @Test("Tremove deletes the file and releases the fid")
    func remove() throws {
        let fs = try sampleTree()
        let s = try makeSession(fs, version: .v9P2000)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["hello.txt"]))
        #expect(s.send(.tremove(fid: 1)) == .rremove)
        #expect(!fs.exists("/hello.txt"))
        #expect(replyErrno(s.send(.tstat(fid: 1))) == LinuxErrno.ebadf)
    }

    @Test("Tflush is always answered")
    func flush() throws {
        let s = try makeSession(try sampleTree(), version: .v9P2000)
        #expect(s.send(.tflush(oldtag: 42)) == .rflush)
    }

    @Test("Tauth is refused because no authentication is required")
    func auth() throws {
        let s = try makeSession(try sampleTree(), version: .v9P2000)
        let reply = s.send(.tauth(afid: 3, uname: "u", aname: "", numericUID: nil))
        #expect(isError(reply))
        #expect(replyErrorText(reply)?.isEmpty == false)
    }
}
