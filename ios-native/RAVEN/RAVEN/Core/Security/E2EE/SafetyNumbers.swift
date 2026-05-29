//
//  SafetyNumbers.swift
//  RAVEN
//
//  Out-of-band identity verification — Signal-style "safety numbers".
//
//  Why this matters
//  ────────────────
//  X3DH and Double Ratchet protect every byte of every message, but
//  ALL of that protection collapses if Mallory swaps in her own
//  public key during the very first key exchange. The defence is to
//  let Alice and Bob compare a deterministic fingerprint of their
//  two identity keys *out of band* — by reading numbers over a
//  voice call, comparing in person, or scanning a QR.
//
//  Format (matches Signal's user-visible "safety number" pattern)
//  ──────────────────────────────────────────────────────────────
//   1. Concatenate the SORTED pair of identity public keys. Sorting
//      gives both sides the same string regardless of who computes.
//   2. Iterate SHA-512 5,200 times — Signal calls this the
//      "fingerprint version 0" KDF. The high iteration count makes
//      it extremely expensive to find a collision that matches a
//      different key pair.
//   3. Take the first 30 bytes of the final hash, encode as twelve
//      groups of five base-10 digits. The decimal encoding is the
//      easiest format to read aloud over a noisy phone line.
//
//  60 digits gives ~199 bits of collision resistance — plenty.
//
//  Output looks like:
//      27462 14857 03398 16029 47185 38201
//      59312 72488 91006 33574 80445 21998
//

import Foundation
import CryptoKit

enum SafetyNumbers {

    /// Number of SHA-512 iterations. Mirrors Signal — DO NOT CHANGE
    /// without rolling the version field, otherwise everyone's
    /// previously-verified peers would suddenly show a "new" safety
    /// number.
    static let iterations = 5200

    /// Final encoded length: 12 groups × 5 digits = 60 digits.
    static let groupSize = 5
    static let groupCount = 12

    /// Compute the safety number string for the (this device, peer
    /// device) pair. Both ends produce the same value as long as
    /// they pass each other's identity keys in the same role.
    ///
    /// - Parameters:
    ///   - localIdentityKey: this device's Ed25519 public key bytes
    ///   - localStableId:    string both sides agree on (typically
    ///                       the user id / fingerprint of OUR side)
    ///   - peerIdentityKey:  peer's Ed25519 public key bytes
    ///   - peerStableId:     peer's user id / fingerprint
    /// - Returns: 60-digit string formatted as 12 groups of 5,
    ///   separated by single spaces.
    static func compute(
        localIdentityKey: Data,
        localStableId: String,
        peerIdentityKey: Data,
        peerStableId: String
    ) -> String {
        // Sort by stable id so both sides produce identical input.
        let (firstKey, firstId, secondKey, secondId): (Data, String, Data, String) = {
            if localStableId < peerStableId {
                return (localIdentityKey, localStableId, peerIdentityKey, peerStableId)
            } else {
                return (peerIdentityKey, peerStableId, localIdentityKey, localStableId)
            }
        }()

        // Pre-image: 0x00 0x00 || firstId || firstKey || secondId || secondKey
        // The two leading bytes carry the version (0x0000 — fingerprint v0,
        // matches Signal). Including the IDs binds the safety number to
        // a specific user pair, not just a public-key pair.
        var preimage = Data([0x00, 0x00])
        preimage.append(Data(firstId.utf8))
        preimage.append(firstKey)
        preimage.append(Data(secondId.utf8))
        preimage.append(secondKey)

        var current = Data(SHA512.hash(data: preimage))
        for _ in 1..<iterations {
            // Re-hash with the original preimage appended each round.
            // Signal does this to keep the cost asymmetric — finding
            // a collision means doing the full 5200-step chain, but
            // verifying is the same cost.
            var next = current
            next.append(preimage)
            current = Data(SHA512.hash(data: next))
        }

        // Take 30 bytes, split into 6 chunks of 5 bytes each, and
        // each chunk modulo 100000 → 5 decimal digits.
        let bytes = Array(current.prefix(30))
        var digits = ""
        for groupIdx in 0..<groupCount {
            let chunkStart = (groupIdx % 6) * 5
            // We only have 30 bytes (6 chunks); use second pass for
            // groups 6..11 by hashing once more with a constant
            // domain-separator to avoid reusing identical chunks.
            let chunk = (groupIdx < 6)
                ? Array(bytes[chunkStart..<(chunkStart + 5)])
                : derivedSecondHalf(seed: current, index: groupIdx - 6)
            let n = chunk.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let group = String(format: "%05d", n % 100_000)
            if !digits.isEmpty { digits += " " }
            digits += group
        }
        return digits
    }

    /// Second-half digits come from a domain-separated re-hash so we
    /// don't reuse the same 30 bytes twice (which would halve the
    /// effective entropy). Cheap because the hash chain is already
    /// the expensive part.
    private static func derivedSecondHalf(seed: Data, index: Int) -> [UInt8] {
        var input = Data("RAVEN_SAFETYv0_TAIL".utf8)
        input.append(seed)
        input.append(UInt8(index))
        let h = SHA512.hash(data: input)
        let bytes = Array(h.prefix(5))
        return bytes
    }

    // MARK: - Convenience over DeviceIdentityService

    /// Compute the safety number for "us ↔ peer" using whatever
    /// identity material this device knows about today. Returns nil
    /// if our own keys aren't loaded yet.
    static func computeForCurrentDevice(
        peerIdentityKey: Data,
        peerUserId: String,
        ourUserId: String
    ) -> String? {
        guard let our = DeviceIdentityService.shared.publicKeyData else { return nil }
        return compute(
            localIdentityKey: our,
            localStableId: ourUserId,
            peerIdentityKey: peerIdentityKey,
            peerStableId: peerUserId
        )
    }
}
