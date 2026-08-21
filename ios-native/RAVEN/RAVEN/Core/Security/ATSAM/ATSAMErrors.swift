//
//  ATSAMErrors.swift
//  RAVEN — ATSAM
//
//  Typed errors for ATSAM pairing + key-tree derivation. Distinct
//  cases so UI / telemetry can render specific copy ("upgrade required
//  — your peer does not support post-quantum pairing" vs "internal
//  KDF failure — please reinstall") instead of a generic
//  "pairing failed".
//

import Foundation

enum ATSAMError: Error, Equatable {

    // MARK: - Hybrid-pairing errors

    /// ML-KEM-768 primitives are not available in this build. v1.0
    /// reference ships an ML-KEM **scaffold** that exposes the right
    /// API surface but defers to `swift-crypto` (or another approved
    /// FIPS-203 implementation) for actual encapsulation /
    /// decapsulation. Until that dependency is wired in, every call
    /// to `ATSAMMLKem.encapsulate` / `.decapsulate` / `.keyGen`
    /// throws this error so the calling site fails closed rather
    /// than silently downgrading to non-hybrid security.
    case kemNotAvailable

    /// Pair was asked to fall back to X25519-only because the peer
    /// did not advertise ML-KEM-768 support. Treat as a policy
    /// decision, not an internal failure: UI should explain
    /// "this peer is on an older build; pairing without
    /// post-quantum protection — proceed?".
    case nonHybridFallbackRefused

    /// An X25519 key agreement produced the all-zero shared secret
    /// (non-contributory behavior). The peer supplied a low-order /
    /// degenerate public key. MUST fail closed per the ATSAM spec —
    /// a predictable shared secret would silently void all
    /// confidentiality guarantees derived from it.
    case nonContributoryX25519

    // MARK: - Input validation

    /// A byte-string supplied to a primitive is the wrong length.
    /// Carries the expected and actual sizes for diagnostics.
    case sizeMismatch(field: String, expected: Int, got: Int)

    /// Caller passed an empty or malformed input (e.g. zero-length
    /// transcript context). NEVER silently coerce to default —
    /// fail-closed so corrupt callers can't silently produce a
    /// predictable root key.
    case invalidInput(reason: String)

    // MARK: - KDF / transcript errors

    /// HKDF produced an unexpected output length. Should be
    /// impossible with CryptoKit; included so the API can stay
    /// `throws` for forward compatibility with alternative HKDF
    /// backends.
    case kdfFailed

    /// The transcript hash recomputed during a check does not match
    /// the one bound into the root-key derivation. Indicates either
    /// a downgrade attempt (someone swapped a public key after
    /// pairing) or a buggy caller mutating the transcript struct
    /// in flight.
    case transcriptBindingMismatch

    // MARK: - Policy

    /// The protocol version byte in a received pairing envelope is
    /// unknown to this build. v1.0 receivers reject any version
    /// other than `ATSAMConstants.formatVersion`. NEVER guess —
    /// guessing is how downgrade attacks succeed.
    case unsupportedFormatVersion(found: UInt8)

    /// The cipher-suite byte specifies a suite this build doesn't
    /// implement. Same fail-closed posture as version mismatch.
    case unsupportedCipherSuite(found: UInt8)
}
