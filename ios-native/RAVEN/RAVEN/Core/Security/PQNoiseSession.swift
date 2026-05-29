// PQNoiseSession — post-quantum hybrid Noise IK (C.4)
//
// Stub today (May 2026). Real implementation lands once Apple ships
// `CryptoKit.MLKEM768` and `CryptoKit.MLDSA65`. See
// `docs/RUM_V2_ROADMAP.md` §C.4 for the rationale on why we wait instead
// of pulling in a third-party C library (`liboqs`, `PQClean`, BoringSSL's
// PQ branch). TL;DR: ciphertext-parsing on every frame is the wrong place
// to introduce a new native dependency, especially while NIST FIPS-203/204
// implementations are still settling on `_ipd` vs. final parameter
// encodings across upstreams.
//
// The API surface here mirrors `NoiseSession` 1:1 so `NoiseSessionStore`
// can drop in this implementation behind a feature flag once
// `isAvailable == true`. Keeping the type defined now means callers can
// `import` it and gate on `isAvailable` without `#if canImport(...)`
// scaffolding that's fragile across Xcode versions.

import Foundation
import CryptoKit

/// Hybrid X25519 + ML-KEM-768 Noise IK session.
///
/// API parity with ``NoiseSession`` so the engine can swap implementations
/// behind ``RUMProtocolV2/pqEnabled``. Until Apple ships ML-KEM in
/// CryptoKit, every operation throws ``PQError/notYetAvailable``.
struct PQNoiseSession {

    /// One-shot check used by the engine when deciding whether to
    /// advertise ``RUMProtocolV2/Capabilities/pqHybridKEM``. Today this is
    /// `false` everywhere — flip to a real runtime probe (e.g.
    /// `#available(iOS 27, *)` once we know the version) when CryptoKit
    /// exposes ML-KEM. ``RUMProtocolV2/pqEnabled`` is the master gate —
    /// even if `isAvailable` flips, the engine should refuse to negotiate
    /// PQ unless both are true.
    static var isAvailable: Bool {
        // No production runtime check yet. `false` is correct because
        // CryptoKit on iOS 26.4 has no ML-KEM API. The exact gate
        // (probably `if #available(iOS 27.0, *)`) lands the same week we
        // implement the body — keeping both `false` for now avoids
        // accidental capability-bit advertisement.
        return false
    }

    enum PQError: Error, LocalizedError {
        /// Caller invoked a PQ primitive on a build that doesn't have the
        /// crypto. Engines should gate on ``PQNoiseSession/isAvailable``
        /// rather than catching this — by the time you see this thrown,
        /// something tried to use PQ behind the gate.
        case notYetAvailable

        var errorDescription: String? {
            switch self {
            case .notYetAvailable:
                return "Post-quantum hybrid Noise is reserved but not yet implemented on this build. See docs/RUM_V2_ROADMAP.md §C.4."
            }
        }
    }

    // MARK: - Handshake API (mirrors NoiseSession.IK pattern)
    //
    // The real signatures will be:
    //
    //     init(role:, staticKeyPair:, remoteStaticPub:)
    //     mutating func writeMessage1(payload:) throws -> (wire: Data, pqEphemeral: MLKEM768.PrivateKey)
    //     mutating func readMessage1(_ wire: Data) throws -> Data
    //     mutating func writeMessage2(payload:) throws -> Data
    //     mutating func readMessage2(_ wire: Data, pqEphemeral: MLKEM768.PrivateKey) throws -> Data
    //
    // For the stub we expose method names + the same throw site so callers
    // catch one error type. The real bodies replace these inline once
    // CryptoKit ships.

    static func writeMessage1(payload _: Data) throws -> Data {
        throw PQError.notYetAvailable
    }

    static func readMessage1(_ wire: Data) throws -> Data {
        _ = wire
        throw PQError.notYetAvailable
    }

    static func writeMessage2(payload _: Data) throws -> Data {
        throw PQError.notYetAvailable
    }

    static func readMessage2(_ wire: Data) throws -> Data {
        _ = wire
        throw PQError.notYetAvailable
    }

    // MARK: - Transport mode (post-handshake AEAD)

    static func encrypt(_ plaintext: Data, ad: Data) throws -> Data {
        _ = (plaintext, ad)
        throw PQError.notYetAvailable
    }

    static func decrypt(_ ciphertext: Data, ad: Data) throws -> Data {
        _ = (ciphertext, ad)
        throw PQError.notYetAvailable
    }

    // MARK: - Hybrid signature (ML-DSA-65)
    //
    // Independent of the KEM side — a build may have signing first if the
    // signature primitive ships before the KEM. The engine can advertise
    // `Capabilities.pqHybridSig` without `Capabilities.pqHybridKEM`.

    static func signHybrid(_ message: Data, ed25519: Curve25519.Signing.PrivateKey) throws -> (ed: Data, pq: Data) {
        _ = (message, ed25519)
        throw PQError.notYetAvailable
    }

    /// Returns true iff BOTH signatures verify. There's no "either-or"
    /// mode — falling back to a single sig defeats the hybrid guarantee.
    static func verifyHybrid(message _: Data, ed25519: Curve25519.Signing.PublicKey, edSig _: Data, pqPubKey _: Data, pqSig _: Data) throws -> Bool {
        _ = ed25519
        throw PQError.notYetAvailable
    }
}
