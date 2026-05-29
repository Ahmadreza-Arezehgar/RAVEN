//
//  PVStealthConstants.swift
//  RAVEN — PROXIMA-VAULT Stealth (ATSAM Stage 9)
//
//  PV-Stealth is the metadata-unlinkability profile that sits ON
//  TOP OF PV v3.1.2. The body crypto (cipher pad XOR + Wegman-Carter
//  MAC) is unchanged. What changes is the PUBLIC HEADER:
//
//      PV v3.1.2 (PV-Standard):
//        pad_id (16 B, stable per pad)
//        sender_pseudo (16 B, stable per pad)
//        receiver_pseudo (16 B, stable per pad)
//
//      PV-Stealth (this module):
//        lookup_nonce  (16 B, fresh per envelope)
//        lookup_tag    (16 B, = Trunc_128(HMAC(K_lookup^dir,
//                                              label || lookup_nonce || counter)))
//
//  Why this matters:
//    PV-Standard exposes stable `pad_id` + per-pad pseudonyms on
//    every envelope. A passive observer can correlate envelopes
//    belonging to the same pad / device pair (Issue 10 / Patch 10
//    of the PV v3.1.2 review). PV-Stealth replaces those stable
//    identifiers with a per-envelope rotating tag.
//
//    Receiver cost: O(active_pads × counter_window) HMACs per
//    inbound envelope. With 20 pads × 32 window × 3 µs HMAC ≈
//    1.92 ms per envelope on A17. Acceptable.
//
//  K_lookup is the sub-key tree branch reserved in ATSAM Stage 1:
//      ATSAMConstants.KDFLabel.pvStealthLookup
//        → ATSAMKeyTree.pvStealthLookupKey  (32 bytes)
//
//  We derive per-direction sub-keys from this parent via HKDF:
//      K_lookup^{A→B} = HKDF(K_lookup, "PV-Stealth.dir.A->B", 32)
//      K_lookup^{B→A} = HKDF(K_lookup, "PV-Stealth.dir.B->A", 32)
//
//  Reference: ATSAM PDF §22 (PV-Stealth Rotating Lookup Tags),
//  Patch 10 of the PV v3.1.2 review.
//

import Foundation

enum PVStealthConstants {

    // MARK: - Wire format

    /// Magic bytes (4 ASCII) prepended to every PV-Stealth envelope.
    /// Lets a receiver distinguish PV-Stealth from PV-Standard
    /// envelopes without trying to parse both.
    static let envelopeMagic: [UInt8] = [0x50, 0x56, 0x53, 0x54]  // "PVST"

    /// Format version byte. Bumped only for a format-breaking change.
    /// v3.2 spec → 0x12.
    static let formatVersion: UInt8 = 0x12

    // MARK: - Sizes (bytes)

    /// Lookup nonce length. 16 bytes / 128 bits. Fresh per envelope.
    /// Carried publicly so the receiver can recompute the expected
    /// tag.
    static let lookupNonceBytes: Int = 16

    /// Lookup tag length. 16 bytes / 128 bits — Trunc_128 of
    /// HMAC-SHA256 output. Collision probability ≤ M × 2⁻¹²⁸
    /// per envelope where M = active pad count on the receiver,
    /// astronomically low.
    static let lookupTagBytes: Int = 16

    // MARK: - Counter window (receiver-side scan width)

    /// Number of counter values the receiver will try when matching
    /// a stealth envelope to one of its active pads. The window
    /// starts at `cursor.lastSeenCounter + 1` and extends forward.
    /// 32 is generous enough to tolerate burst reordering on a
    /// lossy mesh; tight enough that the receiver scan cost stays
    /// bounded (M × 32 HMACs per envelope).
    static let counterWindowSize: Int = 32

    // MARK: - HMAC input domain

    /// String prepended to every lookup-tag HMAC input. Defeats
    /// cross-protocol confusion (a PV-Stealth tag is
    /// distinguishable from any other HMAC under K_lookup).
    static let lookupTagDomain: Data =
        Data("ATSAM/v1/PV-Stealth/lookup".utf8)

    /// Per-direction sub-key derivation labels. Both ends use the
    /// SAME label for the SAME direction (correctness of the key
    /// tree). The "A→B" / "B→A" naming follows ATSAM PDF §21.
    static let directionLabelForward: Data =
        Data("PV-Stealth.dir.A->B".utf8)
    static let directionLabelReverse: Data =
        Data("PV-Stealth.dir.B->A".utf8)

    // MARK: - Header layout

    /// Header size in bytes:
    ///   4 magic + 1 version + 1 mode + 1 direction + 1 reserved
    ///   + 16 lookup_nonce + 16 lookup_tag
    ///   + 4 counter + 4 cipherOffset
    ///   + 12 aeadNonce (zeros in info-theoretic mode)
    ///   + 4 ciphertextLen
    /// = 64 bytes
    static let headerSize: Int = 64

    /// Minimum legal envelope size (header + zero ciphertext + 16 B tag).
    static let minimumSize: Int = headerSize + 16
}
