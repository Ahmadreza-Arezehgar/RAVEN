//
//  ATSAMHybridPairing.swift
//  RAVEN — ATSAM
//
//  End-to-end pairing entry point. Combines the X25519 shared-secret
//  step, the ML-KEM encapsulation/decapsulation step, the transcript
//  binding, and the HKDF root derivation into one call per side.
//
//  Caller pattern (initiator side, "Alice"):
//
//      // 1. Alice already has her long-term keys.
//      let aliceKeys = ATSAMPairingKeys.load(...)
//
//      // 2. Receive Bob's static pubkeys via OOB (QR/NFC).
//      let bobX  = ...   // 32 B
//      let bobPQ = ...   // 1184 B
//
//      // 3. Run Pair() — this consumes Bob's pubkeys + a fresh nonce
//      //    and produces the ML-KEM ciphertext + the root key.
//      let result = try ATSAMHybridPairing.pairAsInitiator(
//          local: aliceKeys,
//          peerXPub: bobX,
//          peerPQPub: bobPQ,
//          context: Data("raven-prod".utf8)
//      )
//
//      // 4. Hand `result.outgoingCiphertext` to Bob over OOB.
//      // 5. Discard the ephemeral state; persist the resulting tree.
//      let tree = ATSAMKeyTree(root: result.root)
//
//  Caller pattern (responder side, "Bob"):
//
//      let bobKeys = ATSAMPairingKeys.load(...)
//      let result = try ATSAMHybridPairing.pairAsResponder(
//          local: bobKeys,
//          peerXPub: aliceX,
//          peerPQPub: alicePQ,
//          incomingCiphertext: <from Alice over OOB>,
//          context: Data("raven-prod".utf8),
//          pairingNonce: <from Alice's transcript>
//      )
//      let tree = ATSAMKeyTree(root: result.root)
//
//  ML-KEM-768 status: `ATSAMMLKem` wires Apple's native
//  `CryptoKit.MLKEM768` (FIPS 203) on iOS 26+/macOS 26+. On those
//  OSes `pairAsInitiator` / `pairAsResponder` run the FULL hybrid
//  (X25519 + ML-KEM-768). On older OSes ML-KEM is unavailable and
//  the hybrid path fails closed (`nonHybridFallbackRefused`) unless
//  the caller explicitly opts into degraded X25519-only mode.
//  The `_test_*` paths force degraded mode with an all-zero ML-KEM
//  secret — they exist purely for the HKDF-tree + transcript-binding
//  KATs. PRODUCTION CALLERS MUST NOT USE THE `_test_` PATHS.
//

import Foundation
import CryptoKit

/// Long-term keys held by one side of an ATSAM pair.
struct ATSAMPairingKeys: Sendable {

    /// X25519 static private key (32 B scalar).
    let xPriv: Curve25519.KeyAgreement.PrivateKey

    /// X25519 static public key derived from `xPriv`. Cached so
    /// callers don't re-derive on every pairing call.
    let xPub: Data

    /// ML-KEM-768 encapsulation key (public). Empty `Data(count: 0)`
    /// if PQ keys are not provisioned (degraded mode).
    let pqPub: Data

    /// ML-KEM-768 decapsulation key (private). Empty if degraded.
    let pqPriv: Data

    /// Convenience builder for a freshly-generated key pair.
    ///
    /// On iOS 26+ / macOS 26+ this produces a FULL hybrid pair:
    /// X25519 + ML-KEM-768 — both halves seeded from the system
    /// CSPRNG via CryptoKit. On older OS versions ML-KEM is
    /// unavailable, so `pqPub` / `pqPriv` come back empty and any
    /// subsequent `pairAsInitiator` call will throw
    /// `kemNotAvailable` (fail-closed) unless the caller explicitly
    /// uses the `_test_*` X25519-only paths.
    static func generate() throws -> ATSAMPairingKeys {
        let xp = Curve25519.KeyAgreement.PrivateKey()
        let xPub = xp.publicKey.rawRepresentation

        // Try to generate ML-KEM-768 keys. If unavailable, fall back
        // to empty placeholders (caller must check `pqPub.isEmpty`
        // before invoking the hybrid path).
        if ATSAMMLKem.isAvailable {
            let pq = try ATSAMMLKem.keyGen()
            return ATSAMPairingKeys(
                xPriv: xp,
                xPub: xPub,
                pqPub: pq.publicKey,
                pqPriv: pq.privateKey
            )
        } else {
            return ATSAMPairingKeys(
                xPriv: xp,
                xPub: xPub,
                pqPub: Data(),
                pqPriv: Data()
            )
        }
    }
}

/// Output of one Pair() call. Both sides see the same `root` after
/// a successful exchange.
struct ATSAMPairingResult: Sendable {

    /// The 32-byte hybrid root. Both A and B compute identical bytes
    /// (correctness invariant of ATSAM pairing).
    let root: ATSAMRootKey

    /// The transcript that was bound. Stored so subsequent ratchet
    /// updates / re-pair checks can verify the same transcript was
    /// used.
    let transcript: ATSAMTranscript

    /// ML-KEM ciphertext produced by the initiator. Empty on the
    /// responder side (responder consumed an incoming ciphertext)
    /// and empty in degraded mode.
    let outgoingCiphertext: Data
}

/// Top-level pairing entry points.
enum ATSAMHybridPairing {

    // MARK: - Initiator side

    /// Pair as the initiator ("Alice"). Computes:
    ///   - Z_X = X25519(skA, pkB)
    ///   - (ctPQ, Z_PQ) = ML-KEM.Encap(pkB^PQ)
    ///   - transcript = bind(pkA, pkB, pkA^PQ, pkB^PQ, ctPQ, context, nonce)
    ///   - K_root = HKDF-Hybrid(Z_X || Z_PQ, transcript)
    ///
    /// The caller MUST then transmit `result.outgoingCiphertext` to
    /// the responder over the OOB channel (alongside Alice's public
    /// keys + the pairing nonce).
    ///
    /// Fail-closed policy: if either side lacks ML-KEM keys, this
    /// throws `ATSAMError.nonHybridFallbackRefused` UNLESS the caller
    /// explicitly opts in via `allowNonHybridFallback: true`. UI
    /// SHOULD surface the choice — "this peer is on an older build;
    /// proceed without post-quantum protection?" — rather than
    /// silently degrading.
    ///
    /// 🔴 ROUND 26 — hacker-audit Mesh F4 hardening adds three
    /// optional parameters bound into the transcript:
    ///   • `selfUserId`  — initiator's RAVEN userId (UTF-8).
    ///   • `peerUserId`  — responder's RAVEN userId (UTF-8).
    ///   • `hybridRequired` — when true, ATSAMError.nonHybridFallbackRefused
    ///     fires unconditionally even if `allowNonHybridFallback: true`.
    /// All three default to "" / false so pre-round-26 callers keep
    /// compiling; production sites SHOULD pass real userIds.
    static func pairAsInitiator(
        local: ATSAMPairingKeys,
        peerXPub: Data,
        peerPQPub: Data,
        context: Data,
        pairingNonce: Data? = nil,
        allowNonHybridFallback: Bool = false,
        selfUserId: String = "",
        peerUserId: String = "",
        hybridRequired: Bool = false
    ) throws -> ATSAMPairingResult {

        // 1. X25519 shared secret.
        guard peerXPub.count == ATSAMConstants.Sizes.x25519PublicBytes else {
            throw ATSAMError.sizeMismatch(field: "peerXPub",
                                          expected: ATSAMConstants.Sizes.x25519PublicBytes,
                                          got: peerXPub.count)
        }
        let peerPubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerXPub)
        let sharedSecret = try local.xPriv.sharedSecretFromKeyAgreement(with: peerPubKey)
        let zX = sharedSecret.withUnsafeBytes { Data($0) }
        // Non-contributory guard: an all-zero X25519 result means the
        // peer supplied a low-order public key. Fail closed (spec MUST).
        guard !zX.allSatisfy({ $0 == 0 }) else {
            throw ATSAMError.nonContributoryX25519
        }

        // 2. Fresh pairing nonce (32 B random) unless caller supplied one.
        let nonceBytes: Data
        if let supplied = pairingNonce {
            guard supplied.count == 32 else {
                throw ATSAMError.sizeMismatch(field: "pairingNonce",
                                              expected: 32,
                                              got: supplied.count)
            }
            nonceBytes = supplied
        } else {
            var buf = Data(count: 32)
            let status = buf.withUnsafeMutableBytes { ptr -> Int32 in
                guard let baseAddr = ptr.baseAddress else { return -1 }
                return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddr)
            }
            guard status == errSecSuccess else {
                throw ATSAMError.invalidInput(reason: "SecRandomCopyBytes failed")
            }
            nonceBytes = buf
        }

        // 3. Hybrid-vs-degraded policy gate. If EITHER side lacks PQ,
        //    refuse unless caller explicitly allowed fallback. This
        //    is the C1-style fail-closed posture: silent downgrade
        //    would let an attacker MITM the OOB channel to strip
        //    the PQ pubkey.
        //
        // 🔴 ROUND 26 — `hybridRequired: true` defeats the
        // `allowNonHybridFallback` opt-in entirely. Use it when the
        // peer's QR/profile says "I will only pair PQ" (a security-
        // conscious user can flip the bit). The bit is ALSO bound
        // into the transcript so an MITM that flips it to false on
        // the wire produces a transcript mismatch → root mismatch
        // → ATSAM session fails to come up. Defense in depth.
        let bothHavePQ = !peerPQPub.isEmpty && !local.pqPub.isEmpty
        if !bothHavePQ && (hybridRequired || !allowNonHybridFallback) {
            throw ATSAMError.nonHybridFallbackRefused
        }

        let ctPQ: Data
        let zPQ: Data
        // Normalised PQ pubkey fields for the transcript. When
        // running in degraded mode, BOTH sides MUST use empty PQ
        // fields so the transcript hashes agree. If we kept the
        // local pqPub set while the peer's was empty, the two
        // sides would build different transcripts and roots.
        let pkAPQForTranscript: Data
        let pkBPQForTranscript: Data
        if bothHavePQ {
            let encap = try ATSAMMLKem.encapsulate(publicKey: peerPQPub)
            ctPQ = encap.ciphertext
            zPQ = encap.sharedSecret
            pkAPQForTranscript = local.pqPub
            pkBPQForTranscript = peerPQPub
        } else {
            // Degraded mode: zero PQ contribution everywhere so A
            // and B agree on transcript bytes.
            ctPQ = Data()
            zPQ = Data(repeating: 0x00, count: ATSAMConstants.Sizes.mlKem768SharedBytes)
            pkAPQForTranscript = Data()
            pkBPQForTranscript = Data()
        }

        // 4. Transcript binding.
        // 🔴 ROUND 26 — bind userIds + hybridRequired so cross-pair
        // replay and policy-downgrade attempts produce divergent
        // transcripts.
        let transcript = try ATSAMTranscript(
            protocolVersion: ATSAMConstants.formatVersion,
            cipherSuite: ATSAMConstants.cipherSuite,
            pkAX: local.xPub,
            pkBX: peerXPub,
            pkAPQ: pkAPQForTranscript,
            pkBPQ: pkBPQForTranscript,
            ctPQ: ctPQ,
            context: context,
            pairingNonce: nonceBytes,
            userIdInitiator: Data(selfUserId.utf8),
            userIdResponder: Data(peerUserId.utf8),
            hybridRequired: hybridRequired
        )

        // 5. Hybrid root derivation.
        let root = try ATSAMRootDerivation.deriveRoot(
            zX: zX,
            zPQ: zPQ,
            transcript: transcript
        )

        return ATSAMPairingResult(
            root: root,
            transcript: transcript,
            outgoingCiphertext: ctPQ
        )
    }

    // MARK: - Responder side

    /// Pair as the responder ("Bob"). Computes:
    ///   - Z_X = X25519(skB, pkA)
    ///   - Z_PQ = ML-KEM.Decap(skB^PQ, ctPQ)
    ///   - transcript = bind(...)  — same fields, same byte order
    ///   - K_root = HKDF-Hybrid(Z_X || Z_PQ, transcript)
    ///
    /// Correctness: produces identical `root` to the initiator's
    /// `pairAsInitiator(...)` provided the transcript fields match
    /// byte-for-byte.
    ///
    /// 🔴 ROUND 26 — see `pairAsInitiator` for the new round-26
    /// transcript bindings. Both sides MUST supply matching
    /// `selfUserId` / `peerUserId` (swapped per side) and the same
    /// `hybridRequired` value, or the derived roots diverge.
    static func pairAsResponder(
        local: ATSAMPairingKeys,
        peerXPub: Data,
        peerPQPub: Data,
        incomingCiphertext: Data,
        context: Data,
        pairingNonce: Data,
        allowNonHybridFallback: Bool = false,
        selfUserId: String = "",
        peerUserId: String = "",
        hybridRequired: Bool = false
    ) throws -> ATSAMPairingResult {

        // 1. X25519 shared secret.
        guard peerXPub.count == ATSAMConstants.Sizes.x25519PublicBytes else {
            throw ATSAMError.sizeMismatch(field: "peerXPub",
                                          expected: ATSAMConstants.Sizes.x25519PublicBytes,
                                          got: peerXPub.count)
        }
        let peerPubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerXPub)
        let sharedSecret = try local.xPriv.sharedSecretFromKeyAgreement(with: peerPubKey)
        let zX = sharedSecret.withUnsafeBytes { Data($0) }
        // Non-contributory guard: an all-zero X25519 result means the
        // peer supplied a low-order public key. Fail closed (spec MUST).
        guard !zX.allSatisfy({ $0 == 0 }) else {
            throw ATSAMError.nonContributoryX25519
        }

        // 2. Hybrid-vs-degraded policy gate (matches initiator).
        // 🔴 ROUND 26 — hybridRequired beats allowNonHybridFallback.
        let bothHavePQ = !incomingCiphertext.isEmpty
            && !peerPQPub.isEmpty
            && !local.pqPriv.isEmpty
            && !local.pqPub.isEmpty
        if !bothHavePQ && (hybridRequired || !allowNonHybridFallback) {
            throw ATSAMError.nonHybridFallbackRefused
        }

        let zPQ: Data
        let pkAPQForTranscript: Data
        let pkBPQForTranscript: Data
        let ctPQForTranscript: Data
        if bothHavePQ {
            zPQ = try ATSAMMLKem.decapsulate(
                ciphertext: incomingCiphertext,
                privateKey: local.pqPriv
            )
            pkAPQForTranscript = peerPQPub
            pkBPQForTranscript = local.pqPub
            ctPQForTranscript = incomingCiphertext
        } else {
            zPQ = Data(repeating: 0x00, count: ATSAMConstants.Sizes.mlKem768SharedBytes)
            pkAPQForTranscript = Data()
            pkBPQForTranscript = Data()
            ctPQForTranscript = Data()
        }

        // 3. Transcript binding. Bob's transcript MUST list the
        //    fields in the SAME ORDER as Alice's, with Alice's
        //    pubkey as `pkAX` (NOT Bob's). This is the "initiator
        //    first" convention — both sides agree based on
        //    pre-pair role assignment (Alice sends first OOB
        //    message, Bob receives it).
        // 🔴 ROUND 26 — initiator's userId goes into
        // userIdInitiator. Responder is `self` on this side, so
        // selfUserId becomes userIdResponder.
        let transcript = try ATSAMTranscript(
            protocolVersion: ATSAMConstants.formatVersion,
            cipherSuite: ATSAMConstants.cipherSuite,
            pkAX: peerXPub,           // initiator's
            pkBX: local.xPub,         // responder's
            pkAPQ: pkAPQForTranscript,
            pkBPQ: pkBPQForTranscript,
            ctPQ: ctPQForTranscript,
            context: context,
            pairingNonce: pairingNonce,
            userIdInitiator: Data(peerUserId.utf8),
            userIdResponder: Data(selfUserId.utf8),
            hybridRequired: hybridRequired
        )

        // 4. Hybrid root.
        let root = try ATSAMRootDerivation.deriveRoot(
            zX: zX,
            zPQ: zPQ,
            transcript: transcript
        )

        return ATSAMPairingResult(
            root: root,
            transcript: transcript,
            outgoingCiphertext: Data()  // responder doesn't produce one
        )
    }

    // MARK: - Test paths (production must not call)

    /// Test-only: pair as initiator with an empty PQ pubkey. Forces
    /// the degraded X25519-only path. Used by Stage 1's KAT tests
    /// to exercise the HKDF tree without requiring ML-KEM.
    static func _test_pairAsInitiatorWithoutPQ(
        local: ATSAMPairingKeys,
        peerXPub: Data,
        context: Data,
        pairingNonce: Data
    ) throws -> ATSAMPairingResult {
        var degradedLocal = local
        if !local.pqPub.isEmpty {
            // Build a copy with empty PQ keys for the test path.
            degradedLocal = ATSAMPairingKeys(
                xPriv: local.xPriv,
                xPub: local.xPub,
                pqPub: Data(),
                pqPriv: Data()
            )
        }
        return try pairAsInitiator(
            local: degradedLocal,
            peerXPub: peerXPub,
            peerPQPub: Data(),  // empty → degraded mode
            context: context,
            pairingNonce: pairingNonce,
            allowNonHybridFallback: true  // test path explicitly opts in
        )
    }

    /// Test-only: pair as responder with an empty PQ pubkey. Mirror
    /// of `_test_pairAsInitiatorWithoutPQ`.
    static func _test_pairAsResponderWithoutPQ(
        local: ATSAMPairingKeys,
        peerXPub: Data,
        context: Data,
        pairingNonce: Data
    ) throws -> ATSAMPairingResult {
        var degradedLocal = local
        if !local.pqPriv.isEmpty {
            degradedLocal = ATSAMPairingKeys(
                xPriv: local.xPriv,
                xPub: local.xPub,
                pqPub: Data(),
                pqPriv: Data()
            )
        }
        return try pairAsResponder(
            local: degradedLocal,
            peerXPub: peerXPub,
            peerPQPub: Data(),
            incomingCiphertext: Data(),
            context: context,
            pairingNonce: pairingNonce,
            allowNonHybridFallback: true  // test path explicitly opts in
        )
    }
}
