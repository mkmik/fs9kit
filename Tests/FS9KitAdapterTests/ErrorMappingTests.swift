import Testing
import Foundation
import NineP
import NinePClient
import FS9Core
@testable import FS9KitAdapter

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Every failure the backend can have becomes exactly one errno, because that
/// is all the kernel will carry back to the caller of `read(2)`. Getting one
/// wrong is the difference between "no such file" and "I/O error", so the table
/// is enumerated rather than spot-checked.
@Suite("Error mapping")
struct ErrorMappingTests {

    @Test("every FSError constant keeps its errno", arguments: [
        (FSError.notFound, ENOENT),
        (FSError.notDirectory, ENOTDIR),
        (FSError.isDirectory, EISDIR),
        (FSError.exists, EEXIST),
        (FSError.notEmpty, ENOTEMPTY),
        (FSError.permissionDenied, EACCES),
        (FSError.notSupported, ENOTSUP),
        (FSError.staleHandle, ESTALE),
        (FSError.invalidArgument, EINVAL),
        (FSError.nameTooLong, ENAMETOOLONG),
    ])
    func fsErrors(error: FSError, code: Int32) {
        #expect(fs9POSIXCode(for: error) == code)
    }

    @Test("an errno the backend made up itself is passed through")
    func arbitraryErrno() {
        #expect(fs9POSIXCode(for: FSError(EROFS)) == EROFS)
        #expect(fs9POSIXCode(for: FSError(EDQUOT, "over quota")) == EDQUOT)
        #expect(fs9POSIXCode(for: fs9ReadOnlyError()) == EROFS)
    }

    /// 9P2000.L carries Linux errno numbers, which `NinePServerError` has
    /// already translated to the host's. Whatever it says is the truth.
    @Test("a server error keeps the server's errno")
    func serverErrors() {
        #expect(fs9POSIXCode(for: NinePServerError(errno: ENOSPC, message: "full")) == ENOSPC)
        #expect(fs9POSIXCode(for: NinePServerError.fromLegacy("file does not exist")) == ENOENT)
        #expect(fs9POSIXCode(for: NinePServerError.fromLegacy("permission denied")) == EACCES)
        // An unrecognised legacy message is EIO, not a guess.
        #expect(fs9POSIXCode(for: NinePServerError.fromLegacy("wibble")) == EIO)
    }

    /// A bad mount URL is always the caller's fault, and it reaches the user
    /// through `mount(8)`'s exit status.
    @Test("every mount-URL failure is EINVAL", arguments: [
        MountURLError.empty,
        .notAURL("x"),
        .unsupportedScheme("nfs"),
        .missingHost,
        .invalidPort("0"),
        .unexpectedAuthority("h"),
        .missingSocketPath,
        .invalidPercentEncoding("%zz"),
        .unknownOption("k"),
        .invalidOptionValue(option: "msize", value: "0"),
    ])
    func mountURLErrors(error: MountURLError) {
        #expect(fs9POSIXCode(for: error) == EINVAL)
        #expect(error.errnoValue == EINVAL)
    }

    /// Transport failures have no errno of their own. The choice matters: a
    /// dead session must report something the kernel stops retrying on.
    @Test("transport failures get an errno the VFS can act on", arguments: [
        (NinePClientError.badEndpoint("x"), EINVAL),
        (.resolutionFailed(host: "h", detail: "d"), EINVAL),
        (.connectionFailed(errno: ECONNREFUSED, detail: "d"), ECONNREFUSED),
        (.connectionClosed, ENOTCONN),
        (.sessionClosed, ENOTCONN),
        (.timedOut, ETIMEDOUT),
        (.io(errno: EPIPE, operation: "write"), EPIPE),
        (.frameTooLarge(1, limit: 2), EIO),
        (.protocolViolation("d"), EIO),
        (.unexpectedReply(7), EIO),
        (.versionNegotiationFailed(offered: [], serverSaid: "unknown"), EPROTONOSUPPORT),
    ])
    func clientErrors(error: NinePClientError, code: Int32) {
        #expect(fs9POSIXCode(for: error) == code)
    }

    @Test("a connect failure with no errno still says something useful")
    func connectFailureWithoutErrno() {
        #expect(fs9POSIXCode(for: NinePClientError.connectionFailed(errno: 0, detail: "")) == EHOSTUNREACH)
        #expect(fs9POSIXCode(for: NinePClientError.io(errno: 0, operation: "read")) == EIO)
    }

    @Test("a cancelled operation is EINTR")
    func cancellation() {
        #expect(fs9POSIXCode(for: CancellationError()) == EINTR)
    }

    /// Anything unrecognised must not become a surprising errno: a caller can
    /// cope with EIO, but ENOENT from a bug would make it delete state.
    @Test("anything else is EIO")
    func fallback() {
        struct Mystery: Error {}
        #expect(fs9POSIXCode(for: Mystery()) == EIO)
        #expect(fs9POSIXCode(for: NSError(domain: "x", code: 1)) == EIO)
    }

    @Test("the descriptor carries the POSIX domain FSKit expects")
    func descriptor() {
        let descriptor = fs9ErrorDescriptor(for: FSError.notFound)
        #expect(descriptor.domain == "NSPOSIXErrorDomain")
        #expect(descriptor.code == ENOENT)
        #expect(descriptor.message.isEmpty == false)
    }
}
