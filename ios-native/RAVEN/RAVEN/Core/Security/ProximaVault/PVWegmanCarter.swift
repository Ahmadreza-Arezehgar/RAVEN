//
//  PVWegmanCarter.swift
//  RAVEN — PROXIMA-VAULT
//
//  Information-theoretic MAC under one-time pad keying.
//
//      MAC(M; K_wc, mask) = GHASH_{K_wc}(M) ⊕ mask
//
//  where:
//    • K_wc  is a fresh 16-byte universal-hash key drawn from the
//             one-time pad (Wegman-Carter "hash key").
//    • M      is the message (ciphertext || AAD-bound header).
//    • mask   is a fresh 16-byte one-time XOR mask drawn from the
//             pad (Wegman-Carter "pad strip").
//    • ⊕     is XOR.
//
//  Both K_wc and mask are USED EXACTLY ONCE. Reusing K_wc with two
//  messages reduces Wegman-Carter security to bare GHASH (which
//  alone is NOT a MAC — universal hashing without an output mask
//  leaks the polynomial structure across messages). Reusing mask
//  with two distinct messages but different K_wc leaks the XOR of
//  their two GHASH outputs.
//
//  Pad-bytes hygiene is therefore THE critical invariant of PV
//  v3.1.2 — the cursor in `PVPadCursor` is what enforces it, and
//  this file expects the caller to have already advanced + persisted
//  the cursor before invoking `tag(...)`.
//
//  Forgery bound (Wegman-Carter / GHASH):
//      Pr[forgery] ≤ q · (ℓ + 1) / 2¹²⁸
//  where q = number of forgery attempts, ℓ = max blocks per message.
//  For ℓ = 256 (4 KiB message), forgery probability per attempt is
//  < 2⁻¹¹⁹ — practically zero against any unbounded adversary.
//

import Foundation

enum PVWegmanCarter {

    /// Compute the Wegman-Carter tag over `message` using
    /// fresh-one-time `key` and `mask` strips from the pad.
    /// Returns 16 bytes (the MAC tag) suitable for direct
    /// embedding in the envelope.
    ///
    /// Precondition: both `key` and `mask` are exactly 16 bytes
    /// AND have been drawn from a pad slot that will not be
    /// reused. The encryptor enforces this by advancing the
    /// cursor before calling.
    static func tag(message: Data, key: Data, mask: Data) -> Data {
        precondition(key.count == 16, "Wegman-Carter key must be 16 bytes")
        precondition(mask.count == 16, "Wegman-Carter mask must be 16 bytes")

        let hash = PVGHash.hash(key: key, message: message)
        return PVWegmanCarter.xor(hash, mask)
    }

    /// Constant-time verification of a received tag. NEVER use
    /// `==` on the raw bytes for security-sensitive comparison —
    /// the stdlib short-circuits on first mismatch.
    static func verify(message: Data,
                       key: Data,
                       mask: Data,
                       receivedTag: Data) -> Bool {
        guard receivedTag.count == 16 else { return false }
        let expected = tag(message: message, key: key, mask: mask)
        return constantTimeEqual(expected, receivedTag)
    }

    // MARK: - Helpers

    /// XOR two equal-length byte strings. Caller MUST ensure equal
    /// length — we precondition rather than truncating because
    /// silent truncation in crypto code is a classic footgun.
    static func xor(_ a: Data, _ b: Data) -> Data {
        precondition(a.count == b.count, "XOR operands must match length")
        var out = Data(count: a.count)
        for i in 0..<a.count {
            out[i] = a[i] ^ b[i]
        }
        return out
    }

    /// Constant-time byte-string comparison. OR-accumulates the
    /// per-byte XOR so the timing is the same regardless of where
    /// the first mismatch falls.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }
}
