import Foundation
import NinePClient
import FS9Core

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The `NSError` an FSKit reply handler should carry, as plain values.
///
/// On macOS the shim turns this into `fs_errorForPOSIXError(code)`, which is
/// FSKit's own constructor and produces an `NSPOSIXErrorDomain` error. Keeping
/// the decision here means the table of which failure becomes which errno is
/// testable on Linux, where FSKit does not exist.
public struct FS9ErrorDescriptor: Sendable, Hashable {
    public var domain: String
    public var code: Int32
    public var message: String

    public init(domain: String = fs9POSIXErrorDomain, code: Int32, message: String = "") {
        self.domain = domain
        self.code = code
        self.message = message
    }
}

/// `NSPOSIXErrorDomain`, spelled out because swift-corelibs-foundation and
/// Darwin's Foundation disagree about where the constant lives.
public let fs9POSIXErrorDomain = "NSPOSIXErrorDomain"

/// Reduces anything thrown inside the backend to a single errno.
///
/// Ordering matters: `FSError` already carries the answer, a server error
/// carries the server's, a mount-URL problem is always the user's fault, and
/// everything else is EIO because reporting a surprising errno to the VFS is
/// worse than reporting a boring one.
public func fs9POSIXCode(for error: any Error) -> Int32 {
    switch error {
    case let error as FSError: return error.errno
    case let error as NinePServerError: return error.errno
    case let error as MountURLError: return error.errnoValue
    case let error as NinePClientError: return posixCode(forClientError: error)
    case is CancellationError: return EINTR
    default: return EIO
    }
}

/// Everything the FSKit reply handler needs in order to answer.
public func fs9ErrorDescriptor(for error: any Error) -> FS9ErrorDescriptor {
    FS9ErrorDescriptor(code: fs9POSIXCode(for: error), message: String(describing: error))
}

/// Transport failures have no errno of their own, so they get the one the
/// kernel handles most sensibly: a dead session is `ENOTCONN` so callers stop
/// retrying, a timeout is `ETIMEDOUT`, and a protocol violation is `EIO`.
private func posixCode(forClientError error: NinePClientError) -> Int32 {
    switch error {
    case .badEndpoint, .resolutionFailed: return EINVAL
    case let .connectionFailed(errno, _): return errno == 0 ? EHOSTUNREACH : errno
    case .connectionClosed, .sessionClosed: return ENOTCONN
    case .timedOut: return ETIMEDOUT
    case let .io(errno, _): return errno == 0 ? EIO : errno
    case .frameTooLarge, .protocolViolation, .unexpectedReply: return EIO
    case .versionNegotiationFailed: return EPROTONOSUPPORT
    }
}

/// The errno a write path should report when the volume is read-only.
///
/// Split out because `EROFS` and `EPERM` are not interchangeable to the VFS:
/// `EROFS` makes the kernel stop asking, `EPERM` makes it retry as another user.
public func fs9ReadOnlyError(_ detail: String = "volume mounted read-only") -> FSError {
    FSError(EROFS, detail)
}
