// Compiled only where the macOS 26 SDK is in play.
//
// `canImport(FSKit)` alone is not a strong enough gate: the framework exists in
// the macOS 15.4 SDK too, but there it has no FSGenericURLResource — the class
// that makes it possible to mount something with no block device behind it —
// and its protocol reply handlers differ. Compiling this against that SDK fails
// on both counts.
//
// There is no `#if` that asks the SDK's version directly, so the compiler
// version stands in for it: the macOS 26 SDK ships with Xcode 26, whose Swift
// is 6.2 or later, while the 15.4 SDK ships with Xcode 16.4 and Swift 6.1. A
// deliberately mismatched pairing — a standalone 6.2 toolchain aimed at the
// 15.4 SDK — would defeat this, but that combination cannot build the backend
// anyway.
#if canImport(FSKit) && compiler(>=6.2)
import Foundation
// FSKit's protocol reply handlers are not `@Sendable`, so a witness that
// declares them `@Sendable` does not satisfy the requirement — which then makes
// the whole type fail to conform, and the extension entry point fail its
// associated-type constraint. The handlers are therefore spelled exactly as the
// framework spells them, and the import is `@preconcurrency` so that capturing
// one in a Task is a warning about Apple's annotations rather than an error in
// ours.
@preconcurrency import FSKit
import os
import FS9Core
import NinePClient

@available(macOS 26.0, *)
extension Logger {
    /// One subsystem for the whole backend so `log stream --predicate
    /// 'subsystem == "com.fs9kit"'` catches everything. See `macos/README.md`.
    static let fs9kit = Logger(subsystem: "com.fs9kit", category: "fskit")
}

/// Carries a value that Swift cannot prove is `Sendable` into the `Task` that
/// answers an FSKit reply handler.
///
/// FSKit's parameter objects — `FSFileName`, `FSDirectoryEntryPacker`,
/// `FSMutableFileDataBuffer`, the attribute requests — are Objective-C classes
/// with no `Sendable` conformance, and every operation is a completion-handler
/// call whose work has to happen on a 9P round trip. The object belongs to one
/// in-flight operation and FSKit keeps it alive until the reply handler runs,
/// so moving it to the task that produces the reply is safe; the compiler just
/// cannot see that.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// The error to hand an FSKit reply handler.
///
/// `fs_errorForPOSIXError` is FSKit's own constructor and is what the VFS layer
/// expects to unwrap back into an errno; a bare `POSIXError` reaches the kernel
/// as a Cocoa error and turns into `EIO`.
@available(macOS 26.0, *)
func fs9Error(_ error: any Error) -> any Error {
    let code = fs9POSIXCode(for: error)
    Logger.fs9kit.debug("replying errno \(code, privacy: .public): \(String(describing: error), privacy: .public)")
    return fs_errorForPOSIXError(code)
}

@available(macOS 26.0, *)
func fs9Error(errno code: Int32) -> any Error { fs_errorForPOSIXError(code) }

// MARK: - Item kinds

@available(macOS 26.0, *)
extension FS9ItemKind {
    var fsItemType: FSItem.ItemType {
        switch self {
        case .unknown: .unknown
        case .file: .file
        case .directory: .directory
        case .symlink: .symlink
        case .fifo: .fifo
        case .charDevice: .charDevice
        case .blockDevice: .blockDevice
        case .socket: .socket
        }
    }

    init(_ type: FSItem.ItemType) {
        switch type {
        case .file: self = .file
        case .directory: self = .directory
        case .symlink: self = .symlink
        case .fifo: self = .fifo
        case .charDevice: self = .charDevice
        case .blockDevice: self = .blockDevice
        case .socket: self = .socket
        default: self = .unknown
        }
    }
}

@available(macOS 26.0, *)
extension FSItem.Identifier {
    /// Never traps: an identifier we cannot express is `.invalid`, which the
    /// kernel treats as "no persistent ID" rather than as a fatal error.
    static func fs9(_ raw: UInt64) -> FSItem.Identifier {
        FSItem.Identifier(rawValue: raw) ?? .invalid
    }
}

// MARK: - Attributes

@available(macOS 26.0, *)
extension FSItem.Attributes {
    /// Fills in every field, whatever was asked for.
    ///
    /// Answering only the requested attributes is the documented contract, but
    /// a volume that leaves `modifyTime` unset does not appear in Finder at all
    /// (forums thread 784055), and the cost of the extra assignments is nil —
    /// the values are already in hand.
    convenience init(fs9 attributes: FS9ItemAttributes) {
        self.init()
        type = attributes.kind.fsItemType
        fileID = .fs9(attributes.itemID)
        parentID = .fs9(attributes.parentID)
        mode = attributes.mode
        uid = attributes.uid
        gid = attributes.gid
        linkCount = attributes.linkCount
        size = attributes.size
        allocSize = attributes.allocSize
        flags = attributes.flags
        accessTime = attributes.accessTimespec
        modifyTime = attributes.modifyTimespec
        changeTime = attributes.changeTimespec
        birthTime = attributes.birthTimespec
    }
}

@available(macOS 26.0, *)
extension FSItem.SetAttributesRequest {
    /// Reads out the fields the caller actually set.
    ///
    /// UNCONFIRMED: `isValid(_:)` is the accessor named in the FSKit headers'
    /// attribute-validity pattern, but Apple documents neither it nor the
    /// alternative spelling `wasAttributeConsumed(_:)`. If this does not
    /// compile on a real SDK, this method is the only place to change — every
    /// caller goes through `FS9SetAttributes`.
    var fs9Requested: FS9SetAttributes {
        var request = FS9SetAttributes()
        if isValid(.mode) { request.mode = mode }
        if isValid(.uid) { request.uid = uid }
        if isValid(.gid) { request.gid = gid }
        if isValid(.size) { request.size = size }
        if isValid(.accessTime) { request.accessTime = fs9FileTime(accessTime) }
        if isValid(.modifyTime) { request.modifyTime = fs9FileTime(modifyTime) }
        return request
    }
}

// MARK: - Open modes

@available(macOS 26.0, *)
extension FS9OpenModes {
    /// UNCONFIRMED: whether `FSVolume.OpenModes` has members beyond `.read` and
    /// `.write`. Only those two are read here; an append- or truncate-on-open
    /// that FSKit expresses some other way is handled by the explicit offsets
    /// on `write` and by `setAttributes(size:)`, so nothing is lost by missing
    /// them.
    init(_ modes: FSVolume.OpenModes) {
        var result = FS9OpenModes()
        if modes.contains(.read) { result.insert(.read) }
        if modes.contains(.write) { result.insert(.write) }
        self = result
    }
}

// MARK: - Names

@available(macOS 26.0, *)
extension FSFileName {
    /// A 9P name is a UTF-8 string on the wire, so a name that is not valid
    /// UTF-8 cannot be sent at all. Report it rather than lossily transcoding
    /// it into a name that would address a different file.
    func fs9String() throws -> String {
        guard let string else {
            throw FSError(EILSEQ, "file name is not valid UTF-8")
        }
        return string
    }
}
#endif
