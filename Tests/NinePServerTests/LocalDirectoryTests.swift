import Testing
import Foundation
import NineP
@testable import NinePServer

@Suite("LocalDirectoryFileSystem")
struct LocalDirectoryFileSystemTests {
    private func populate(_ root: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/docs", withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: URL(fileURLWithPath: root + "/docs/a.txt"))
        try Data("hello, 9P".utf8).write(to: URL(fileURLWithPath: root + "/hello.txt"))
        try fm.createSymbolicLink(atPath: root + "/inside", withDestinationPath: "hello.txt")
        try fm.createSymbolicLink(atPath: root + "/escape", withDestinationPath: "/etc")
    }

    @Test("a real directory can be listed and read")
    func readThrough() throws {
        try withTemporaryDirectory { root in
            try populate(root)
            let fs = try LocalDirectoryFileSystem(root: root)
            let s = try makeSession(fs)
            _ = s.send(.twalk(fid: 0, newfid: 1, names: ["hello.txt"]))
            _ = s.send(.tlopen(fid: 1, flags: .rdonly))
            #expect(s.send(.tread(fid: 1, offset: 0, count: 64)) == .rread(data: Array("hello, 9P".utf8)))

            _ = s.send(.twalk(fid: 0, newfid: 2, names: []))
            _ = s.send(.tlopen(fid: 2, flags: .rdonly))
            guard case let .rreaddir(entries) = s.send(.treaddir(fid: 2, offset: 0, count: 4096)) else {
                Issue.record("expected Rreaddir"); return
            }
            #expect(entries.map(\.name) == [".", "..", "docs", "escape", "hello.txt", "inside"])
        }
    }

    @Test("files can be created, written, renamed and removed")
    func mutations() throws {
        try withTemporaryDirectory { root in
            try populate(root)
            let fs = try LocalDirectoryFileSystem(root: root)
            let s = try makeSession(fs)
            _ = s.send(.twalk(fid: 0, newfid: 1, names: []))
            guard case .rlcreate = s.send(.tlcreate(fid: 1, name: "new.txt", flags: .rdwr,
                                                    mode: 0o644, gid: 0)) else {
                Issue.record("expected Rlcreate"); return
            }
            #expect(s.send(.twrite(fid: 1, offset: 0, data: Array("data".utf8))) == .rwrite(count: 4))
            #expect(s.send(.tfsync(fid: 1, dataSync: 0)) == .rfsync)
            #expect(s.send(.tclunk(fid: 1)) == .rclunk)
            #expect(try String(contentsOfFile: root + "/new.txt", encoding: .utf8) == "data")

            #expect(s.send(.trenameat(olddirfid: 0, oldname: "new.txt",
                                      newdirfid: 0, newname: "moved.txt")) == .rrenameat)
            #expect(FileManager.default.fileExists(atPath: root + "/moved.txt"))
            #expect(s.send(.tunlinkat(dirfid: 0, name: "moved.txt", flags: 0)) == .runlinkat)
            #expect(!FileManager.default.fileExists(atPath: root + "/moved.txt"))
        }
    }

    @Test("statfs reports the host filesystem")
    func statfs() throws {
        try withTemporaryDirectory { root in
            let fs = try LocalDirectoryFileSystem(root: root)
            let info = try fs.statfs(FilePath())
            #expect(info.bsize > 0)
            #expect(info.namelen >= 255)
        }
    }

    @Test("a symlink inside the root is reported, not followed, by walk")
    func symlinkInside() throws {
        try withTemporaryDirectory { root in
            try populate(root)
            let fs = try LocalDirectoryFileSystem(root: root)
            let s = try makeSession(fs)
            guard case let .rwalk(qids) = s.send(.twalk(fid: 0, newfid: 1, names: ["inside"])) else {
                Issue.record("expected Rwalk"); return
            }
            #expect(qids[0].isSymlink)
            #expect(s.send(.treadlink(fid: 1)) == .rreadlink(target: "hello.txt"))
            // Opening it does follow the link, which stays inside the root.
            _ = s.send(.tlopen(fid: 1, flags: .rdonly))
            #expect(s.send(.tread(fid: 1, offset: 0, count: 64)) == .rread(data: Array("hello, 9P".utf8)))
        }
    }

    @Test("dot-dot cannot walk out of the exported root")
    func dotDotCannotEscape() throws {
        try withTemporaryDirectory { root in
            try populate(root)
            let fs = try LocalDirectoryFileSystem(root: root)
            let s = try makeSession(fs)
            // Three ".."s from the root still land on the root, so "hello.txt"
            // resolves and "etc" does not.
            guard case let .rwalk(qids) = s.send(
                .twalk(fid: 0, newfid: 1, names: ["..", "..", "..", "hello.txt"])) else {
                Issue.record("expected Rwalk"); return
            }
            #expect(qids.count == 4)
            guard case let .rwalk(escaped) = s.send(
                .twalk(fid: 0, newfid: 2, names: ["..", "..", "etc"])) else {
                Issue.record("expected Rwalk"); return
            }
            #expect(escaped.count == 2)
        }
    }

    @Test("a path element of \"..\" is rejected by the provider itself")
    func providerRejectsDotDot() throws {
        try withTemporaryDirectory { root in
            try populate(root)
            let fs = try LocalDirectoryFileSystem(root: root)
            #expect(throws: NinePServerError.self) {
                _ = try fs.entry(at: FilePath([".."]))
            }
            #expect(throws: NinePServerError.self) {
                _ = try fs.entry(at: FilePath(["docs", "..", "..", "etc"]))
            }
        }
    }

    @Test("an absolute symlink out of the root cannot be traversed or opened")
    func symlinkCannotEscape() throws {
        try withTemporaryDirectory { root in
            try populate(root)
            let fs = try LocalDirectoryFileSystem(root: root)
            let s = try makeSession(fs)

            // The link itself is visible — 9P hands symlinks to the client —
            // but nothing on the far side of it is reachable.
            guard case let .rwalk(qids) = s.send(.twalk(fid: 0, newfid: 1, names: ["escape"])) else {
                Issue.record("expected Rwalk"); return
            }
            #expect(qids[0].isSymlink)
            #expect(replyErrno(s.send(.tlopen(fid: 1, flags: .rdonly))) == LinuxErrno.eacces)

            // Walking through it stops at the link rather than entering /etc.
            guard case let .rwalk(through) = s.send(.twalk(fid: 0, newfid: 2, names: ["escape", "passwd"])) else {
                Issue.record("expected Rwalk"); return
            }
            #expect(through.count == 1)

            // And the provider refuses the composed path outright.
            let error = #expect(throws: NinePServerError.self) {
                _ = try fs.entry(at: FilePath(["escape", "passwd"]))
            }
            #expect(error?.errno == LinuxErrno.eacces)
        }
    }

    @Test("followExternalSymlinks opts back in to escaping links")
    func followExternalSymlinks() throws {
        try withTemporaryDirectory { root in
            try populate(root)
            let permissive = try LocalDirectoryFileSystem(
                root: root, options: .init(followExternalSymlinks: true))
            #expect(throws: Never.self) {
                _ = try permissive.entry(at: FilePath(["escape", "hosts"]))
            }
        }
    }

    @Test("a read-only export refuses mutations")
    func readOnly() throws {
        try withTemporaryDirectory { root in
            try populate(root)
            let fs = try LocalDirectoryFileSystem(root: root, options: .init(readOnly: true))
            let s = try makeSession(fs)
            #expect(replyErrno(s.send(.tmkdir(dfid: 0, name: "x", mode: 0o755, gid: 0))) == LinuxErrno.erofs)
        }
    }

    @Test("a missing export root is refused at construction")
    func missingRoot() {
        #expect(throws: NinePServerError.self) {
            _ = try LocalDirectoryFileSystem(root: "/definitely/not/here/at/all")
        }
    }

    @Test("errors from the host are mapped to Linux errno values")
    func hostErrors() throws {
        try withTemporaryDirectory { root in
            try populate(root)
            let fs = try LocalDirectoryFileSystem(root: root)
            let s = try makeSession(fs)
            #expect(replyErrno(s.send(.twalk(fid: 0, newfid: 1, names: ["nope"]))) == LinuxErrno.enoent)
            #expect(replyErrno(s.send(.tunlinkat(dirfid: 0, name: "docs",
                                                 flags: UnlinkAtFlags.removeDir))) == LinuxErrno.enotempty)
            _ = s.send(.twalk(fid: 0, newfid: 2, names: []))
            #expect(replyErrno(s.send(.tlcreate(fid: 2, name: "hello.txt",
                                                flags: [.rdwr, .create, .excl],
                                                mode: 0o644, gid: 0))) == LinuxErrno.eexist)
        }
    }
}
