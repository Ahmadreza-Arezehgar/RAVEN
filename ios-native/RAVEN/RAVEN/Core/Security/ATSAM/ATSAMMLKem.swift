//
//  ATSAMMLKem.swift
//  RAVEN — ATSAM
//
//  ML-KEM-768 (FIPS 203) primitives.
//
//  v1.0 reference WIRES UP Apple's native `CryptoKit.MLKEM768` on
//  iOS 26 / macOS 26 / watchOS 26 / tvOS 26 / macCatalyst 26 /
//  visionOS 26. On earlier OS versions, every primitive throws
//  `ATSAMError.kemNotAvailable` so callers fail closed rather
//  than silently downgrade to non-hybrid security.
//
//  Why we picked Apple's native ML-KEM over `swift-crypto`:
//    1. No SwiftPM dependency to add — one less moving piece in
//       a security-critical path.
//    2. Apple-supplied implementation goes through the same
//       FIPS-203 reference + side-channel hardening that backs
//       Secure Enclave's hardware path. We could swap to the
//       `SecureEnclave.MLKEM768.PrivateKey` variant for
//       hardware-bound private keys in a follow-on (would need
//       biometric / passcode prompts at pair time).
//    3. Apple's API uses the seed form (`d ‖ z`, 64 B) which is
//       smaller and safer to store than the FIPS-203 expanded
//       2400-byte private key. Re-derivation is deterministic.
//
//  Runtime gating: `isAvailable` is a function (not a static
//  let) because the answer depends on `#available(iOS 26, *)` at
//  call site, which is a per-process runtime decision.
//
//  Reference: FIPS 203 (ML-KEM Standard), August 2024.
//

import Foundation
import CryptoKit

/// ML-KEM-768 primitive surface. Wraps Apple's native `MLKEM768`
/// on iOS 26+; throws `kemNotAvailable` on earlier OSes.
enum ATSAMMLKem {

    /// Generate a fresh (publicKey, privateKey) pair.
    ///   - publicKey: 1184 bytes (FIPS-203 encapsulation key)
    ///   - privateKey: 64 bytes (seed form, `d ‖ z`)
    static func keyGen() throws -> (publicKey: Data, privateKey: Data) {
        if #available(iOS 26.0, macOS 26.0, watchOS 26.0, tvOS 26.0, macCatalyst 26.0, visionOS 26.0, *) {
            let priv = try CryptoKit.MLKEM768.PrivateKey()
            return (
                publicKey: priv.publicKey.rawRepresentation,
                privateKey: priv.seedRepresentation
            )
        } else {
            throw ATSAMError.kemNotAvailable
        }
    }

    /// Encapsulate a fresh shared secret toward `publicKey`. Returns
    /// `(ciphertext, sharedSecret)`:
    ///   - ciphertext: 1088 bytes (FIPS-203 ML-KEM-768 ciphertext)
    ///   - sharedSecret: 32 bytes
    /// The recipient runs `decapsulate(ciphertext, privateKey)` and
    /// obtains the same 32-byte shared secret.
    static func encapsulate(publicKey: Data) throws -> (ciphertext: Data, sharedSecret: Data) {
        guard publicKey.count == ATSAMConstants.Sizes.mlKem768PublicBytes else {
            throw ATSAMError.sizeMismatch(
                field: "publicKey",
                expected: ATSAMConstants.Sizes.mlKem768PublicBytes,
                got: publicKey.count
            )
        }
        if #available(iOS 26.0, macOS 26.0, watchOS 26.0, tvOS 26.0, macCatalyst 26.0, visionOS 26.0, *) {
            let pub = try CryptoKit.MLKEM768.PublicKey(rawRepresentation: publicKey)
            let result = try pub.encapsulate()
            let sharedBytes = result.sharedSecret.withUnsafeBytes { Data($0) }
            return (
                ciphertext: result.encapsulated,
                sharedSecret: sharedBytes
            )
        } else {
            throw ATSAMError.kemNotAvailable
        }
    }

    /// Decapsulate a 1088-byte ciphertext using `privateKey` (seed form,
    /// 64 bytes) to recover the 32-byte shared secret. The result MUST
    /// equal the encapsulator's `sharedSecret` (FIPS 203 correctness).
    static func decapsulate(ciphertext: Data, privateKey: Data) throws -> Data {
        guard ciphertext.count == ATSAMConstants.Sizes.mlKem768CiphertextBytes else {
            throw ATSAMError.sizeMismatch(
                field: "ciphertext",
                expected: ATSAMConstants.Sizes.mlKem768CiphertextBytes,
                got: ciphertext.count
            )
        }
        guard privateKey.count == ATSAMConstants.Sizes.mlKem768PrivateBytes else {
            throw ATSAMError.sizeMismatch(
                field: "privateKey (seed form)",
                expected: ATSAMConstants.Sizes.mlKem768PrivateBytes,
                got: privateKey.count
            )
        }
        if #available(iOS 26.0, macOS 26.0, watchOS 26.0, tvOS 26.0, macCatalyst 26.0, visionOS 26.0, *) {
            let priv = try CryptoKit.MLKEM768.PrivateKey(
                seedRepresentation: privateKey,
                publicKey: nil  // re-derive pubkey from seed
            )
            let shared = try priv.decapsulate(ciphertext)
            return shared.withUnsafeBytes { Data($0) }
        } else {
            throw ATSAMError.kemNotAvailable
        }
    }

    /// Runtime check: does this OS expose ML-KEM-768? Use to decide
    /// whether to surface a "PQ unavailable on this device — please
    /// upgrade iOS" prompt at pair time, vs offering hybrid pairing.
    static var isAvailable: Bool {
        if #available(iOS 26.0, macOS 26.0, watchOS 26.0, tvOS 26.0, macCatalyst 26.0, visionOS 26.0, *) {
            return true
        }
        return false
    }
}
