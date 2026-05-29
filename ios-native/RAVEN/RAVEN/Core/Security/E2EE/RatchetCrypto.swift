//
//  RatchetCrypto.swift
//  RAVEN
//
//  Cryptographic primitive helpers for the Signal-style Double Ratchet.
//
//  This file ONLY exposes pure, side-effect-free helpers built on top of
//  Apple CryptoKit. No I/O, no Keychain, no SQLite — that lives in the
//  state machine and storage layers above.
//
//  All helpers follow the Signal Double Ratchet spec
//  (https://signal.org/docs/specifications/doubleratchet/) — the
//  KDF_RK / KDF_CK constants, info strings, and AEAD construction match
//  the spec verbatim so future inter-op with reference implementations
//  remains possible.
//
//  ⚠️ Crypto correctness checklist when modifying this file:
//   • KDF info strings must NEVER change (would invalidate every persisted
//     session).
//   • AEAD nonces must be 12 bytes and unique per (key, message). We
//     derive them deterministically from the message key so a single key
//     is only ever used once anyway.
//   • All key-material outputs are 32 bytes; downstream code assumes that.
//

import Foundation
import CryptoKit

// MARK: - Constants

enum RatchetCrypto {

    // Domain-separated info strings for HKDF. Per spec these are protocol
    // identifiers so that a key from one chain can never be confused with
    // another even if a hash collision occurs.
    static let infoRootKey      = Data("RAVEN_E2EE_ROOT".utf8)
    static let infoChainKey     = Data("RAVEN_E2EE_CHAIN".utf8)
    static let infoMessageKey   = Data("RAVEN_E2EE_MSG".utf8)
    static let infoX3DH         = Data("RAVEN_E2EE_X3DH".utf8)

    // HMAC inputs that distinguish the chain-key step from the
    // message-key step inside KDF_CK (Signal spec §5.2).
    static let chainKeyConstant: UInt8   = 0x02
    static let messageKeyConstant: UInt8 = 0x01

    // 32-byte outputs everywhere.
    static let keyByteCount = 32
}

// MARK: - KDF_RK (root-key step)

extension RatchetCrypto {
    /// Signal spec KDF_RK: rootKey || dhOutput → (newRootKey, chainKey)
    ///
    /// Used after every Diffie-Hellman ratchet step. The rootKey is the
    /// HKDF salt; the DH output is the input keying material; the info
    /// label produces 64 bytes split into two 32-byte halves.
    static func kdfRootKey(rootKey: SymmetricKey, dhOutput: SharedSecret)
        -> (newRootKey: SymmetricKey, chainKey: SymmetricKey)
    {
        // 64 bytes = 32 (new root) + 32 (chain)
        let derived = dhOutput.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: rootKey.dataRepresentation,
            sharedInfo: infoRootKey,
            outputByteCount: 64
        )
        let raw = derived.dataRepresentation
        let newRoot = SymmetricKey(data: raw.prefix(32))
        let chain   = SymmetricKey(data: raw.suffix(32))
        return (newRoot, chain)
    }
}

// MARK: - KDF_CK (chain-key step)

extension RatchetCrypto {
    /// Signal spec KDF_CK: chainKey → (newChainKey, messageKey)
    ///
    /// Two HMACs over the same key with different one-byte constants —
    /// cheap, deterministic, and forward-secure (the previous chainKey
    /// is overwritten and unrecoverable from the outputs).
    static func kdfChainKey(_ chainKey: SymmetricKey)
        -> (newChainKey: SymmetricKey, messageKey: SymmetricKey)
    {
        // newChainKey = HMAC(ck, 0x02)
        let newChainData = HMAC<SHA256>.authenticationCode(
            for: Data([chainKeyConstant]),
            using: chainKey
        )
        // messageKey = HMAC(ck, 0x01)
        let messageKeyData = HMAC<SHA256>.authenticationCode(
            for: Data([messageKeyConstant]),
            using: chainKey
        )
        return (
            SymmetricKey(data: Data(newChainData)),
            SymmetricKey(data: Data(messageKeyData))
        )
    }
}

// MARK: - AEAD encrypt / decrypt

extension RatchetCrypto {
    /// Encrypt a single message under a per-message key.
    ///
    /// We use AES-256-GCM with a deterministic 12-byte nonce derived from
    /// the message key itself. Because every message uses a *fresh*
    /// message key (Double Ratchet guarantees this), a deterministic
    /// nonce is safe — the (key, nonce) pair is never reused.
    ///
    /// Associated Data binds the ciphertext to the ratchet header so a
    /// MITM cannot rewrite header fields without invalidating the
    /// AEAD tag.
    static func aeadEncrypt(
        plaintext: Data,
        messageKey: SymmetricKey,
        associatedData: Data
    ) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: deriveNonce(from: messageKey))
        let sealed = try AES.GCM.seal(
            plaintext,
            using: messageKey,
            nonce: nonce,
            authenticating: associatedData
        )
        guard let combined = sealed.combined else {
            throw RatchetError.encryptionFailed
        }
        return combined
    }

    /// Decrypt a message produced by `aeadEncrypt`. Throws on tag failure.
    static func aeadDecrypt(
        ciphertext: Data,
        messageKey: SymmetricKey,
        associatedData: Data
    ) throws -> Data {
        let sealed = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(
            sealed,
            using: messageKey,
            authenticating: associatedData
        )
    }

    /// Deterministic 12-byte nonce derived from the message key.
    /// HKDF-SHA256 is overkill but cheap and gives us domain separation
    /// from anything else that ever HMACs the same key.
    private static func deriveNonce(from key: SymmetricKey) -> Data {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            info: Data("RAVEN_E2EE_NONCE".utf8),
            outputByteCount: 12
        )
        return derived.dataRepresentation
    }
}

// MARK: - SymmetricKey ↔ Data convenience

extension SymmetricKey {
    /// Stable byte view of the key. CryptoKit hides this behind
    /// `withUnsafeBytes` for safety; we need it for HKDF salt and for
    /// persistence.
    var dataRepresentation: Data {
        withUnsafeBytes { Data($0) }
    }
}

// MARK: - Errors

enum RatchetError: Error, LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case invalidHeader
    case skippedKeyLimitExceeded
    case sessionNotInitialised
    case bundleVerificationFailed
    case storageFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:        return "E2EE encryption failed."
        case .decryptionFailed:        return "E2EE decryption failed (bad key, tampered ciphertext, or out-of-window message)."
        case .invalidHeader:           return "Ratchet header malformed."
        case .skippedKeyLimitExceeded: return "Too many out-of-order messages skipped — possible DoS."
        case .sessionNotInitialised:   return "No ratchet session for this peer; run X3DH first."
        case .bundleVerificationFailed:return "PreKey bundle signature did not verify under the peer's identity key."
        case .storageFailed(let e):    return "Ratchet session store failed: \(e.localizedDescription)"
        }
    }
}
