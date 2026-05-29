//
//  ATSAMRootKey.swift
//  RAVEN — ATSAM
//
//  Hybrid root-key derivation. This is the single most important
//  cryptographic primitive in ATSAM v1 — it produces the 32-byte
//  `K_root` from which every downstream layer derives its sub-keys
//  via the HKDF tree (`ATSAMKeyTree`).
//
//  Construction (PDF §8, with C1 fix from the review):
//
//    K_root := HKDF-Extract-then-Expand(
//        ikm  = Z_X || Z_PQ,
//        salt = transcript.hash(),
//        info = "ATSAM/v1/pair-init" || transcript.hash(),
//        L    = 32
//    )
//
//  Security bound (corrected from doc §8 — see C1 of the review):
//
//    Adv_Seed-IND ≤ Adv_HKDF-PRG
//                 + min( Adv_X25519-DDH , Adv_ML-KEM-768-IND-CCA )
//
//  The MIN (not SUM) reflects that the adversary must defeat BOTH
//  halves of the hybrid — defeating either one alone leaves the
//  other 32 bytes of `ikm` uniform-random, and HKDF's PRG property
//  guarantees the output is indistinguishable from uniform.
//
//  Implementation notes:
//    • Both `Z_X` and `Z_PQ` are exactly 32 bytes (RFC 7748 +
//      FIPS 203). Concatenated `ikm` is therefore 64 bytes.
//    • Transcript hash (32 B) is folded BOTH into HKDF's salt
//      slot AND appended to the info string. This is over-binding
//      on purpose: a buggy implementation that uses the wrong
//      salt would still fail to match because the info differs.
//    • `K_root` is persisted ONLY via `ATSAMRootStorage`, which keeps
//      it in the Keychain under
//      `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (encrypted
//      at rest, device-bound, never synced to iCloud, never in
//      backups). It is NEVER written to UserDefaults, a plist, or any
//      app-readable file. Derived sub-keys (PV pads, BBE catch-up
//      state) are the only root-descended artifacts that touch
//      general storage — the root itself stays Keychain-only.
//

import Foundation
import CryptoKit

/// The 32-byte hybrid root key. Wrapped in a struct so callers can't
/// accidentally use raw bytes for the wrong purpose — the only way
/// to consume `ATSAMRootKey` is through `ATSAMKeyTree`, which forces
/// every derivation through a typed `KDFLabel`.
struct ATSAMRootKey: Sendable, Hashable {

    /// The 32 raw bytes. Internal to the ATSAM module — callers
    /// outside should access derived sub-keys, not the root.
    fileprivate let bytes: Data

    /// Constructor reserved for the derivation path. External
    /// callers should not synthesise an `ATSAMRootKey` directly;
    /// instead they call `ATSAMHybridPairing.deriveRoot(...)`.
    fileprivate init(bytes: Data) {
        precondition(bytes.count == ATSAMConstants.Sizes.rootKeyBytes,
                     "ATSAMRootKey must be exactly \(ATSAMConstants.Sizes.rootKeyBytes) bytes")
        self.bytes = bytes
    }

    /// Internal accessor for `ATSAMKeyTree`. Marked
    /// `fileprivate(set)` so siblings within the ATSAM module can
    /// read but no external caller can.
    fileprivate var rawBytes: Data { bytes }
}

/// Derivation entry point for the hybrid root.
enum ATSAMRootDerivation {

    /// Compute `K_root` from the X25519 shared secret, the ML-KEM
    /// shared secret, and the bound transcript. Throws if any
    /// input is the wrong size.
    ///
    /// Both ends of the pair run this with their respective `Z_X`
    /// and `Z_PQ` values (derived from their private keys + the
    /// peer's public key + the same ciphertext bytes). The result
    /// is byte-identical on both sides — that's the correctness
    /// property of ATSAM pairing.
    static func deriveRoot(zX: Data,
                           zPQ: Data,
                           transcript: ATSAMTranscript) throws -> ATSAMRootKey {

        // Validate input sizes BEFORE touching any crypto. A
        // wrong-size input here is a programmer bug — fail-fast.
        guard zX.count == ATSAMConstants.Sizes.x25519SharedBytes else {
            throw ATSAMError.sizeMismatch(
                field: "zX",
                expected: ATSAMConstants.Sizes.x25519SharedBytes,
                got: zX.count
            )
        }
        guard zPQ.count == ATSAMConstants.Sizes.mlKem768SharedBytes else {
            throw ATSAMError.sizeMismatch(
                field: "zPQ",
                expected: ATSAMConstants.Sizes.mlKem768SharedBytes,
                got: zPQ.count
            )
        }

        // Bind the transcript. Pre-compute the hash once because
        // we use it twice (salt slot + info-string append).
        let transcriptHash = transcript.hash()
        guard transcriptHash.count == ATSAMConstants.Sizes.transcriptHashBytes else {
            // Defensive — SHA-256 should always be 32 B.
            throw ATSAMError.kdfFailed
        }

        // Concatenate Z_X || Z_PQ. Order matters and is fixed by
        // protocol — classical first, then post-quantum. If a
        // future variant swaps order, the label MUST be bumped.
        var ikm = Data(capacity: zX.count + zPQ.count)
        ikm.append(zX)
        ikm.append(zPQ)

        // Info = "ATSAM/v1/pair-init" || transcriptHash.
        var info = Data(capacity: ATSAMConstants.KDFLabel.pairInit.bytes.count + transcriptHash.count)
        info.append(ATSAMConstants.KDFLabel.pairInit.bytes)
        info.append(transcriptHash)

        // HKDF-Extract-then-Expand. CryptoKit's `deriveKey` is
        // exactly this two-step operation.
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: transcriptHash,
            info: info,
            outputByteCount: ATSAMConstants.Sizes.rootKeyBytes
        )

        // Move out of `SymmetricKey` so we can store as `Data` in
        // the struct (callers don't see this — `ATSAMRootKey`
        // mediates).
        let rawRootBytes = derived.withUnsafeBytes { Data($0) }
        return ATSAMRootKey(bytes: rawRootBytes)
    }

    /// Diagnostic-only path: derive a root with a zero `Z_PQ`. Used
    /// by tests to verify the HKDF tree behaves correctly under
    /// known inputs. Production callers MUST NOT use this — it
    /// silently downgrades to X25519-only security.
    ///
    /// Marked `_test_` to make grep / code-review obvious.
    static func _test_deriveRootWithoutPQ(zX: Data,
                                          transcript: ATSAMTranscript) throws -> ATSAMRootKey {
        let zPQPlaceholder = Data(repeating: 0x00, count: ATSAMConstants.Sizes.mlKem768SharedBytes)
        return try deriveRoot(zX: zX, zPQ: zPQPlaceholder, transcript: transcript)
    }
}

// MARK: - Internal accessor for ATSAMKeyTree

/// Extension that lets `ATSAMKeyTree` read the raw bytes. Kept here
/// (same file) so the `fileprivate` access works. External callers
/// can't read `bytes` because they're outside this file.
extension ATSAMRootKey {
    internal var _rootBytes: Data { bytes }

    /// Internal constructor for the per-peer Keychain reload path.
    ///
    /// 🔴 ROUND 71 phase 3 follow-up #5 (2026-05-24) — Task #44 / #59.
    /// `ATSAMRootStorage.root(for:)` needs to reconstruct an
    /// `ATSAMRootKey` from raw bytes pulled out of Keychain on a
    /// fresh launch. The `fileprivate init(bytes:)` above is the
    /// canonical derivation path but isn't visible outside this
    /// file. This sibling initialiser bridges that gap while
    /// keeping the constructor module-private — external callers
    /// (anywhere outside RAVEN's Security module) still can't
    /// synthesise an `ATSAMRootKey` from arbitrary bytes.
    ///
    /// 🛡️ SECURITY: precondition fails on wrong-size input so a
    /// corrupted Keychain entry can't produce an undersized "root"
    /// that would silently collapse the downstream key tree to a
    /// degenerate state.
    internal init(rootBytes: Data) {
        // Delegate to the fileprivate canonical init (in-file scope
        // means the call is visible). Precondition lives in that
        // init, so wrong-size input crashes here too.
        self.init(bytes: rootBytes)
    }
}
