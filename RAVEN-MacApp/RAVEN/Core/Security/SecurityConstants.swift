// SecurityConstants.swift
//
// Single-source-of-truth for mesh security parameters — KDF domain labels,
// session quotas, cover-traffic timing, Phase E feature flags.
//
// Every constant here exists for a reason documented inline; do NOT hardcode
// equivalent strings or numbers elsewhere. Audit trail lives in
// `docs/RUM_V2_ROADMAP.md` §E and `docs/MESH_SECURITY_AUDIT.md`.
//
// BYTE-IDENTICAL sibling on Mac at
// `RAVEN-MacApp/RAVEN/Core/Security/SecurityConstants.swift` — both files
// must be edited together or the engines will disagree at runtime about
// what label bytes go into HKDF and produce silently-incompatible session
// keys.

import Foundation

/// Mesh-network security parameters. All static — no instances.
enum SecurityConstants {

    // MARK: - KDF domain-separation labels (Phase E.5)
    //
    // Every HKDF (and HKDF-Expand-Label) call in the codebase MUST cite a
    // label from this enum. Two reasons:
    //
    //   1. **Cryptographic hygiene** — domain separation guarantees that a
    //      key derived for purpose X cannot collide with one for purpose Y
    //      even if the inputs happen to overlap. This is a free defence
    //      against accidental key reuse in future code changes.
    //
    //   2. **Type-system enforcement** — `KDFLabel` is a non-`String`
    //      type, so callers can't pass an arbitrary string by mistake.
    //      A reviewer who sees `HKDF(..., label: .transportSend)` knows at
    //      a glance which purpose the derived key serves.
    //
    // To add a new purpose: add a case here + the literal byte string.
    // Never reuse an existing case. Never re-label an existing case — that
    // would silently invalidate every session derived under the old name.

    /// Strongly-typed HKDF "info" string. Wraps a stable byte sequence so
    /// the compiler treats this distinct from `String` and callers can't
    /// pass an arbitrary literal. The raw bytes are what the underlying
    /// HKDF call uses — comparing the two strings should be exact.
    struct KDFLabel: RawRepresentable, Hashable, Sendable {
        let rawValue: String
        var bytes: Data { Data(rawValue.utf8) }

        init(rawValue: String) { self.rawValue = rawValue }

        // ── Noise IK handshake (C.1) ──────────────────────────────────
        /// Root chaining-key derivation right after the handshake completes.
        static let handshakeRoot     = KDFLabel(rawValue: "RAVEN.v2.handshake.root")
        /// Initiator → responder transport-mode AEAD key.
        static let transportSend     = KDFLabel(rawValue: "RAVEN.v2.transport.send")
        /// Responder → initiator transport-mode AEAD key.
        static let transportRecv     = KDFLabel(rawValue: "RAVEN.v2.transport.recv")

        // ── Rotating peer-ID derivation (Phase E.4, v3 envelope) ──────
        /// Per-session "session ID" — stable for the lifetime of one Noise
        /// session, never repeats across sessions.
        static let peerIdSession     = KDFLabel(rawValue: "RAVEN.v3.peer-id-session")
        /// Per-message rotating sender ID. Concatenated with the message
        /// counter to give each message a fresh 16-byte pseudonym.
        static let peerIdSender      = KDFLabel(rawValue: "RAVEN.v3.sender-id")
        /// Per-message rotating destination ID. Same construction as
        /// `peerIdSender` but distinct so a sniffer can't link the two
        /// halves of a (sender, dest) pair across messages.
        static let peerIdDest        = KDFLabel(rawValue: "RAVEN.v3.dest-id")

        // ── Bridge / server interop ───────────────────────────────────
        /// Server-bridge authentication key derived from the user's static
        /// Noise key + a server-issued nonce. Lets the server prove it
        /// reached the right account without holding the static key.
        static let bridgeAuth        = KDFLabel(rawValue: "RAVEN.v2.bridge.auth")

        // ── Group sender keys ─────────────────────────────────────────
        /// Sender-side group AEAD key, rotates on membership change.
        static let groupSender       = KDFLabel(rawValue: "RAVEN.v2.group.sender")
        /// Receiver-side group AEAD key (same root, different direction
        /// label so a compromised sender key can't decrypt the
        /// receiver's outgoing-key-equivalent path).
        static let groupReceiver     = KDFLabel(rawValue: "RAVEN.v2.group.receiver")

        // ── Hop-by-hop MAC chain (Phase E.2, v3 envelope) ─────────────
        /// HMAC key each relay uses to tag the envelope with its identity.
        static let hopMacChain       = KDFLabel(rawValue: "RAVEN.v3.hop-mac")

        // ── Post-quantum hybrid (C.4) ─────────────────────────────────
        /// Hybrid chaining-key derivation that mixes classical X25519 +
        /// ML-KEM-768 outputs. Distinct label so a hybrid-mode session
        /// key can never collide with a classical-only one even if both
        /// run with the same static key material.
        static let pqHandshakeRoot   = KDFLabel(rawValue: "RAVEN.v3.pq.handshake.root")

        // ── Double Ratchet (Phase F) ──────────────────────────────────
        /// Root-chain KDF — mixes the previous root key with each new
        /// DH-ratchet output to derive `(new_root_key, new_chain_key)`.
        /// Distinct label so the root chain can never collide with any
        /// per-message chain key even if HKDF inputs accidentally agree.
        static let doubleRatchetRoot    = KDFLabel(rawValue: "RAVEN.v4.dr.root")
        /// Per-message chain KDF — drives the symmetric ratchet WITHIN
        /// a DH epoch. Two HMAC tags: one becomes the next chain key,
        /// the other becomes the message key.
        static let doubleRatchetChain   = KDFLabel(rawValue: "RAVEN.v4.dr.chain")
        /// Per-message AEAD key derived from the chain output. Separate
        /// label so an attacker who somehow learns one chain output
        /// (e.g. via implementation bug) can't trivially recover the
        /// AEAD key without breaking the second HKDF.
        static let doubleRatchetMessage = KDFLabel(rawValue: "RAVEN.v4.dr.message")
        /// Future: encrypted-header variant — derives a key used to
        /// encrypt the DR header itself so passive observers can't
        /// read DH pubkey + message number. Reserved label; not
        /// emitted today.
        static let doubleRatchetHeader  = KDFLabel(rawValue: "RAVEN.v4.dr.header")
    }

    // MARK: - Phase E feature flags

    /// **E.1** Emit cover-traffic frames on idle (Poisson-distributed,
    /// see `Cover.lambdaPerSecond`). Off by default — flip after field
    /// test confirms it doesn't degrade real-frame latency under
    /// contention. Engines also need
    /// `Capabilities.coverTraffic` advertised when this is true.
    static let coverTrafficEnabled: Bool = false

    /// **E.2** Produce + verify the hop-by-hop HMAC chain. Requires v3
    /// envelope negotiation; both peers must advertise
    /// `Capabilities.hopAuth`. Off until the v3 wire format rolls out.
    static let hopAuthEnabled: Bool = false

    /// **E.3** Bind a monotonic counter into the Noise transport AEAD's
    /// associated data. Independently togglable from `hopAuthEnabled`
    /// because it's invisible on the wire (no v3 break).
    static let monotonicCounterEnabled: Bool = false

    /// **E.4** Derive rotating pseudonymous peer IDs per message.
    /// Requires v3 envelope + `Capabilities.rotatingPeerId` on both
    /// sides. Off until v3 rolls out.
    static let rotatingPeerIdEnabled: Bool = false

    /// **E.6** Auto-rotate Noise sessions on the quotas below.
    /// Independent of the wire format — purely engine-internal.
    /// Off-by-default while we measure overhead.
    static let sessionRotationEnabled: Bool = false

    /// **F** Double Ratchet for transport-mode encryption. When `true`,
    /// engines bootstrap a ``DoubleRatchet`` from each completed Noise IK
    /// `split()` and route message traffic through it instead of the
    /// raw ``NoiseCipherState``. Off-by-default until field test shows
    /// the per-message DH ratchet doesn't blow the BLE 5 ms-per-frame
    /// budget on older devices.
    static let doubleRatchetEnabled: Bool = false

    // MARK: - Double Ratchet parameters (Phase F)

    enum DoubleRatchet {
        /// Maximum out-of-order messages we'll cache message keys for
        /// before refusing further skip-ahead. Bounds memory at
        /// roughly 32 B × this many keys per session. Matches Signal's
        /// reference recommendation of 1000.
        static let maxSkipKeys: Int = 1_000

        /// Hard ceiling on skip distance per receive call. Defeats a
        /// peer who advertises N = 10^9 to make us derive a billion
        /// keys. 100 keys ≈ 100 ms of work on an A17, still bounded.
        static let maxSkipPerReceive: Int = 100

        /// Length of the DR header on the wire, in bytes:
        ///   32 B DH ratchet public key
        ///    4 B PN — previous-chain length (big-endian uint32)
        ///    4 B  N — message number       (big-endian uint32)
        /// Receivers parse the first 40 bytes of the envelope payload
        /// as the header before pulling out the AEAD ciphertext.
        static let headerSize: Int = 40
    }

    // MARK: - Session forward-secrecy quotas (Phase E.6)

    enum Session {
        /// Max transport messages per session before forcing a fresh
        /// handshake. Caps the blast radius of a stolen session key —
        /// at 100k messages even a fully-compromised key can only
        /// decrypt that bounded window.
        static let maxMessages: UInt64 = 100_000

        /// Max wall-clock age of a session before forced rotation.
        /// 7 days = long enough that re-handshakes don't churn battery,
        /// short enough that yesterday's compromised key isn't useful
        /// next week.
        static let maxAge: TimeInterval = 7 * 24 * 60 * 60

        /// On exact `maxMessages` value, the next encrypt MUST kick off
        /// a fresh handshake. Setting this guard before the AEAD nonce
        /// space exhausts keeps us nowhere near the ChaCha20-Poly1305
        /// 2^64 nonce limit but the principle is the same.
        static let hardLimitMessages: UInt64 = 1_000_000
    }

    // MARK: - Cover-traffic timing (Phase E.1)

    enum Cover {
        /// Average idle interval before a cover frame is scheduled.
        /// Poisson process so individual gaps are exponentially
        /// distributed — a passive observer can't predict the next
        /// emission window.
        static let lambdaPerSecond: Double = 1.0 / 90.0

        /// Engine considers itself "idle" if no real frame has been
        /// sent in this many seconds. Below this, no cover frame
        /// scheduling — we ride on the back of real traffic patterns.
        static let idleThresholdSeconds: TimeInterval = 60

        /// Cover-payload size after Noise IK encryption (padded to
        /// nearest bucket in `RUMProtocolV2.paddingTargets`).
        /// 256 B matches the smallest bucket so cover frames look
        /// like short text messages by default.
        static let payloadBucketBytes: Int = 256
    }

    // MARK: - Replay enforcement (Phase E.3)

    enum Replay {
        /// Max delta between received `monotonic_counter` and our
        /// `last_seen` before we treat it as a long-window replay.
        /// 4096 = generous enough to tolerate burst reordering on
        /// lossy BLE links, tight enough that an attacker can't
        /// quietly buffer ~1 GB of frames.
        static let acceptableJumpAhead: UInt64 = 4_096

        /// Sliding bitmap window for out-of-order acceptance, in
        /// number of message slots tracked. Matches IPsec's
        /// anti-replay default. RFC 6479 style.
        static let bitmapWindowSize: Int = 1024
    }
}
