//
//  BBEConstants.swift
//  RAVEN — BBE (Bilateral Beacon Encryption / Ghost Beacon)
//
//  Stage 2 of ATSAM. BBE is the private-discovery layer: a paired
//  device recognises that a friend may be nearby without
//  broadcasting a username, phone number, stable public key, or
//  social-graph identifier. To a stranger, every BBE beacon is
//  indistinguishable from uniform random bytes.
//
//  This file is the single source of truth for BBE wire-format
//  sizes, slot counts, epoch duration, and the catch-up window.
//  Reference: ATSAM PDF §9 (BBE / Ghost Beacon), §10 (Epoch &
//  Catch-Up), §11 (Partitioning).
//
//  Architectural reminder: BBE is a *content-of-a-beacon*
//  primitive. The actual transmission (BLE AUX_ADV_IND, Wi-Fi
//  Aware service info) is wired by `BLEMeshEngine` /
//  `WiFiAwareTransport` in Stage 3. Stage 2 ships pure data
//  primitives only — encrypt the beacon bytes, decrypt them, no
//  radio touched.
//
//  Sibling on Mac at
//  `RAVEN-MacApp/RAVEN/Core/Security/BBE/BBEConstants.swift`
//  must stay byte-identical or the two engines emit different
//  slot bits and never see each other.
//

import Foundation

/// BBE protocol parameters. All static — no instances.
enum BBEConstants {

    // MARK: - Wire format

    /// Magic bytes (4 ASCII) prepended to every BBE beacon on the
    /// wire. Lets a receiver recognise a beacon WITHOUT having to
    /// attempt HMAC on every random radio frame.
    static let beaconMagic: [UInt8] = [0x42, 0x42, 0x45, 0x31]  // "BBE1"

    /// Beacon format version. Bumped only for a format-breaking
    /// change. v3.1 spec → 0x31.
    static let beaconVersion: UInt8 = 0x31

    // MARK: - Slot parameters

    /// Number of real friend-slots emitted per beacon. 28 was
    /// chosen so the entire beacon (header + slots) fits in a
    /// single BLE 5 AUX_ADV_IND frame (254 B max) without
    /// fragmentation. Real slots count + padding fill the
    /// fixed-size field together.
    static let slotsPerBeacon: Int = 28

    /// Slot ID width on the wire. 64 bits / 8 bytes.
    static let slotBytes: Int = 8

    /// False-positive rate per *single* matched slot per stranger
    /// per beacon: `2^-(slotBytes * 8)` = 2⁻⁶⁴ ≈ 5.4×10⁻²⁰. With
    /// 28 slots tested, the union bound gives ≤ 28·2⁻⁶⁴ ≈ 1.5×10⁻¹⁸
    /// per beacon. False-positive friends are filtered out by
    /// Ghost Handshake (Stage 4) before being surfaced as
    /// verified peers.
    static let perSlotFalsePositiveBitsLog2: Double = 64.0

    // MARK: - Epoch discipline (§10)

    /// Epoch duration in seconds. 300 s = 5 minutes. Both peers
    /// MUST agree on this for slot computation to converge. NEVER
    /// change without a wire-format break.
    static let epochSeconds: TimeInterval = 300.0

    /// Acceptable clock skew window — receivers attempt
    /// detection across epochs `[t-2, t+1]` to handle:
    ///   • t-1 / t-2: queued retransmissions on a lossy mesh
    ///   • t+1: a peer whose clock drifted forward by < 5 min
    ///
    /// Per minor-fix m2 of the v3.1 review (PDF accepts
    /// `[t-1, t+1]`; we extend to `[t-2, t+1]` because mesh
    /// re-transmission windows realistically span 10 min).
    static let clockSkewWindowPast: Int = 2
    static let clockSkewWindowFuture: Int = 1

    // MARK: - Ratchet / catch-up (§10)

    /// Number of past ratchet states to keep cached so a peer
    /// who falls behind by up to `catchUpWindow` epochs can still
    /// be detected. 12 epochs × 5 min = 1 hour of offline tolerance.
    ///
    /// Memory cost: 12 states × 32 B per pairing = 384 B per
    /// pairing. At 1000 pairings = 384 KB. Acceptable.
    static let catchUpWindow: Int = 12

    /// Absolute ceiling on catch-up. Beyond this, the cursor MUST
    /// trigger an OOB re-pair flow rather than expanding the
    /// cache indefinitely (cache-poisoning resistance).
    static let catchUpMax: Int = 288  // 24 hours at 5-min epochs

    // MARK: - Nonce

    /// Per-beacon random nonce length. 16 bytes / 128 bits — fed
    /// into the slot HMAC alongside the epoch counter so the same
    /// (pair, epoch) tuple emits a different slot value on every
    /// beacon. Collision-resistant against a global passive
    /// observer.
    static let beaconNonceBytes: Int = 16

    // MARK: - Beacon size

    /// Total beacon size on the wire (header + nonce + slot field):
    ///   4 (magic) + 1 (version) + 4 (epoch t big-endian)
    ///                       + 16 (nonce) + 28 × 8 (slots)
    /// = 4 + 1 + 4 + 16 + 224 = 249 bytes.
    /// Within the 254-byte BLE 5 AUX_ADV_IND payload limit.
    static let beaconTotalBytes: Int = 249

    /// Offset within the beacon where the slot field begins.
    /// Useful for direct-slice access during detect.
    static let slotsOffset: Int = 4 + 1 + 4 + beaconNonceBytes  // 25

    // MARK: - KDF labels (delegated to ATSAM)

    /// String used as HMAC input prefix during slot computation:
    /// `slot_AB(t, r) = Trunc64(HMAC(K_BBE^(t), slotLabel || t || r))`.
    /// Listed here as a literal rather than reusing the
    /// `ATSAMConstants.KDFLabel.bbeSlot` value because slot
    /// computation is on the hot path — the literal compiles to
    /// a single static byte sequence with no struct unwrapping.
    static let slotLabel: Data = Data("BBE-slot".utf8)

    /// HMAC input prefix used by the ratchet step:
    /// `K_BBE^(t+1) = HKDF(K_BBE^(t), ratchetLabel || uint32(t+1))`.
    static let ratchetInfo: Data = Data("ATSAM/BBE/ratchet".utf8)
}
