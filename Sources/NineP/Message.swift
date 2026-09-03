import Foundation

/// A 9P message tag. `notag` is reserved for Tversion.
public typealias Tag = UInt16
/// A 9P file identifier. `nofid` means "no fid supplied".
public typealias Fid = UInt32

public enum P9 {
    /// The tag Tversion must use.
    public static let notag: Tag = 0xFFFF
    /// The fid value meaning "none", used by Tattach when there is no auth fid.
    public static let nofid: Fid = 0xFFFF_FFFF
    /// Bytes of framing overhead before a message body: size[4] type[1] tag[2].
    public static let headerSize = 7
    /// A conservative default msize; large enough for fast bulk I/O, small
    /// enough that every server we know of accepts it.
    public static let defaultMsize: UInt32 = 512 * 1024
    /// The most path elements a single Twalk may carry.
    public static let maxWalkElements = 16
    /// The IANA-registered port for 9P (`9pfs`).
    public static let defaultPort = 564
}

/// Numeric message type codes. Base 9P2000 uses 100..127; 9P2000.L adds the
/// low-numbered codes 6..77.
public enum MessageType: UInt8, Sendable, CaseIterable {
    // 9P2000.L
    case rlerror     = 7
    case tstatfs     = 8
    case rstatfs     = 9
    case tlopen      = 12
    case rlopen      = 13
    case tlcreate    = 14
    case rlcreate    = 15
    case tsymlink    = 16
    case rsymlink    = 17
    case tmknod      = 18
    case rmknod      = 19
    case trename     = 20
    case rrename     = 21
    case treadlink   = 22
    case rreadlink   = 23
    case tgetattr    = 24
    case rgetattr    = 25
    case tsetattr    = 26
    case rsetattr    = 27
    case txattrwalk  = 30
    case rxattrwalk  = 31
    case txattrcreate = 32
    case rxattrcreate = 33
    case treaddir    = 40
    case rreaddir    = 41
    case tfsync      = 50
    case rfsync      = 51
    case tlock       = 52
    case rlock       = 53
    case tgetlock    = 54
    case rgetlock    = 55
    case tlink       = 70
    case rlink       = 71
    case tmkdir      = 72
    case rmkdir      = 73
    case trenameat   = 74
    case rrenameat   = 75
    case tunlinkat   = 76
    case runlinkat   = 77

    // 9P2000 / shared
    case tversion    = 100
    case rversion    = 101
    case tauth       = 102
    case rauth       = 103
    case tattach     = 104
    case rattach     = 105
    case rerror      = 107
    case tflush      = 108
    case rflush      = 109
    case twalk       = 110
    case rwalk       = 111
    case topen       = 112
    case ropen       = 113
    case tcreate     = 114
    case rcreate     = 115
    case tread       = 116
    case rread       = 117
    case twrite      = 118
    case rwrite      = 119
    case tclunk      = 120
    case rclunk      = 121
    case tremove     = 122
    case rremove     = 123
    case tstat       = 124
    case rstat       = 125
    case twstat      = 126
    case rwstat      = 127

    /// True for client-to-server messages.
    public var isRequest: Bool {
        // Every T-message code is even in the .L range and even-or-100+even in
        // the base range; both hold because T/R pairs are (n, n+1) with n even.
        rawValue % 2 == 0
    }
}

/// A decoded 9P message body. The tag lives in ``Frame``.
public enum Message: Sendable, Hashable {
    // MARK: 9P2000 core
    case tversion(msize: UInt32, version: String)
    case rversion(msize: UInt32, version: String)
    case tauth(afid: Fid, uname: String, aname: String, numericUID: UInt32?)
    case rauth(aqid: Qid)
    case tattach(fid: Fid, afid: Fid, uname: String, aname: String, numericUID: UInt32?)
    case rattach(qid: Qid)
    /// Base 9P2000/.u error. `errno` is present only in 9P2000.u.
    case rerror(message: String, errno: UInt32?)
    /// 9P2000.L error: a bare Linux errno.
    case rlerror(errno: UInt32)
    case tflush(oldtag: Tag)
    case rflush
    case twalk(fid: Fid, newfid: Fid, names: [String])
    case rwalk(qids: [Qid])
    case topen(fid: Fid, mode: OpenMode)
    case ropen(qid: Qid, iounit: UInt32)
    case tcreate(fid: Fid, name: String, perm: FileMode, mode: OpenMode, extensionString: String?)
    case rcreate(qid: Qid, iounit: UInt32)
    case tread(fid: Fid, offset: UInt64, count: UInt32)
    case rread(data: [UInt8])
    case twrite(fid: Fid, offset: UInt64, data: [UInt8])
    case rwrite(count: UInt32)
    case tclunk(fid: Fid)
    case rclunk
    case tremove(fid: Fid)
    case rremove
    case tstat(fid: Fid)
    case rstat(stat: Stat)
    case twstat(fid: Fid, stat: Stat)
    case rwstat

    // MARK: 9P2000.L
    case tstatfs(fid: Fid)
    case rstatfs(StatFS)
    case tlopen(fid: Fid, flags: LinuxOpenFlags)
    case rlopen(qid: Qid, iounit: UInt32)
    case tlcreate(fid: Fid, name: String, flags: LinuxOpenFlags, mode: UInt32, gid: UInt32)
    case rlcreate(qid: Qid, iounit: UInt32)
    case tsymlink(dfid: Fid, name: String, target: String, gid: UInt32)
    case rsymlink(qid: Qid)
    case tmknod(dfid: Fid, name: String, mode: UInt32, major: UInt32, minor: UInt32, gid: UInt32)
    case rmknod(qid: Qid)
    case trename(fid: Fid, dfid: Fid, name: String)
    case rrename
    case treadlink(fid: Fid)
    case rreadlink(target: String)
    case tgetattr(fid: Fid, requestMask: GetattrMask)
    case rgetattr(LinuxAttr)
    case tsetattr(fid: Fid, valid: SetattrMask, mode: UInt32, uid: UInt32, gid: UInt32,
                  size: UInt64, atimeSec: UInt64, atimeNsec: UInt64,
                  mtimeSec: UInt64, mtimeNsec: UInt64)
    case rsetattr
    case txattrwalk(fid: Fid, newfid: Fid, name: String)
    case rxattrwalk(size: UInt64)
    case txattrcreate(fid: Fid, name: String, attrSize: UInt64, flags: UInt32)
    case rxattrcreate
    case treaddir(fid: Fid, offset: UInt64, count: UInt32)
    case rreaddir(entries: [Dirent])
    case tfsync(fid: Fid, dataSync: UInt32)
    case rfsync
    case tlock(fid: Fid, type: UInt8, flags: UInt32, start: UInt64, length: UInt64,
               procID: UInt32, clientID: String)
    case rlock(status: UInt8)
    case tgetlock(fid: Fid, type: UInt8, start: UInt64, length: UInt64,
                  procID: UInt32, clientID: String)
    case rgetlock(type: UInt8, start: UInt64, length: UInt64, procID: UInt32, clientID: String)
    case tlink(dfid: Fid, fid: Fid, name: String)
    case rlink
    case tmkdir(dfid: Fid, name: String, mode: UInt32, gid: UInt32)
    case rmkdir(qid: Qid)
    case trenameat(olddirfid: Fid, oldname: String, newdirfid: Fid, newname: String)
    case rrenameat
    case tunlinkat(dirfid: Fid, name: String, flags: UInt32)
    case runlinkat

    /// The wire type code for this message.
    public var type: MessageType {
        switch self {
        case .tversion: .tversion
        case .rversion: .rversion
        case .tauth: .tauth
        case .rauth: .rauth
        case .tattach: .tattach
        case .rattach: .rattach
        case .rerror: .rerror
        case .rlerror: .rlerror
        case .tflush: .tflush
        case .rflush: .rflush
        case .twalk: .twalk
        case .rwalk: .rwalk
        case .topen: .topen
        case .ropen: .ropen
        case .tcreate: .tcreate
        case .rcreate: .rcreate
        case .tread: .tread
        case .rread: .rread
        case .twrite: .twrite
        case .rwrite: .rwrite
        case .tclunk: .tclunk
        case .rclunk: .rclunk
        case .tremove: .tremove
        case .rremove: .rremove
        case .tstat: .tstat
        case .rstat: .rstat
        case .twstat: .twstat
        case .rwstat: .rwstat
        case .tstatfs: .tstatfs
        case .rstatfs: .rstatfs
        case .tlopen: .tlopen
        case .rlopen: .rlopen
        case .tlcreate: .tlcreate
        case .rlcreate: .rlcreate
        case .tsymlink: .tsymlink
        case .rsymlink: .rsymlink
        case .tmknod: .tmknod
        case .rmknod: .rmknod
        case .trename: .trename
        case .rrename: .rrename
        case .treadlink: .treadlink
        case .rreadlink: .rreadlink
        case .tgetattr: .tgetattr
        case .rgetattr: .rgetattr
        case .tsetattr: .tsetattr
        case .rsetattr: .rsetattr
        case .txattrwalk: .txattrwalk
        case .rxattrwalk: .rxattrwalk
        case .txattrcreate: .txattrcreate
        case .rxattrcreate: .rxattrcreate
        case .treaddir: .treaddir
        case .rreaddir: .rreaddir
        case .tfsync: .tfsync
        case .rfsync: .rfsync
        case .tlock: .tlock
        case .rlock: .rlock
        case .tgetlock: .tgetlock
        case .rgetlock: .rgetlock
        case .tlink: .tlink
        case .rlink: .rlink
        case .tmkdir: .tmkdir
        case .rmkdir: .rmkdir
        case .trenameat: .trenameat
        case .rrenameat: .rrenameat
        case .tunlinkat: .tunlinkat
        case .runlinkat: .runlinkat
        }
    }
}

/// A complete 9P message: a tag plus a body.
public struct Frame: Sendable, Hashable {
    public var tag: Tag
    public var message: Message

    public init(tag: Tag, message: Message) {
        self.tag = tag
        self.message = message
    }
}
