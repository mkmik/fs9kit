import Foundation

/// A name-based UUID, RFC 4122 version 5 in shape.
///
/// `fskitd` matches the container identifier a module reports against the one
/// it already has for a resource, and treats a mismatch as an unknown container
/// — the load then fails with EAGAIN. So the identifier must be a pure function
/// of the mount target and must not change between the probe and the load, or
/// between one mount and the next.
///
/// SHA-256 is implemented here rather than taken from CryptoKit because this
/// code has to build and be tested on Linux, and the project takes no external
/// dependencies.
public enum StableUUID {
    /// The 16 bytes of a version-5-shaped UUID for `name`.
    ///
    /// Not a true RFC 4122 v5 UUID: that would be SHA-1 over a namespace UUID
    /// plus the name. SHA-256 truncated to 16 bytes is used instead because the
    /// only requirement is determinism, and nothing outside this process ever
    /// reconstructs the value.
    public static func bytes(for name: String) -> [UInt8] {
        var digest = Array(SHA256.hash(Array(name.utf8)).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50  // version 5
        digest[8] = (digest[8] & 0x3F) | 0x80  // RFC 4122 variant
        return digest
    }

    /// The same value as a `UUID`.
    public static func uuid(for name: String) -> UUID {
        let b = bytes(for: name)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// A minimal SHA-256. Only `hash(_:)` over an in-memory array is needed.
public enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]

        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        let bitCount = UInt64(message.count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8truncating(bitCount >> UInt64(shift)))
        }

        var w = [UInt32](repeating: 0, count: 64)
        var block = padded.startIndex
        while block < padded.endIndex {
            for i in 0..<16 {
                let base = block + i * 4
                w[i] = UInt32(padded[base]) << 24 | UInt32(padded[base + 1]) << 16
                    | UInt32(padded[base + 2]) << 8 | UInt32(padded[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g; g = f; f = e
                e = d &+ temp1
                d = c; c = b; b = a
                a = temp1 &+ temp2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
            block += 64
        }

        var out: [UInt8] = []
        out.reserveCapacity(32)
        for word in h {
            out.append(UInt8truncating(UInt64(word) >> 24))
            out.append(UInt8truncating(UInt64(word) >> 16))
            out.append(UInt8truncating(UInt64(word) >> 8))
            out.append(UInt8truncating(UInt64(word)))
        }
        return out
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}

private func UInt8truncating(_ value: UInt64) -> UInt8 { UInt8(value & 0xFF) }
