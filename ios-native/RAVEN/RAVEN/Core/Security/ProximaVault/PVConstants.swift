//
//  PVConstants.swift
//  RAVEN — PROXIMA-VAULT (PV) v3.1.2
//
//  Single-source-of-truth for PROXIMA-VAULT crypto parameters.
//
//  PROXIMA-VAULT is a CONTENT-LAYER primitive: it produces an opaque
//  ciphertext blob that the existing transport layers (Noise IK
//  online, mesh relay envelopes, internet-bridge tunnels) carry as
//  payload. PV does not replace transport encryption — it stacks on
//  top so the user has BOTH information-theoretic content secrecy
//  AND computational transport secrecy.
//
//  ⚠️  Scope reminder (from spec freeze):
//      PV v3.1.2 protects **message content**, not metadata. The
//      header carries a public `pad_id` and stable per-pad
//      pseudonyms, which a passive observer can correlate. Metadata
//      unlinkability is deferred to PV-Stealth (v3.2).
//
//  Every constant in this file exists for a reason documented
//  inline. Adding a new constant: append, never reuse a slot.
//  Editing a label string: NEVER. That silently breaks every pad
//  derived under the old label and decrypts will fail.
//
//  Sibling on Mac at
//  `RAVEN-MacApp/RAVEN/Core/Security/ProximaVault/PVConstants.swift`
//  must stay byte-identical or the two engines disagree about which
//  pad-bytes feed which key slot.
//

import Foundation

/// PROXIMA-VAULT crypto parameters. All static — no instances.
enum PVConstants {

    // MARK: - Wire-format version

    /// Magic bytes (4 ASCII) prepended to every PV envelope. Lets a
    /// receiver recognise PV ciphertext WITHOUT having to attempt
    /// decryption first, and gives the build-time guarantee that any
    /// future incompatible format change forces a new magic.
    static let envelopeMagic: [UInt8] = [0x50, 0x56, 0x33, 0x31]  // "PV31"

    /// Format version byte, written immediately after the magic.
    /// Bumped only for a format-breaking change. v3.1.2 spec → 0x12.
    /// Receivers reject any unknown version rather than guessing.
    static let formatVersion: UInt8 = 0x12

    // MARK: - Sizes (bytes)

    /// Length of the public pad identifier surfaced in every
    /// envelope header. 16 bytes = 128-bit random ID, collision
    /// probability negligible across a single user's pad collection.
    /// NOT a secret — observers see this and can correlate envelopes
    /// from the same pad (metadata limitation acknowledged).
    static let padIdBytes: Int = 16

    /// Length of the pad-local sender/receiver pseudonym in every
    /// header. Stable for the pad's lifetime, derived from pad
    /// material (NOT from any pubkey hash — Patch 8). Distinct per
    /// pad, so two pads to the same physical device produce two
    /// uncorrelated pseudonyms.
    static let pseudonymBytes: Int = 16

    /// Width of the per-direction message counter on the wire.
    /// `UInt32` big-endian. Pad is forced into end-of-life at
    /// `0xFFFFFFFF` (Patch 4) — receiver also enforces this ceiling.
    static let counterBytes: Int = 4

    /// AEAD nonce length used by the chunk cipher when running in
    /// AES-GCM-SIV (or, fallback, AES-GCM). 12 bytes is the IETF
    /// standard; SIV mode also accepts longer nonces but 12 keeps
    /// the wire format compact.
    static let aeadNonceBytes: Int = 12

    /// Authenticator tag length. 16 bytes (128 bits) — matches
    /// AES-GCM-SIV's tag width and gives 2⁻¹²⁸ forgery probability
    /// per chunk regardless of message length (Theorem 2 bound).
    static let macTagBytes: Int = 16

    /// Width of the universal-hash key (GHASH H) sampled per
    /// message from pad bytes. 16 bytes / 128 bits — gives the
    /// GHASH ε = ℓ/2¹²⁸ universal-hash bound, identical to TLS 1.3
    /// AES-GCM. NEVER reused across messages (one-time key).
    static let universalHashKeyBytes: Int = 16

    /// Mode-bit field on the envelope header, AAD-bound (Patch 1
    /// fix: prevents an attacker from downgrading AES-GCM-SIV → raw
    /// XOR by flipping a header bit unauthenticated). 1 byte:
    ///   0x00 = info-theoretic XOR + Wegman-Carter
    ///   0x01 = AES-GCM-SIV chunk cipher (computational, faster)
    /// Mixed-mode envelopes are not permitted.
    static let modeByteSize: Int = 1

    /// Direction byte in the AAD. 0x01 = sender→receiver in canonical
    /// "low pubkey hash" ordering; 0x02 = the reverse. NEVER lets
    /// a passive observer guess physical-device direction because
    /// the canonical order is derived from a pad-local pseudonym
    /// rather than the real pubkey hash (Patch 8).
    static let directionByteSize: Int = 1

    // MARK: - Pad layout
    //
    // All "per-direction" sizes are doubled inside the pad blob (one
    // copy for A→B, one for B→A). Total pad-on-disk size is therefore
    //   2 · (cipher + macKeys + tagMask + aeadNonce + lookupKeys + pseudonym)
    // = 2 · (1 MiB + 1 MiB + 1 MiB + 768 KiB + 32 + 16)
    // ≈ 7.5 MiB
    // Comfortable for Keychain-wrapped storage with biometric gating.
    //
    // The cipher/macKeys/tagMask/aeadNonce ranges together cap the
    // pad at ~65 k messages per direction (16 B per K_wc strip
    // ⇒ 1 MiB / 16 = 65 536 messages). Pad EOL fires at that limit
    // and the UI surfaces "re-provision".
    //
    // Future tuning: bump these once we have field telemetry on
    // real message rates. Numbers chosen for v1.0 reference are
    // deliberately conservative.

    /// Per-direction one-time-pad keystream (the "cipher pad").
    /// 1 MiB → average message length 16 B × 65 k messages.
    /// Long-form posts spend more here and may reduce effective
    /// message count; that's an accepted trade-off.
    static let padCipherBytesPerDirection: Int = 1_048_576

    /// Per-direction Wegman-Carter universal-hash key strips
    /// (16 B per message). 1 MiB ⇒ 65 536 K_wc strips.
    static let padMacKeysBytesPerDirection: Int = 1_048_576

    /// Per-direction per-message tag-XOR mask (16 B per message).
    /// 1 MiB ⇒ 65 536 tag masks, parallel to MAC keys.
    static let padTagMaskBytesPerDirection: Int = 1_048_576

    /// Per-direction per-message AES-GCM-SIV nonce strip
    /// (12 B per message). 768 KiB ⇒ 65 536 nonces. Only
    /// consumed in `.aesGcmSIV` mode; in `.infoTheoretic` mode
    /// these bytes are skipped over (the cursor still advances
    /// for cross-mode predictability).
    static let padAeadNonceBytesPerDirection: Int = 786_432

    /// Per-pad message budget. Computed from the smallest
    /// non-cipher range so any single direction can fully spend
    /// without one range running out before the others.
    /// 1 048 576 / 16 = 65 536 — keep in sync if you change
    /// `padMacKeysBytesPerDirection`.
    static let perDirectionMessageBudget: UInt32 = 65_536

    /// Bytes reserved for `K_lookup_{A→B}` and `K_lookup_{B→A}`,
    /// used by PV-Stealth (v3.2) to build rotating `lookup_tag`s.
    /// Reserved space here in v3.1.2 so v3.2 can roll out without
    /// re-provisioning pads — receivers running v3.1.2 simply ignore
    /// these bytes today.
    static let padLookupKeysBytesPerDirection: Int = 32

    /// Per-pad fixed pseudonym bytes (one slot per direction). Drawn
    /// once at pad-provision time and stable for the pad's
    /// lifetime. v3.2 PV-Stealth replaces the on-wire pseudonym
    /// with `lookup_tag`, leaving these slots dormant.
    static let padPseudonymBytesPerDirection: Int = 16

    // MARK: - Counters

    /// Hard end-of-life ceiling for the per-direction message
    /// counter. UInt32 max — once a direction's counter reaches
    /// this value, the pad refuses further encrypts in that
    /// direction and surfaces a "pad-exhausted" error to the UI
    /// (Patch 4). The peer must re-provision.
    static let counterEndOfLife: UInt32 = 0xFFFFFFFF

    /// Replay window for receiving direction-counter values. Larger
    /// than the BLE re-order window (4096, see SecurityConstants)
    /// because PV envelopes can arrive across multiple transports
    /// with different latency characteristics. 16 k slots is
    /// generous but bounded.
    static let replayWindowSize: Int = 16_384

    // MARK: - Modes

    /// Encryption mode selection — sender-chosen, AAD-bound, MUST
    /// match between sender and receiver or auth tag verification
    /// fails (Patch 1).
    enum Mode: UInt8, Codable, Sendable {
        /// True information-theoretic: chunk cipher is pure XOR
        /// with pad bytes; MAC is Wegman-Carter (GHASH polynomial
        /// hashed by K_wc, output masked by pad tag-strip).
        /// Pad-byte cost: |M| + 32 B (16 K_wc + 16 tag mask) +
        /// 4 B counter + 12 B placeholder nonce per message.
        case infoTheoretic = 0x00

        /// AES-GCM-SIV chunk cipher (Patch 7 — nonce-misuse-resistant)
        /// keyed by 32 B drawn from pad. MAC is still Wegman-Carter
        /// (we don't reuse AES-GCM-SIV's built-in tag because that
        /// would weaken our auth guarantee to AES-PRF-strength).
        /// Faster on iPhone (hardware AES) but loses the pure
        /// info-theoretic confidentiality guarantee.
        case aesGcmSIV     = 0x01

        /// Human label for debug overlays.
        var label: String {
            switch self {
            case .infoTheoretic: return "info-theoretic"
            case .aesGcmSIV:     return "AES-GCM-SIV"
            }
        }
    }

    // MARK: - KDF labels — pad → byte-range derivation

    /// Strongly-typed pad-range identifier. Each label maps to a
    /// distinct, non-overlapping byte range within the pad so two
    /// purposes can never accidentally consume the same pad bytes.
    /// Adding a new range: append, never overlap, never re-order
    /// existing labels (re-ordering = silent ciphertext invalidation
    /// across the entire pad universe).
    struct PVPadLabel: RawRepresentable, Hashable, Sendable {
        let rawValue: String
        var bytes: Data { Data(rawValue.utf8) }
        init(rawValue: String) { self.rawValue = rawValue }

        /// A→B cipher keystream (cipherPad).
        static let cipherForwardLabel  = PVPadLabel(rawValue: "PV.v3.1.2.cipher.A->B")
        /// B→A cipher keystream.
        static let cipherReverseLabel  = PVPadLabel(rawValue: "PV.v3.1.2.cipher.B->A")

        /// A→B Wegman-Carter universal-hash key strips.
        static let kwcForwardLabel     = PVPadLabel(rawValue: "PV.v3.1.2.kwc.A->B")
        /// B→A Wegman-Carter universal-hash key strips.
        static let kwcReverseLabel     = PVPadLabel(rawValue: "PV.v3.1.2.kwc.B->A")

        /// A→B per-message tag-XOR mask.
        static let tagMaskForwardLabel = PVPadLabel(rawValue: "PV.v3.1.2.tag.A->B")
        /// B→A per-message tag-XOR mask.
        static let tagMaskReverseLabel = PVPadLabel(rawValue: "PV.v3.1.2.tag.B->A")

        /// A→B AES-GCM-SIV nonce sequence (only used in `.aesGcmSIV`).
        static let aeadNonceForwardLabel = PVPadLabel(rawValue: "PV.v3.1.2.nonce.A->B")
        /// B→A AES-GCM-SIV nonce sequence.
        static let aeadNonceReverseLabel = PVPadLabel(rawValue: "PV.v3.1.2.nonce.B->A")

        /// Reserved for PV-Stealth (v3.2) — A→B lookup-tag derivation key.
        static let lookupForwardLabel  = PVPadLabel(rawValue: "PV.v3.2.lookup.A->B")
        /// Reserved for PV-Stealth (v3.2) — B→A lookup-tag derivation key.
        static let lookupReverseLabel  = PVPadLabel(rawValue: "PV.v3.2.lookup.B->A")
    }
}
