import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Translation between Linux errno numbers and this host's.
///
/// 9P2000.L puts *Linux* errno values on the wire — `Rlerror` and the numeric
/// field of a 9P2000.u `Rerror` — regardless of what either end runs. On Linux
/// that is a no-op, but on Darwin the numbers diverge sharply above 34 and even
/// at 11, where Linux says EAGAIN and Darwin says EDEADLK. Passing the wire
/// value straight to a caller would turn "try again" into "deadlock detected"
/// and "function not implemented" (Linux 38) into "directory not empty"
/// (Darwin 66).
///
/// The table is written as (Linux number, host constant) pairs so it stays
/// correct by construction: the host side is whatever this platform's headers
/// say, and on Linux every pair is an identity.
public enum LinuxErrno {
    /// Linux errno numbers paired with the matching constant on this platform.
    private static let pairs: [(linux: Int32, host: Int32)] = [
        (1, EPERM), (2, ENOENT), (3, ESRCH), (4, EINTR), (5, EIO), (6, ENXIO),
        (7, E2BIG), (8, ENOEXEC), (9, EBADF), (10, ECHILD), (11, EAGAIN),
        (12, ENOMEM), (13, EACCES), (14, EFAULT), (15, ENOTBLK), (16, EBUSY),
        (17, EEXIST), (18, EXDEV), (19, ENODEV), (20, ENOTDIR), (21, EISDIR),
        (22, EINVAL), (23, ENFILE), (24, EMFILE), (25, ENOTTY), (26, ETXTBSY),
        (27, EFBIG), (28, ENOSPC), (29, ESPIPE), (30, EROFS), (31, EMLINK),
        (32, EPIPE), (33, EDOM), (34, ERANGE),
        // Everything past here differs between the two platforms.
        (35, EDEADLK), (36, ENAMETOOLONG), (37, ENOLCK), (38, ENOSYS),
        (39, ENOTEMPTY), (40, ELOOP), (42, ENOMSG), (43, EIDRM),
        // Linux merges ENODATA and ENOATTR; xattr callers want ENOATTR, which
        // is the sense in which 9P servers send it.
        (61, ENOATTR), (62, ETIME), (74, EBADMSG), (75, EOVERFLOW),
        (84, EILSEQ), (88, ENOTSOCK), (89, EDESTADDRREQ), (90, EMSGSIZE),
        (91, EPROTOTYPE), (92, ENOPROTOOPT), (93, EPROTONOSUPPORT),
        (94, ESOCKTNOSUPPORT), (95, ENOTSUP), (96, EPFNOSUPPORT),
        (97, EAFNOSUPPORT), (98, EADDRINUSE), (99, EADDRNOTAVAIL),
        (100, ENETDOWN), (101, ENETUNREACH), (102, ENETRESET),
        (103, ECONNABORTED), (104, ECONNRESET), (105, ENOBUFS), (106, EISCONN),
        (107, ENOTCONN), (108, ESHUTDOWN), (109, ETOOMANYREFS),
        (110, ETIMEDOUT), (111, ECONNREFUSED), (112, EHOSTDOWN),
        (113, EHOSTUNREACH), (114, EALREADY), (115, EINPROGRESS),
        (116, ESTALE), (122, EDQUOT), (125, ECANCELED),
    ]

    private static let toHostTable: [Int32: Int32] =
        Dictionary(pairs.map { ($0.linux, $0.host) }, uniquingKeysWith: { a, _ in a })
    private static let fromHostTable: [Int32: Int32] =
        Dictionary(pairs.map { ($0.host, $0.linux) }, uniquingKeysWith: { a, _ in a })

    /// Converts an errno received over the wire into this platform's value.
    ///
    /// A number we do not recognise is passed through: some servers invent
    /// codes, and a wrong-but-nonzero errno is more useful than EIO.
    public static func toHost(_ linux: Int32) -> Int32 {
        toHostTable[linux] ?? linux
    }

    /// Converts a local errno into the Linux value to put on the wire.
    public static func fromHost(_ host: Int32) -> Int32 {
        fromHostTable[host] ?? host
    }
}

#if !canImport(Darwin)
// Linux spells the "no such attribute" error ENODATA; Darwin has a distinct
// ENOATTR. Give the table one name to use on both.
private let ENOATTR: Int32 = ENODATA
private let ETOOMANYREFS: Int32 = 109
#endif
