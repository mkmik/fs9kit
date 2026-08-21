import Testing
import Foundation
import NineP
@testable import NinePServer

@Suite("Open, read, write, clunk")
struct FileIOTests {
    @Test("a file can be opened and read")
    func readFile() throws {
        let s = try makeSession(try sampleTree())
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["hello.txt"]))
        guard case let .rlopen(qid, iounit) = s.send(.tlopen(fid: 1, flags: .rdonly)) else {
            Issue.record("expected Rlopen"); return
        }
        #expect(!qid.isDir)
        #expect(iounit > 0)
        #expect(s.send(.tread(fid: 1, offset: 0, count: 64)) == .rread(data: Array("hello, 9P".utf8)))
        // Reading past the end is EOF, not an error.
        #expect(s.send(.tread(fid: 1, offset: 99, count: 64)) == .rread(data: []))
        #expect(s.send(.tclunk(fid: 1)) == .rclunk)
        #expect(replyErrno(s.send(.tread(fid: 1, offset: 0, count: 1))) == LinuxErrno.ebadf)
    }

    @Test("a read is clamped to the negotiated msize")
    func readClamped() throws {
        let fs = MemoryFileSystem()
        try fs.addFile("/big", contents: [UInt8](repeating: 0x41, count: 4096))
        let s = try makeSession(fs, msize: 1024)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["big"]))
        _ = s.send(.tlopen(fid: 1, flags: .rdonly))
        guard case let .rread(data) = s.send(.tread(fid: 1, offset: 0, count: 4096)) else {
            Issue.record("expected Rread"); return
        }
        #expect(data.count == 1024 - P9.headerSize - 4)
    }

    @Test("writes land in the backing file")
    func writeFile() throws {
        let fs = try sampleTree()
        let s = try makeSession(fs)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["hello.txt"]))
        _ = s.send(.tlopen(fid: 1, flags: .rdwr))
        #expect(s.send(.twrite(fid: 1, offset: 7, data: Array("XY".utf8))) == .rwrite(count: 2))
        #expect(try fs.text(at: "/hello.txt") == "hello, XY")
        #expect(s.send(.tread(fid: 1, offset: 0, count: 64)) == .rread(data: Array("hello, XY".utf8)))
    }

    @Test("writing past the end zero-fills the gap")
    func sparseWrite() throws {
        let fs = MemoryFileSystem()
        try fs.addFile("/f", text: "ab")
        let s = try makeSession(fs)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["f"]))
        _ = s.send(.tlopen(fid: 1, flags: .rdwr))
        #expect(s.send(.twrite(fid: 1, offset: 4, data: [0x5A])) == .rwrite(count: 1))
        #expect(try fs.contents(of: "/f") == [0x61, 0x62, 0, 0, 0x5A])
    }

    @Test("reading or writing an unopened fid fails")
    func unopenedFid() throws {
        let s = try makeSession(try sampleTree())
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["hello.txt"]))
        #expect(replyErrno(s.send(.tread(fid: 1, offset: 0, count: 8))) == LinuxErrno.ebadf)
        #expect(replyErrno(s.send(.twrite(fid: 1, offset: 0, data: [1]))) == LinuxErrno.ebadf)
    }

    @Test("a directory cannot be written to")
    func writeDirectory() throws {
        let s = try makeSession(try sampleTree())
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["docs"]))
        _ = s.send(.tlopen(fid: 1, flags: .rdonly))
        #expect(replyErrno(s.send(.twrite(fid: 1, offset: 0, data: [1]))) == LinuxErrno.eisdir)
    }

    @Test("clunking an unknown fid fails")
    func clunkUnknown() throws {
        let s = try makeSession(try sampleTree())
        #expect(replyErrno(s.send(.tclunk(fid: 99))) == LinuxErrno.ebadf)
    }

    @Test("base 9P2000 Topen honours OTRUNC")
    func openTruncate() throws {
        let fs = try sampleTree()
        let s = try makeSession(fs, version: .v9P2000)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["hello.txt"]))
        guard case .ropen = s.send(.topen(fid: 1, mode: OpenMode([.write, .trunc]))) else {
            Issue.record("expected Ropen"); return
        }
        #expect(try fs.contents(of: "/hello.txt").isEmpty)
    }
}

@Suite("Directory listing")
struct DirectoryTests {
    @Test("base 9P2000 reads a directory as concatenated stat structures")
    func statListing() throws {
        let s = try makeSession(try sampleTree(), version: .v9P2000)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["docs"]))
        _ = s.send(.topen(fid: 1, mode: .read))
        guard case let .rread(data) = s.send(.tread(fid: 1, offset: 0, count: 4096)) else {
            Issue.record("expected Rread"); return
        }
        let stats = try decodeStats(data)
        #expect(stats.map(\.name) == ["a.txt", "b.txt"])
        #expect(stats[0].length == 5)
        // A second read at the end of the stream is EOF.
        #expect(s.send(.tread(fid: 1, offset: UInt64(data.count), count: 4096)) == .rread(data: []))
    }

    @Test("a directory read never splits a stat across replies")
    func statListingChunked() throws {
        let s = try makeSession(try wideTree(count: 12), version: .v9P2000)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["many"]))
        _ = s.send(.topen(fid: 1, mode: .read))

        var names: [String] = []
        var offset: UInt64 = 0
        var rounds = 0
        while rounds < 50 {
            rounds += 1
            guard case let .rread(data) = s.send(.tread(fid: 1, offset: offset, count: 96)) else {
                Issue.record("expected Rread"); return
            }
            if data.isEmpty { break }
            let stats = try decodeStats(data)
            #expect(!stats.isEmpty)
            names.append(contentsOf: stats.map(\.name))
            offset += UInt64(data.count)
        }
        #expect(rounds > 3, "a 96-byte count should need several round trips")
        #expect(names == (0..<12).map { String(format: "file%03d", $0) })
    }

    @Test("a directory read at a non-boundary offset is refused")
    func statListingBadOffset() throws {
        let s = try makeSession(try sampleTree(), version: .v9P2000)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["docs"]))
        _ = s.send(.topen(fid: 1, mode: .read))
        #expect(replyErrno(s.send(.tread(fid: 1, offset: 3, count: 4096))) == LinuxErrno.einval)
    }

    @Test("9P2000.L Treaddir lists dot, dot-dot and the children")
    func readdir() throws {
        let s = try makeSession(try sampleTree())
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["docs"]))
        _ = s.send(.tlopen(fid: 1, flags: [.rdonly, .directory]))
        guard case let .rreaddir(entries) = s.send(.treaddir(fid: 1, offset: 0, count: 4096)) else {
            Issue.record("expected Rreaddir"); return
        }
        #expect(entries.map(\.name) == [".", "..", "a.txt", "b.txt"])
        #expect(entries.map(\.offset) == [1, 2, 3, 4])
        #expect(entries[0].type == DirentType.dir)
        #expect(entries[2].type == DirentType.reg)
        #expect(s.send(.treaddir(fid: 1, offset: 4, count: 4096)) == .rreaddir(entries: []))
    }

    @Test("Treaddir resumes across several round trips")
    func readdirResumption() throws {
        let s = try makeSession(try wideTree(count: 40), msize: 512)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["many"]))
        _ = s.send(.tlopen(fid: 1, flags: [.rdonly, .directory]))

        var names: [String] = []
        var offset: UInt64 = 0
        var rounds = 0
        while rounds < 100 {
            rounds += 1
            guard case let .rreaddir(entries) = s.send(.treaddir(fid: 1, offset: offset, count: 128)) else {
                Issue.record("expected Rreaddir"); return
            }
            if entries.isEmpty { break }
            names.append(contentsOf: entries.map(\.name))
            offset = entries[entries.count - 1].offset
        }
        #expect(rounds > 5, "a 128-byte count should need several round trips")
        #expect(names == [".", ".."] + (0..<40).map { String(format: "file%03d", $0) })
    }

    @Test("Treaddir past the end is refused")
    func readdirBeyondEnd() throws {
        let s = try makeSession(try sampleTree())
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["empty"]))
        _ = s.send(.tlopen(fid: 1, flags: .rdonly))
        #expect(replyErrno(s.send(.treaddir(fid: 1, offset: 99, count: 512))) == LinuxErrno.einval)
    }

    @Test("Tread of a directory is EISDIR in 9P2000.L")
    func readdirWrongMessage() throws {
        let s = try makeSession(try sampleTree())
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["docs"]))
        _ = s.send(.tlopen(fid: 1, flags: .rdonly))
        #expect(replyErrno(s.send(.tread(fid: 1, offset: 0, count: 512))) == LinuxErrno.eisdir)
    }

    @Test("a listing is frozen at open time so offsets keep their meaning")
    func listingIsStable() throws {
        let fs = try sampleTree()
        let s = try makeSession(fs)
        _ = s.send(.twalk(fid: 0, newfid: 1, names: ["docs"]))
        _ = s.send(.tlopen(fid: 1, flags: .rdonly))
        try fs.addFile("/docs/c.txt", text: "gamma")
        guard case let .rreaddir(entries) = s.send(.treaddir(fid: 1, offset: 0, count: 4096)) else {
            Issue.record("expected Rreaddir"); return
        }
        #expect(entries.map(\.name) == [".", "..", "a.txt", "b.txt"])
    }
}
