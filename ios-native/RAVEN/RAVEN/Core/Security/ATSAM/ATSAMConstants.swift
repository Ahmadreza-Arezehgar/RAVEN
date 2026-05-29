//
//  ATSAMConstants.swift
//  RAVEN — ATSAM (A unified mathematical protocol)
//
//  Single source of truth for ATSAM v1 sizes, version byte, and the
//  KDF label catalog.
//
//  ATSAM is a LAYERING document — it produces a hybrid root key
//  (X25519 + ML-KEM-768) from a pairing transcript, then derives
//  domain-separated sub-keys for every higher layer (BBE discovery,
//  Ghost Handshake, Ghost Route, PV-Stealth lookup, PV pad seed).
//
//  Stage 1 (this file + siblings) provides ONLY the pairing/key-tree
//  layer. Later stages will consume the sub-keys to build BBE,
//  Ghost Handshake, Ghost Route. None of those higher layers exist
//  yet — Stage 1 is intentionally additive and isolated from the
//  rest of the codebase.
//
//  Reference: `ATSAM_Raven_Expanded_30_Page_Mathematical_Protocol.pdf`
//  §7 (HKDF Key Tree) and §8 (Pairing Algorithm).
//
//  Sibling on Mac at
//  `RAVEN-MacApp/RAVEN/Core/Security/ATSAM/ATSAMConstants.swift`
//  must stay byte-identical or the two engines disagree about which
//  label bytes go into HKDF.
//

import Foundation

/// ATSAM v1 protocol parameters. All static — no instances.
enum ATSAMConstants {

    // MARK: - Version

    /// Protocol version byte. Bumped only for a format-breaking
    /// change. v1.0 → 0x01.
    static let formatVersion: UInt8 = 0x01

    /// Cipher-suite selector byte. Reserved for future variants
    /// (e.g. SHA384-based KDF, larger ML-KEM, alternative curves).
    /// v1.0 ships exactly one suite:
    ///   X25519 + ML-KEM-768 + HKDF-SHA256 + Wegman-Carter MAC.
    static let cipherSuite: UInt8 = 0x01

    // MARK: - Output sizes (bytes)

    enum Sizes {
        /// Hybrid root key length. 32 B / 256 bit — matches the
        /// security level of every downstream primitive.
        static let rootKeyBytes: Int = 32

        /// Sub-key length emitted by the HKDF tree. All sub-keys
        /// are 32 B so each downstream layer can use them as
        /// HMAC-SHA256 / AEAD keys directly.
        static let subKeyBytes: Int = 32

        /// X25519 raw shared-secret length. RFC 7748.
        static let x25519SharedBytes: Int = 32

        /// X25519 public-key length.
        static let x25519PublicBytes: Int = 32

        /// X25519 private scalar length.
        static let x25519PrivateBytes: Int = 32

        /// ML-KEM-768 shared-secret length. FIPS 203.
        static let mlKem768SharedBytes: Int = 32

        /// ML-KEM-768 encapsulation-key (public-key) length.
        /// FIPS 203 specifies 1184 bytes.
        static let mlKem768PublicBytes: Int = 1184

        /// ML-KEM-768 decapsulation-key (private-key) length —
        /// **seed form** (`d ‖ z`, 64 bytes).
        ///
        /// FIPS 203 also defines a 2400-byte EXPANDED private-key
        /// form, but Apple's CryptoKit surfaces only the seed and
        /// re-derives the expanded form on every operation. The
        /// seed form is smaller, safer to store (less surface to
        /// keep secret), and what `MLKEM768.PrivateKey.seedRepresentation`
        /// returns. We adopt it as the canonical persistence
        /// format throughout ATSAM.
        static let mlKem768PrivateBytes: Int = 64

        /// ML-KEM-768 ciphertext length. Sent over the OOB channel
        /// once at pair time alongside the X25519 + ML-KEM pubkeys.
        static let mlKem768CiphertextBytes: Int = 1088

        /// Transcript hash output. SHA-256.
        static let transcriptHashBytes: Int = 32
    }

    // MARK: - KDF label catalog (strongly typed)

    /// Strongly-typed HKDF info-string. Wraps a stable byte sequence
    /// so the compiler treats this distinct from `String` and callers
    /// can't pass an arbitrary literal. The raw bytes are what the
    /// underlying HKDF call uses; comparing the two strings should be
    /// exact.
    ///
    /// To add a new purpose: append a `static let` here + the literal
    /// byte string. Never reuse an existing label. Never re-label an
    /// existing case — that would silently invalidate every session
    /// derived under the old name.
    struct KDFLabel: RawRepresentable, Hashable, Sendable {
        let rawValue: String
        var bytes: Data { Data(rawValue.utf8) }

        init(rawValue: String) { self.rawValue = rawValue }

        // ── Pairing root (§8) ──────────────────────────────────────
        /// Info bytes for the initial `HKDF-Extract-then-Expand`
        /// step that produces the 32-byte root key from
        /// `Z_X ‖ Z_PQ`. Concatenated with the transcript hash
        /// when fed to HKDF-Expand.
        static let pairInit  = KDFLabel(rawValue: "ATSAM/v1/pair-init")

        /// Label used for the second-stage root expansion (rare —
        /// most consumers use `pairInit` directly via Extract).
        /// Reserved for a future variant where we split Extract
        /// and Expand into two distinct HKDF calls.
        static let rootExpand = KDFLabel(rawValue: "ATSAM/v1/root")

        // ── BBE / Ghost Beacon (§9–§11) ────────────────────────────
        /// Per-pair BBE discovery key. Used to derive per-epoch slot
        /// IDs in the BBE beacon.
        static let bbeDiscovery   = KDFLabel(rawValue: "ATSAM/v1/BBE/discovery")

        /// BBE ratchet key. Mixed into each epoch's `K_BBE^(t)` so
        /// compromise of one beacon state doesn't reveal earlier ones.
        static let bbeRatchet     = KDFLabel(rawValue: "ATSAM/v1/BBE/ratchet")

        /// Per-pair master key for stable bucket-sort (§11). Drives
        /// the deterministic partition assignment so A and B agree
        /// on which partition holds (A, B) without coordination.
        static let bbePairMaster  = KDFLabel(rawValue: "ATSAM/v1/BBE/pair-master")

        /// HMAC input prefix for the actual slot computation:
        /// `slot = Trunc64(HMAC(K_BBE^(t), "ATSAM/v1/BBE/slot" || t || r))`.
        /// Listed here for code-search; consumed at the BBE-emit layer.
        static let bbeSlot        = KDFLabel(rawValue: "ATSAM/v1/BBE/slot")

        /// HMAC input prefix for sequential-partition sort (§11):
        /// `sort_key = HMAC(pair_master, "ATSAM/v1/BBE/stable-partition-sort")`.
        static let bbeStablePartitionSort = KDFLabel(rawValue: "ATSAM/v1/BBE/stable-partition-sort")

        // ── Ghost Handshake (§15) ──────────────────────────────────
        /// Per-pair live-confirmation key. Drives the challenge-
        /// response MAC that turns a BBE candidate into a verified
        /// live peer.
        static let ghostHandshakeLive = KDFLabel(rawValue: "ATSAM/v1/GhostHandshake/live")

        /// HMAC input prefix for the response itself.
        /// `response = HMAC(K_live, "ATSAM/v1/GhostHandshake/response" || ...)`.
        static let ghostHandshakeResponse = KDFLabel(rawValue: "ATSAM/v1/GhostHandshake/response")

        // ── Ghost Route (§16) ──────────────────────────────────────
        /// Per-pair recipient-tag key. Used to derive unlinkable
        /// per-message tags so mesh relays can't link the same
        /// recipient across messages.
        static let ghostRouteRecipientTag = KDFLabel(rawValue: "ATSAM/v1/GhostRoute/recipient-tag")

        /// HMAC input prefix for the actual recipient-tag computation:
        /// `recipient_tag = Trunc128(HMAC(K_route, "ATSAM/v1/GhostRoute/recipient" || n_msg))`.
        static let ghostRouteRecipient = KDFLabel(rawValue: "ATSAM/v1/GhostRoute/recipient")

        // ── PV-Stealth (§22) ──────────────────────────────────────
        /// Per-pair lookup-tag key (PV-Stealth v3.2). Rotating
        /// lookup tags replace the stable `pad_id` from PV v3.1.2
        /// to close the metadata-linkability gap (Patch 10).
        static let pvStealthLookup = KDFLabel(rawValue: "ATSAM/v1/PV-Stealth/lookup")

        // ── PROXIMA-VAULT seed channel (§18) ───────────────────────
        /// Seed-channel key for PV pad delivery. Used to wrap the
        /// pad-bundle exchange between Secure Enclave-protected
        /// devices. Does NOT replace the pad itself — only the
        /// transport over which the pad travels.
        static let pvSeed = KDFLabel(rawValue: "ATSAM/v1/ProximaVault/seed")
    }

    // MARK: - Pairing-time transcript domain separator

    /// Constant string prepended to the transcript byte sequence
    /// before SHA-256. Defeats any cross-protocol confusion where
    /// a Noise-IK transcript could be replayed into ATSAM pairing.
    static let transcriptDomain: Data =
        Data("ATSAM/v1/transcript".utf8)
}
