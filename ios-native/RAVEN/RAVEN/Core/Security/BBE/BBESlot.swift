//
//  BBESlot.swift
//  RAVEN — BBE
//
//  Slot-ID derivation. A slot is an 8-byte (64-bit) value that
//  a paired friend recognises as "me, in this epoch, in this
//  beacon nonce window". To a stranger without the per-pair key,
//  every slot is computationally indistinguishable from uniform
//  random bytes.
//
//  Definition (PDF §9):
//
//      slot_AB(t, r) = Trunc_64(HMAC-SHA256(K_BBE^(t),
//                                           "BBE-slot" || uint32(t) || r))
//
//  where `r` is the 16-byte per-beacon random nonce.
//
//  False-positive bound: for two strangers with no shared key,
//  the probability that A's slot matches any one of B's `N`
//  slots in a given beacon is `≤ N · 2⁻⁶⁴`. With N=28 that's
//  ≈ 1.5×10⁻¹⁸ per beacon — astronomically rare, but Ghost
//  Handshake (Stage 4) still confirms before surfacing
//  "verified live peer".
//

import Foundation
import CryptoKit

enum BBESlot {

    /// Derive the slot ID this pairing emits in (epoch `t`, nonce `r`).
    /// Returns the canonical 8-byte truncated form suitable for direct
    /// comparison.
    ///
    /// Caller (sender): emits this 8-byte value as one of `slotsPerBeacon`
    /// real slots in the outgoing beacon.
    ///
    /// Caller (receiver): for every active pairing, computes this value
    /// against the (t, r) reported in an incoming beacon and tests
    /// whether the result appears in the beacon's slot field.
    static func slot(epochKey kBBE: Data,
                     epoch t: UInt32,
                     nonce r: Data) throws -> Data {
        guard kBBE.count == 32 else {
            throw BBEError.internalInputError(reason: "slot: K_BBE^(t) must be 32 B")
        }
        guard r.count == BBEConstants.beaconNonceBytes else {
            throw BBEError.internalInputError(reason: "slot: nonce must be \(BBEConstants.beaconNonceBytes) B")
        }

        // Build the HMAC input: label || uint32(t) || nonce
        var input = Data(capacity: BBEConstants.slotLabel.count + 4 + r.count)
        input.append(BBEConstants.slotLabel)
        input.append(BBERatchet.uint32BE(t))
        input.append(r)

        let key = SymmetricKey(data: kBBE)
        let mac = HMAC<SHA256>.authenticationCode(for: input, using: key)
        let macBytes = Data(mac)

        // Trunc_64 = first 8 bytes of HMAC output.
        return macBytes.prefix(BBEConstants.slotBytes)
    }

    /// Constant-time equality on slot bytes. NEVER use `==` on raw
    /// Data for security-sensitive comparison — stdlib `==`
    /// short-circuits on the first mismatch.
    static func slotsEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }
}
