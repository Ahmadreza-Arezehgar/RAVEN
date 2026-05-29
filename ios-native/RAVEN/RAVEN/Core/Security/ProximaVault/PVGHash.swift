//
//  PVGHash.swift
//  RAVEN — PROXIMA-VAULT
//
//  Information-theoretic universal hash over GF(2¹²⁸).
//
//  This is the core of PV's Wegman-Carter MAC: we hash a message
//  under a one-time-uniform key H drawn from the pad, then XOR the
//  result with a one-time pad strip to produce the on-wire tag.
//
//  Why a fresh universal hash and not HMAC?
//  ─────────────────────────────────────────
//  HMAC's forgery resistance reduces to "SHA-256 is a PRF" — a
//  computational assumption. Universal hashing keyed by a uniform
//  one-time key gives **information-theoretic** ε-AXU security:
//  the forgery probability is bounded by (m+1)/2¹²⁸ for any
//  adversary, including unbounded ones. Combined with a one-time
//  XOR mask, this is the textbook Wegman-Carter construction
//  (1981). The same hash family powers GHASH inside AES-GCM, so
//  we're standing on well-trodden ground.
//
//  Convention used here (NOT the NIST SP 800-38D bit-reflected one):
//    • A field element is 128 bits stored as `(hi, lo)` UInt64 pair
//    • `hi`'s MSB is x¹²⁷, `lo`'s LSB is x⁰
//    • Reduction polynomial: p(x) = x¹²⁸ + x⁷ + x² + x + 1
//    • Multiplication by x shifts left by 1; if the top bit was 1,
//      XOR the constant 0x87 into the LSB (the four set bits of
//      x⁷ + x² + x + 1 = 0b10000111).
//
//  This is the "Intel/AArch64 carryless-multiply native" convention
//  — same as what hardware PCLMUL/PMULL instructions return. So if
//  we later add a hardware-accelerated path it drops in without
//  bit-reversal gymnastics.
//
//  Performance baseline (Swift schoolbook, no PMULL): ~30 µs for a
//  1 KiB message on an A17. Adequate for chat-rate (< 100 msg/s);
//  v2 will swap in a hardware path for file/media throughput.
//

import Foundation

/// Element of GF(2¹²⁸) with the standard (non-bit-reflected) convention.
struct PVGF128: Equatable, Hashable, Sendable {
    /// High 64 bits — `hi`'s MSB is the x¹²⁷ coefficient.
    var hi: UInt64
    /// Low 64 bits — `lo`'s LSB is the x⁰ coefficient.
    var lo: UInt64

    /// Additive identity (the zero polynomial).
    static let zero = PVGF128(hi: 0, lo: 0)

    // MARK: - Byte ↔ field conversion

    /// Decode 16 big-endian bytes into a field element. The first
    /// byte holds bits 127..120 (highest), the last byte holds bits
    /// 7..0 (lowest). Standard big-endian — matches how we
    /// serialise tags on the wire.
    static func fromBytes(_ data: Data) -> PVGF128 {
        precondition(data.count == 16, "PVGF128 requires exactly 16 bytes")
        // Use a local copy because indexed `Data` access can require
        // base-offset normalisation when the buffer is a slice.
        let bytes = Array(data)
        var hi: UInt64 = 0
        var lo: UInt64 = 0
        for i in 0..<8 {
            hi = (hi << 8) | UInt64(bytes[i])
        }
        for i in 8..<16 {
            lo = (lo << 8) | UInt64(bytes[i])
        }
        return PVGF128(hi: hi, lo: lo)
    }

    /// Encode a field element to 16 big-endian bytes.
    func toBytes() -> Data {
        var out = Data(count: 16)
        for i in 0..<8 {
            out[i]     = UInt8((hi >> (8 * (7 - i))) & 0xFF)
            out[i + 8] = UInt8((lo >> (8 * (7 - i))) & 0xFF)
        }
        return out
    }

    // MARK: - Field arithmetic

    /// Addition in GF(2¹²⁸) — XOR of coefficient vectors.
    static func + (a: PVGF128, b: PVGF128) -> PVGF128 {
        PVGF128(hi: a.hi ^ b.hi, lo: a.lo ^ b.lo)
    }

    /// `a * x mod p(x)`. The fundamental shift-and-reduce step.
    /// • Shift the 128-bit value left by 1.
    /// • If the bit that fell off the top was 1, the result has an
    ///   `x¹²⁸` term, which we reduce by adding (XORing) the
    ///   reduction polynomial minus its leading term:
    ///       x⁷ + x² + x + 1  ⇒  0b10000111  ⇒  0x87
    static func mulByX(_ v: PVGF128) -> PVGF128 {
        let topBitSet = (v.hi & 0x8000_0000_0000_0000) != 0
        var result = PVGF128(
            hi: (v.hi << 1) | (v.lo >> 63),
            lo:  v.lo << 1
        )
        if topBitSet {
            result.lo ^= 0x87
        }
        return result
    }

    /// Multiplication in GF(2¹²⁸). Schoolbook: for each bit of `b`
    /// from MSB to LSB, accumulate `b's running product by x` into
    /// `z` whenever the bit is set. Constant-time-ish — every
    /// iteration does the same work, but the conditional XOR may
    /// be cache-visible. Good enough for v1 reference; production
    /// builds should swap to PMULL on A11+.
    static func * (a: PVGF128, b: PVGF128) -> PVGF128 {
        var z = PVGF128.zero
        var v = a
        // Iterate bit 0 (LSB of b.lo) through bit 127 (MSB of b.hi).
        for i in 0..<64 {
            if (b.lo >> i) & 1 == 1 {
                z = z + v
            }
            v = mulByX(v)
        }
        for i in 0..<64 {
            if (b.hi >> i) & 1 == 1 {
                z = z + v
            }
            v = mulByX(v)
        }
        return z
    }
}

// MARK: - GHASH (polynomial universal hash)

enum PVGHash {

    /// Compute GHASH_H(M) where H is a fresh one-time key (16 B)
    /// and M is a byte string.
    ///
    /// Construction (matches NIST GHASH up to bit convention):
    ///   1. Split M into 16-byte blocks, zero-padding the last
    ///      block if needed.
    ///   2. Append one final 16-byte block encoding the bit-length
    ///      of M as a big-endian uint128 (high 64 bits = 0,
    ///      low 64 bits = bitlen). This length encoding is what
    ///      stops trivial extension attacks — without it,
    ///      `M = "ab"` and `M' = "ab\x00"` would hash to the same
    ///      thing.
    ///   3. Y_0 = 0
    ///      Y_i = (Y_{i-1} ⊕ block_i) · H
    ///   4. Return Y_m as 16 big-endian bytes.
    ///
    /// ε-AXU bound: Pr[GHASH_H(M) = GHASH_H(M')] ≤ (m + 1) / 2¹²⁸
    /// for any two distinct messages of at most m 128-bit blocks.
    /// This is the canonical Wegman-Carter universal-hash bound.
    static func hash(key: Data, message: Data) -> Data {
        precondition(key.count == 16, "PVGHash key must be exactly 16 bytes")

        let H = PVGF128.fromBytes(key)
        var Y = PVGF128.zero

        // Step 1+3: absorb message blocks (zero-padded).
        let blockCount = (message.count + 15) / 16
        for blockIdx in 0..<blockCount {
            let start = blockIdx * 16
            let end = min(start + 16, message.count)
            var block = Data(count: 16)
            // Copy this block's bytes; remaining bytes are zero by Data init.
            // Use plain assignment to keep slice/base-offset bookkeeping
            // out of the picture.
            for (i, b) in message[start..<end].enumerated() {
                block[i] = b
            }
            let X = PVGF128.fromBytes(block)
            Y = (Y + X) * H
        }

        // Step 2: length-encoding block. 16 bytes big-endian uint128.
        // High 64 bits = 0 (we don't support messages > 2^64 bits).
        var lenBlock = Data(count: 16)
        let bitLen = UInt64(message.count) &* 8
        // Place bitLen big-endian into the low 8 bytes.
        for i in 0..<8 {
            lenBlock[8 + i] = UInt8((bitLen >> (8 * (7 - i))) & 0xFF)
        }
        let L = PVGF128.fromBytes(lenBlock)
        Y = (Y + L) * H

        return Y.toBytes()
    }
}
