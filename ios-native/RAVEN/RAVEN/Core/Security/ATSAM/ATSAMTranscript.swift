//
//  ATSAMTranscript.swift
//  RAVEN — ATSAM
//
//  Pairing-time transcript binding. Every byte that contributes to
//  trust during pairing is concatenated, prefixed with a domain
//  separator, and hashed with SHA-256 → the resulting 32-byte digest
//  is folded into the HKDF salt for the root-key derivation.
//
//  Why this matters:
//    • Defeats cross-protocol confusion (a Noise-IK transcript
//      can't be replayed as an ATSAM transcript because the
//      domain bytes differ).
//    • Defeats downgrade attacks where an attacker swaps one
//      pubkey mid-handshake — the transcript hash binds the
//      pubkeys that were actually used.
//    • Provides interoperability anchoring: if A and B disagree
//      on any field (protocol version, cipher suite, pubkey
//      bytes, ML-KEM ciphertext, nonces), their roots differ
//      and downstream layers fail-closed.
//
//  Reference: PDF §8 (`transcript = protocol_version || cipher_suites
//  || pk_A^X || pk_B^X || pk_A^PQ || pk_B^PQ || context || nonces`).
//

import Foundation
import CryptoKit

/// Fully-typed pairing transcript. All fields are required (no
/// optionals) so a corrupt caller can't omit a binding by accident.
/// Two `ATSAMTranscript` values are equal iff every byte position
/// agrees.
///
/// 🔴 ROUND 26 (2026-05-16) — hacker-audit Mesh F4 hardening.
/// Two new bindings, both folded into the canonical byte layout:
///   • `userIdInitiator` / `userIdResponder` — UTF-8 user IDs of
///     both sides. Defeats a confused-deputy / cross-pair replay
///     where the same pubkeys are reused across distinct (alice,
///     bob) and (alice, charlie) pairings — distinct userId bytes
///     produce distinct transcript hashes → distinct root keys.
///   • `hybridRequired` — when 1, both peers refuse non-hybrid
///     fallback EVEN IF their pairing-layer caller passed
///     `allowNonHybridFallback: true`. The bit is bound into the
///     transcript, so a MITM stripping the bit causes the
///     transcripts to diverge → root mismatch → ATSAM session
///     fails to come up.
struct ATSAMTranscript: Sendable, Equatable, Hashable {

    /// Protocol version byte. MUST equal `ATSAMConstants.formatVersion`
    /// for a v1 build.
    let protocolVersion: UInt8

    /// Cipher-suite selector. MUST equal `ATSAMConstants.cipherSuite`
    /// for a v1 build.
    let cipherSuite: UInt8

    /// Initiator's X25519 static public key. 32 bytes.
    let pkAX: Data

    /// Responder's X25519 static public key. 32 bytes.
    let pkBX: Data

    /// Initiator's ML-KEM-768 encapsulation key (public key).
    /// 1184 bytes. Empty `Data(count: 0)` if running a degraded
    /// non-hybrid mode (NOT recommended; emits a warning at the
    /// pairing layer).
    let pkAPQ: Data

    /// Responder's ML-KEM-768 encapsulation key.
    let pkBPQ: Data

    /// ML-KEM-768 ciphertext bytes exchanged during pairing
    /// (initiator's encapsulation toward responder). 1088 bytes.
    /// Empty when running non-hybrid.
    let ctPQ: Data

    /// Application-defined context bytes. Bound into the transcript
    /// so distinct deployment contexts (e.g. main app vs Mac
    /// companion app) cannot share a root key even with identical
    /// pubkeys.
    let context: Data

    /// 32 bytes of pairing-session randomness. Initiator-chosen,
    /// sent over OOB. Defeats long-term-key-only correlation:
    /// even if two devices pair, un-pair, and re-pair with the same
    /// static keys, the second pairing's root differs from the
    /// first.
    let pairingNonce: Data

    /// 🔴 ROUND 26 — initiator's RAVEN userId (UTF-8). Bound into
    /// the transcript so a (pubkey, userId) tuple swap mid-pair
    /// invalidates the root. Empty `Data()` only for the pre-round-
    /// 26 back-compat path in the test suite — all production
    /// callers MUST supply the real userId.
    let userIdInitiator: Data

    /// 🔴 ROUND 26 — responder's RAVEN userId (UTF-8).
    let userIdResponder: Data

    /// 🔴 ROUND 26 — hybrid-required policy bit. When 1, both
    /// peers MUST run PQ. Bound into the transcript so the bit
    /// itself is integrity-protected; the pairing layer also
    /// enforces it at the policy gate.
    let hybridRequired: UInt8

    // MARK: - Construction

    /// Convenience initialiser that validates each field's byte
    /// length. Throws `sizeMismatch` so the caller cannot
    /// accidentally build a transcript with the wrong-sized pubkey
    /// (which would silently produce a different root key once
    /// concatenated).
    init(protocolVersion: UInt8,
         cipherSuite: UInt8,
         pkAX: Data,
         pkBX: Data,
         pkAPQ: Data,
         pkBPQ: Data,
         ctPQ: Data,
         context: Data,
         pairingNonce: Data,
         userIdInitiator: Data = Data(),
         userIdResponder: Data = Data(),
         hybridRequired: Bool = false) throws {

        guard pkAX.count == ATSAMConstants.Sizes.x25519PublicBytes else {
            throw ATSAMError.sizeMismatch(field: "pkAX",
                                          expected: ATSAMConstants.Sizes.x25519PublicBytes,
                                          got: pkAX.count)
        }
        guard pkBX.count == ATSAMConstants.Sizes.x25519PublicBytes else {
            throw ATSAMError.sizeMismatch(field: "pkBX",
                                          expected: ATSAMConstants.Sizes.x25519PublicBytes,
                                          got: pkBX.count)
        }
        // ML-KEM pubkeys + ciphertext can be empty for the
        // (discouraged) non-hybrid fallback. Otherwise they must
        // be the exact FIPS-203 sizes.
        if !pkAPQ.isEmpty {
            guard pkAPQ.count == ATSAMConstants.Sizes.mlKem768PublicBytes else {
                throw ATSAMError.sizeMismatch(field: "pkAPQ",
                                              expected: ATSAMConstants.Sizes.mlKem768PublicBytes,
                                              got: pkAPQ.count)
            }
        }
        if !pkBPQ.isEmpty {
            guard pkBPQ.count == ATSAMConstants.Sizes.mlKem768PublicBytes else {
                throw ATSAMError.sizeMismatch(field: "pkBPQ",
                                              expected: ATSAMConstants.Sizes.mlKem768PublicBytes,
                                              got: pkBPQ.count)
            }
        }
        if !ctPQ.isEmpty {
            guard ctPQ.count == ATSAMConstants.Sizes.mlKem768CiphertextBytes else {
                throw ATSAMError.sizeMismatch(field: "ctPQ",
                                              expected: ATSAMConstants.Sizes.mlKem768CiphertextBytes,
                                              got: ctPQ.count)
            }
        }
        guard pairingNonce.count == 32 else {
            throw ATSAMError.sizeMismatch(field: "pairingNonce",
                                          expected: 32,
                                          got: pairingNonce.count)
        }

        // 🔴 ROUND 26 — userIds are length-prefixed, no fixed size,
        // but cap at 64 B each to keep canonicalBytes bounded.
        guard userIdInitiator.count <= 64 else {
            throw ATSAMError.sizeMismatch(field: "userIdInitiator",
                                          expected: 64,
                                          got: userIdInitiator.count)
        }
        guard userIdResponder.count <= 64 else {
            throw ATSAMError.sizeMismatch(field: "userIdResponder",
                                          expected: 64,
                                          got: userIdResponder.count)
        }

        self.protocolVersion = protocolVersion
        self.cipherSuite = cipherSuite
        self.pkAX = pkAX
        self.pkBX = pkBX
        self.pkAPQ = pkAPQ
        self.pkBPQ = pkBPQ
        self.ctPQ = ctPQ
        self.context = context
        self.pairingNonce = pairingNonce
        self.userIdInitiator = userIdInitiator
        self.userIdResponder = userIdResponder
        self.hybridRequired = hybridRequired ? 1 : 0
    }

    // MARK: - Serialisation

    /// Emit the canonical byte sequence that gets hashed. Layout:
    ///
    /// ```
    /// transcriptDomain         (variable, fixed at compile time)
    /// protocolVersion          (1 byte)
    /// cipherSuite              (1 byte)
    /// len(pkAX)+pkAX           (2 + 32 bytes)
    /// len(pkBX)+pkBX           (2 + 32 bytes)
    /// len(pkAPQ)+pkAPQ         (2 + 0 or 1184 bytes)
    /// len(pkBPQ)+pkBPQ         (2 + 0 or 1184 bytes)
    /// len(ctPQ)+ctPQ           (2 + 0 or 1088 bytes)
    /// len(context)+context     (2 + |context| bytes)
    /// pairingNonce             (32 bytes, fixed)
    /// len(userIdInitiator)+... (2 + 0..64 bytes)  ← round 26
    /// len(userIdResponder)+... (2 + 0..64 bytes)  ← round 26
    /// hybridRequired           (1 byte)            ← round 26
    /// ```
    ///
    /// Length-prefixing each variable field defeats canonicalisation
    /// attacks where an attacker re-arranges concatenated bytes
    /// across boundaries. With length prefixes, only one parse is
    /// possible.
    ///
    /// 🔴 ROUND 26 — three new tail bindings (userIdInitiator,
    /// userIdResponder, hybridRequired). Pre-round-26 transcripts
    /// will hash differently from round-26-or-later — that's
    /// intentional: a round-26 build refuses to derive a root that
    /// uses the older layout. Stale ATSAM sessions need re-pair.
    func canonicalBytes() -> Data {
        var out = Data()
        out.reserveCapacity(64 + pkAX.count + pkBX.count + pkAPQ.count + pkBPQ.count + ctPQ.count + context.count + userIdInitiator.count + userIdResponder.count)

        out.append(ATSAMConstants.transcriptDomain)
        out.append(protocolVersion)
        out.append(cipherSuite)

        // Length-prefixed append helper. UInt16 big-endian.
        func appendLP(_ d: Data) {
            let len = UInt16(d.count)
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
            out.append(d)
        }
        appendLP(pkAX)
        appendLP(pkBX)
        appendLP(pkAPQ)
        appendLP(pkBPQ)
        appendLP(ctPQ)
        appendLP(context)

        // Pairing nonce is fixed-length, no prefix needed.
        out.append(pairingNonce)

        // 🔴 ROUND 26 — userId bindings + hybrid-required policy.
        appendLP(userIdInitiator)
        appendLP(userIdResponder)
        out.append(hybridRequired)

        return out
    }

    /// SHA-256 of the canonical byte sequence. This is the value that
    /// gets folded into the HKDF salt + info during root-key
    /// derivation.
    func hash() -> Data {
        Data(SHA256.hash(data: canonicalBytes()))
    }
}
