import Testing
import Foundation
import FS9NFS

private func hexBytes(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

@Suite("XDR primitives")
struct XDRPrimitiveTests {
    @Test("integers are big-endian, unlike 9P's little-endian wire")
    func bigEndian() throws {
        var e = XDREncoder()
        e.uint32(0x0102_0304)
        e.uint64(0x0506_0708_090A_0B0C)
        #expect(hexBytes(e.bytes) == "01020304" + "05060708090a0b0c")

        var d = XDRDecoder(e.bytes)
        #expect(try d.uint32() == 0x0102_0304)
        #expect(try d.uint64() == 0x0506_0708_090A_0B0C)
        #expect(d.isAtEnd)
    }

    @Test("signed values round-trip through their bit patterns")
    func signed() throws {
        var e = XDREncoder()
        e.int32(-2)
        e.int64(-3)
        var d = XDRDecoder(e.bytes)
        #expect(try d.int32() == -2)
        #expect(try d.int64() == -3)
    }

    @Test("a boolean is four bytes and only 0 or 1 is legal")
    func booleans() throws {
        var e = XDREncoder()
        e.bool(true)
        e.bool(false)
        #expect(e.bytes.count == 8)
        var d = XDRDecoder(e.bytes)
        #expect(try d.bool() == true)
        #expect(try d.bool() == false)

        var bogus = XDRDecoder([0, 0, 0, 2])
        #expect(throws: XDRError.invalidBoolean(2)) { _ = try bogus.bool() }
    }

    @Test("opaques of every length mod 4 are padded to a four-byte boundary")
    func padding() throws {
        for length in 0...9 {
            let payload = [UInt8](repeating: 0xAB, count: length)
            var e = XDREncoder()
            e.opaqueVariable(payload)
            // Four bytes of length, then the data rounded up to a multiple of 4.
            let expected = 4 + (length + 3) / 4 * 4
            #expect(e.count == expected, "length \(length)")

            var d = XDRDecoder(e.bytes)
            #expect(try d.opaqueVariable() == payload, "length \(length)")
            #expect(d.isAtEnd, "padding was not consumed for length \(length)")
        }
    }

    @Test("fixed opaques are padded and consumed the same way")
    func fixedPadding() throws {
        for length in 0...9 {
            let payload = (0..<length).map { UInt8($0) }
            var e = XDREncoder()
            e.opaqueFixed(payload)
            e.uint32(0xDEAD_BEEF)
            var d = XDRDecoder(e.bytes)
            #expect(try d.opaqueFixed(length) == payload, "length \(length)")
            #expect(try d.uint32() == 0xDEAD_BEEF, "misaligned after \(length) bytes")
        }
    }

    @Test("strings count bytes, not characters, and are not NUL terminated")
    func strings() throws {
        var e = XDREncoder()
        e.string("héllo")
        var d = XDRDecoder(e.bytes)
        #expect(try d.uint32() == 6)

        var again = XDRDecoder(e.bytes)
        #expect(try again.string() == "héllo")
        #expect(again.isAtEnd)
    }

    @Test("arrays carry a four-byte count")
    func arrays() throws {
        var e = XDREncoder()
        e.array([UInt32(1), 2, 3]) { $0.uint32($1) }
        var d = XDRDecoder(e.bytes)
        #expect(try d.array(limit: 8) { try $0.uint32() } == [1, 2, 3])
    }

    @Test("an optional is a discriminant followed by the value")
    func optionals() throws {
        var e = XDREncoder()
        e.optional(UInt32(7)) { $0.uint32($1) }
        e.optional(UInt32?.none) { $0.uint32($1) }
        var d = XDRDecoder(e.bytes)
        #expect(try d.optional { try $0.uint32() } == 7)
        #expect(try d.optional { try $0.uint32() } == nil)
    }
}

@Suite("XDR bounds checking")
struct XDRBoundsTests {
    @Test("a truncated buffer throws instead of reading past the end")
    func truncated() {
        var d = XDRDecoder([0, 0, 0])
        #expect(throws: XDRError.truncated(needed: 4, available: 3)) { _ = try d.uint32() }
    }

    @Test("an opaque whose data is missing throws rather than returning short")
    func truncatedOpaque() {
        // Declares eight bytes and supplies two.
        var d = XDRDecoder([0, 0, 0, 8, 1, 2])
        #expect(throws: (any Error).self) { _ = try d.opaqueVariable() }
    }

    @Test("an absurd declared length is refused before anything is allocated")
    func absurdLength() {
        // 0xFFFFFFF0 bytes claimed, six bytes present. Honouring this would be
        // a four-gigabyte allocation driven by a peer.
        var d = XDRDecoder([0xFF, 0xFF, 0xFF, 0xF0, 1, 2], defaultLimit: 1024)
        #expect(throws: XDRError.lengthExceedsLimit(declared: 0xFFFF_FFF0, limit: 1024)) {
            _ = try d.opaqueVariable()
        }
    }

    @Test("a per-call limit overrides the decoder's default")
    func callSiteLimit() {
        var d = XDRDecoder([0, 0, 0, 100] + [UInt8](repeating: 0, count: 100))
        #expect(throws: XDRError.lengthExceedsLimit(declared: 100, limit: 16)) {
            _ = try d.opaqueVariable(limit: 16)
        }
    }

    @Test("an array with an absurd element count is refused")
    func absurdArray() {
        var d = XDRDecoder([0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: (any Error).self) { _ = try d.array(limit: 16) { try $0.uint32() } }
    }

    @Test("trailing bytes after a complete message are detectable")
    func trailing() throws {
        var d = XDRDecoder([0, 0, 0, 1, 9])
        _ = try d.uint32()
        #expect(throws: XDRError.trailingBytes(1)) { try d.expectEnd() }
    }

    @Test("invalid UTF-8 in a string is rejected")
    func badUTF8() {
        var d = XDRDecoder([0, 0, 0, 2, 0xFF, 0xFE, 0, 0])
        #expect(throws: XDRError.invalidUTF8) { _ = try d.string() }
    }
}
