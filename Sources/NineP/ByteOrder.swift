// 9P wire primitives. All integers are little-endian.
//
// Reference: Plan 9 intro(5). Data items of larger or variable lengths are
// represented by a two-byte field specifying a count, n, followed by n bytes
// of data. Text strings are represented the same way and are NOT NUL
// terminated.

import Foundation

/// Errors raised while decoding a 9P message from the wire.
public enum NinePWireError: Error, Equatable, Sendable {
    /// The buffer ended before the field could be read.
    case truncated(needed: Int, available: Int)
    /// A string field did not contain valid UTF-8.
    case invalidUTF8
    /// The message type byte is not one this implementation knows.
    case unknownMessageType(UInt8)
    /// The declared frame size is nonsensical (smaller than a header, or above msize).
    case invalidFrameSize(UInt32)
    /// A message body contained fewer or more bytes than the message requires.
    case trailingBytes(Int)
    /// A count field exceeded what the protocol allows (e.g. >16 walk names).
    case fieldOutOfRange(String)
}

/// A cursor over a byte buffer that reads little-endian 9P primitives.
public struct ByteReader: Sendable {
    public private(set) var bytes: ArraySlice<UInt8>

    public init(_ bytes: [UInt8]) { self.bytes = bytes[...] }
    public init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes }
    public init(_ data: Data) { self.bytes = [UInt8](data)[...] }

    /// Number of bytes not yet consumed.
    public var remaining: Int { bytes.count }

    /// True when every byte has been consumed.
    public var isAtEnd: Bool { bytes.isEmpty }

    @inline(__always)
    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard bytes.count >= n else {
            throw NinePWireError.truncated(needed: n, available: bytes.count)
        }
        let head = bytes.prefix(n)
        bytes = bytes.dropFirst(n)
        return head
    }

    public mutating func u8() throws -> UInt8 {
        let s = try take(1)
        return s[s.startIndex]
    }

    public mutating func u16() throws -> UInt16 {
        let s = try take(2)
        let i = s.startIndex
        return UInt16(s[i]) | UInt16(s[i + 1]) << 8
    }

    public mutating func u32() throws -> UInt32 {
        let s = try take(4)
        let i = s.startIndex
        return UInt32(s[i]) | UInt32(s[i + 1]) << 8 | UInt32(s[i + 2]) << 16 | UInt32(s[i + 3]) << 24
    }

    public mutating func u64() throws -> UInt64 {
        let lo = try u32()
        let hi = try u32()
        return UInt64(lo) | UInt64(hi) << 32
    }

    /// Reads `count[2]` followed by that many raw bytes.
    public mutating func lengthPrefixedBytes() throws -> [UInt8] {
        let n = Int(try u16())
        return Array(try take(n))
    }

    /// Reads a `s[2]` string: a two-byte length followed by UTF-8 bytes.
    public mutating func string() throws -> String {
        let n = Int(try u16())
        let raw = try take(n)
        guard let s = String(bytes: raw, encoding: .utf8) else {
            throw NinePWireError.invalidUTF8
        }
        return s
    }

    /// Reads `count[4]` followed by that many raw bytes (used by Twrite/Rread).
    public mutating func u32PrefixedBytes() throws -> [UInt8] {
        let n = Int(try u32())
        return Array(try take(n))
    }

    public mutating func raw(_ n: Int) throws -> [UInt8] {
        Array(try take(n))
    }

    /// Consumes and returns everything left in the buffer.
    public mutating func rest() -> [UInt8] {
        let r = Array(bytes)
        bytes = bytes.suffix(0)
        return r
    }

    /// Throws if any bytes remain; used to catch decoder/encoder drift.
    public func expectEmpty() throws {
        if !bytes.isEmpty { throw NinePWireError.trailingBytes(bytes.count) }
    }
}

/// An append-only buffer that writes little-endian 9P primitives.
public struct ByteWriter: Sendable {
    public private(set) var bytes: [UInt8]

    public init(reserving capacity: Int = 64) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    public var count: Int { bytes.count }

    public mutating func u8(_ v: UInt8) { bytes.append(v) }

    public mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    public mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        bytes.append(UInt8(truncatingIfNeeded: v >> 24))
    }

    public mutating func u64(_ v: UInt64) {
        u32(UInt32(truncatingIfNeeded: v))
        u32(UInt32(truncatingIfNeeded: v >> 32))
    }

    /// Writes a `s[2]` string. Strings longer than 65535 bytes are rejected by
    /// the caller long before this point; we truncate defensively rather than trap.
    public mutating func string(_ s: String) {
        let utf8 = Array(s.utf8)
        precondition(utf8.count <= Int(UInt16.max), "9P string exceeds 64KiB")
        u16(UInt16(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    public mutating func lengthPrefixedBytes(_ b: [UInt8]) {
        precondition(b.count <= Int(UInt16.max))
        u16(UInt16(b.count))
        bytes.append(contentsOf: b)
    }

    public mutating func u32PrefixedBytes(_ b: [UInt8]) {
        u32(UInt32(b.count))
        bytes.append(contentsOf: b)
    }

    public mutating func raw(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    public mutating func raw(_ b: ArraySlice<UInt8>) { bytes.append(contentsOf: b) }

    /// Overwrites four bytes at `offset` — used to backfill the frame size.
    public mutating func patchU32(at offset: Int, _ v: UInt32) {
        bytes[offset] = UInt8(truncatingIfNeeded: v)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: v >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: v >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: v >> 24)
    }

    /// Overwrites two bytes at `offset` — used to backfill stat sizes.
    public mutating func patchU16(at offset: Int, _ v: UInt16) {
        bytes[offset] = UInt8(truncatingIfNeeded: v)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }
}
