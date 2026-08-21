// XDR: External Data Representation, RFC 4506.
//
// Everything is big-endian and everything is padded out to a multiple of four
// bytes. That second rule is the one implementations get wrong: a three-byte
// opaque is followed by one zero byte, and the reader must skip it or every
// later field is misaligned.
//
// 9P's ``ByteReader``/``ByteWriter`` are little-endian, so this is a separate
// codec rather than a shim over those.

import Foundation

/// Errors raised while decoding XDR from a socket.
public enum XDRError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The buffer ended before the field could be read.
    case truncated(needed: Int, available: Int)
    /// A declared length was larger than the caller said it could be.
    ///
    /// This is the important one: the length comes from the network, and
    /// honouring it blindly would let a peer make us allocate gigabytes.
    case lengthExceedsLimit(declared: UInt64, limit: Int)
    /// A boolean was neither 0 nor 1.
    case invalidBoolean(UInt32)
    /// A string field was not valid UTF-8.
    case invalidUTF8
    /// Bytes were left over after decoding a complete message.
    case trailingBytes(Int)

    public var description: String {
        switch self {
        case let .truncated(needed, available):
            return "truncated XDR: needed \(needed) bytes, \(available) available"
        case let .lengthExceedsLimit(declared, limit):
            return "XDR length \(declared) exceeds the limit of \(limit)"
        case let .invalidBoolean(value):
            return "XDR boolean was \(value), not 0 or 1"
        case .invalidUTF8:
            return "XDR string was not valid UTF-8"
        case let .trailingBytes(count):
            return "\(count) trailing bytes after the XDR message"
        }
    }
}

/// Rounds `n` up to the next multiple of four, which is XDR's universal
/// alignment.
@inline(__always)
func xdrPadded(_ n: Int) -> Int { (n + 3) & ~3 }

// MARK: - Decoding

/// A cursor that reads big-endian XDR primitives out of a byte buffer.
///
/// It is a value type so a handler can take a copy, decode its arguments and
/// leave the caller's cursor alone; that also keeps it `Sendable` for the
/// dispatch path, which crosses a task boundary.
public struct XDRDecoder: Sendable {
    public let bytes: [UInt8]
    public private(set) var index: Int
    /// Default ceiling for a variable-length field when a call site does not
    /// name its own. Sized for a full NFS WRITE payload plus headers.
    public var defaultLimit: Int

    public init(_ bytes: [UInt8], defaultLimit: Int = 1 << 20) {
        self.bytes = bytes
        self.index = 0
        self.defaultLimit = defaultLimit
    }

    public init(_ bytes: ArraySlice<UInt8>, defaultLimit: Int = 1 << 20) {
        self.init(Array(bytes), defaultLimit: defaultLimit)
    }

    public var remaining: Int { bytes.count - index }
    public var isAtEnd: Bool { remaining == 0 }

    /// Throws unless every byte has been consumed. Callers use this to reject
    /// a request that carried more arguments than the procedure defines.
    public func expectEnd() throws {
        guard isAtEnd else { throw XDRError.trailingBytes(remaining) }
    }

    @inline(__always)
    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0 else { throw XDRError.truncated(needed: 0, available: remaining) }
        guard remaining >= n else { throw XDRError.truncated(needed: n, available: remaining) }
        let slice = bytes[index..<(index + n)]
        index += n
        return slice
    }

    public mutating func uint32() throws -> UInt32 {
        let s = try take(4)
        let i = s.startIndex
        return UInt32(s[i]) << 24 | UInt32(s[i + 1]) << 16 | UInt32(s[i + 2]) << 8 | UInt32(s[i + 3])
    }

    public mutating func int32() throws -> Int32 {
        Int32(bitPattern: try uint32())
    }

    public mutating func uint64() throws -> UInt64 {
        let high = try uint32()
        let low = try uint32()
        return UInt64(high) << 32 | UInt64(low)
    }

    public mutating func int64() throws -> Int64 {
        Int64(bitPattern: try uint64())
    }

    /// XDR booleans are four-byte enums; anything but 0 or 1 is malformed and
    /// is rejected rather than coerced, because a coerced value silently
    /// changes the meaning of the union that follows it.
    public mutating func bool() throws -> Bool {
        let raw = try uint32()
        switch raw {
        case 0: return false
        case 1: return true
        default: throw XDRError.invalidBoolean(raw)
        }
    }

    /// Reads exactly `count` bytes plus alignment padding.
    public mutating func opaqueFixed(_ count: Int) throws -> [UInt8] {
        guard count <= defaultLimit else {
            throw XDRError.lengthExceedsLimit(declared: UInt64(count), limit: defaultLimit)
        }
        let value = Array(try take(count))
        _ = try take(xdrPadded(count) - count)
        return value
    }

    /// Reads a four-byte length, that many bytes, and the alignment padding.
    ///
    /// The declared length is checked against `limit` *before* anything is
    /// allocated, and against what is actually in the buffer by `take`.
    public mutating func opaqueVariable(limit: Int? = nil) throws -> [UInt8] {
        let cap = limit ?? defaultLimit
        let declared = try uint32()
        guard declared <= UInt32(clamping: cap) else {
            throw XDRError.lengthExceedsLimit(declared: UInt64(declared), limit: cap)
        }
        let count = Int(declared)
        let value = Array(try take(count))
        _ = try take(xdrPadded(count) - count)
        return value
    }

    /// An XDR string is an opaque with the same framing; it is not NUL
    /// terminated and its length is in bytes, not characters.
    public mutating func string(limit: Int? = nil) throws -> String {
        let raw = try opaqueVariable(limit: limit)
        guard let s = String(bytes: raw, encoding: .utf8) else { throw XDRError.invalidUTF8 }
        return s
    }

    /// Reads a counted array. `limit` bounds the element *count*, so a peer
    /// cannot declare four billion elements and make us reserve for them.
    public mutating func array<T>(limit: Int, _ element: (inout XDRDecoder) throws -> T) throws -> [T] {
        let declared = try uint32()
        guard declared <= UInt32(clamping: limit) else {
            throw XDRError.lengthExceedsLimit(declared: UInt64(declared), limit: limit)
        }
        var out: [T] = []
        out.reserveCapacity(min(Int(declared), 1024))
        for _ in 0..<Int(declared) { out.append(try element(&self)) }
        return out
    }

    /// An optional-data field: a boolean discriminant, then the value if true.
    public mutating func optional<T>(_ element: (inout XDRDecoder) throws -> T) throws -> T? {
        try bool() ? try element(&self) : nil
    }
}

// MARK: - Encoding

/// Appends big-endian XDR primitives to a byte buffer.
public struct XDREncoder: Sendable {
    public private(set) var bytes: [UInt8]

    public init(reservingCapacity capacity: Int = 256) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    /// How many bytes have been written. READDIR needs this to stop before it
    /// overruns the client's byte budget.
    public var count: Int { bytes.count }

    public mutating func uint32(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    public mutating func int32(_ value: Int32) { uint32(UInt32(bitPattern: value)) }

    public mutating func uint64(_ value: UInt64) {
        uint32(UInt32(truncatingIfNeeded: value >> 32))
        uint32(UInt32(truncatingIfNeeded: value))
    }

    public mutating func int64(_ value: Int64) { uint64(UInt64(bitPattern: value)) }

    public mutating func bool(_ value: Bool) { uint32(value ? 1 : 0) }

    /// Writes `value` and its alignment padding, with no length prefix.
    public mutating func opaqueFixed(_ value: [UInt8]) {
        bytes.append(contentsOf: value)
        pad(value.count)
    }

    public mutating func opaqueVariable(_ value: [UInt8]) {
        uint32(UInt32(truncatingIfNeeded: value.count))
        bytes.append(contentsOf: value)
        pad(value.count)
    }

    public mutating func opaqueVariable(_ value: ArraySlice<UInt8>) {
        uint32(UInt32(truncatingIfNeeded: value.count))
        bytes.append(contentsOf: value)
        pad(value.count)
    }

    public mutating func string(_ value: String) {
        opaqueVariable(Array(value.utf8))
    }

    public mutating func array<T>(_ values: [T], _ element: (inout XDREncoder, T) -> Void) {
        uint32(UInt32(truncatingIfNeeded: values.count))
        for value in values { element(&self, value) }
    }

    public mutating func optional<T>(_ value: T?, _ element: (inout XDREncoder, T) -> Void) {
        guard let value else { return bool(false) }
        bool(true)
        element(&self, value)
    }

    /// Appends the encoded form of another encoder, used to splice a
    /// pre-built result onto a reply header.
    public mutating func append(_ other: XDREncoder) {
        bytes.append(contentsOf: other.bytes)
    }

    /// Appends already-encoded XDR verbatim, with no length prefix and no
    /// padding — the caller guarantees it is already aligned.
    public mutating func appendRaw(_ encoded: [UInt8]) {
        bytes.append(contentsOf: encoded)
    }

    private mutating func pad(_ written: Int) {
        let padding = xdrPadded(written) - written
        for _ in 0..<padding { bytes.append(0) }
    }
}
