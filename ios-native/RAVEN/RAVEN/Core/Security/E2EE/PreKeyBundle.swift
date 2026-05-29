//
//  PreKeyBundle.swift
//  RAVEN
//
//  X3DH pre-key bundle types — the data each user publishes so others
//  can establish a Double Ratchet session asynchronously, even when the
//  recipient is offline (or only reachable via mesh).
//
//  A user maintains:
//   • Identity Key (Ed25519, long-lived)         — already in DeviceIdentityService
//   • Identity Agreement Key (X25519, long-lived)— already in DeviceIdentityService
//   • Signed PreKey         (X25519, rotated weekly-ish, signed by Identity)
//   • One-Time PreKeys      (X25519, single-use, replenished as consumed)
//
//  When initiator A wants to message B, A fetches B's PreKey bundle
//  (from the server, or piggy-backed on a mesh advertisement) and runs
//  X3DH to derive the initial shared secret. That secret seeds the
//  Double Ratchet root key.
//

import Foundation

// MARK: - Public bundle (what we publish for others)

/// Snapshot of one user's pre-keys at a moment in time. This is the
/// payload that the server hands out (and that mesh peers can advertise
/// during a brief offline-pairing handshake).
///
/// Wire-compact JSON keys — bundles travel often.
struct PreKeyBundle: Codable, Equatable {
    /// Stable user identifier (matches the rest of the app).
    let userId: String
    /// Specific device of that user — supports multi-device.
    let deviceId: String
    /// Ed25519 public key (raw bytes). Already used elsewhere as
    /// `signerPublicKey`.
    let identityKey: Data
    /// X25519 public key for ECDH (already in DeviceIdentityService as
    /// `agreementPublicKeyData`).
    let identityAgreementKey: Data
    /// Currently-active signed pre-key.
    let signedPreKey: SignedPreKeyPublic
    /// One single-use pre-key. The server pops one off the queue per
    /// fetcher; if the queue is empty the bundle is still valid (the
    /// session will just be slightly weaker — no one-time forward
    /// secrecy contribution).
    let oneTimePreKey: OneTimePreKeyPublic?
    /// Bundle minting timestamp (epoch seconds). Used by clients to
    /// reject stale bundles.
    let createdAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case userId               = "uid"
        case deviceId             = "did"
        case identityKey          = "ik"
        case identityAgreementKey = "iak"
        case signedPreKey         = "spk"
        case oneTimePreKey        = "opk"
        case createdAt            = "ca"
    }
}

/// Public half of a signed pre-key. The signature is over `publicKey`
/// using the user's identity Ed25519 key — proves authenticity even if
/// the bundle came over an untrusted channel.
struct SignedPreKeyPublic: Codable, Equatable {
    let id: UInt32
    let publicKey: Data       // X25519 raw
    let signature: Data       // Ed25519 over publicKey
    let createdAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case id        = "i"
        case publicKey = "k"
        case signature = "s"
        case createdAt = "c"
    }
}

/// Public half of a one-time pre-key.
struct OneTimePreKeyPublic: Codable, Equatable {
    let id: UInt32
    let publicKey: Data       // X25519 raw

    enum CodingKeys: String, CodingKey {
        case id        = "i"
        case publicKey = "k"
    }
}

// MARK: - Private bundle (what stays on this device)

/// The locally-held private material for our own pre-keys. NEVER
/// transmitted. Stored encrypted at rest (Keychain / SQLCipher).
struct PreKeyBundlePrivate {
    /// The signed pre-key's private half. Rotated periodically; the
    /// previous one is retained for `gracePeriod` so in-flight
    /// session-init messages still decrypt.
    let signedPreKey: SignedPreKeyPrivate
    /// Pool of unused one-time pre-keys. Each is consumed exactly once.
    let oneTimePreKeys: [OneTimePreKeyPrivate]
}

struct SignedPreKeyPrivate {
    let id: UInt32
    let privateKey: Data      // X25519 raw private
    let publicKey: Data       // X25519 raw public
    let signature: Data       // Ed25519 over publicKey
    let createdAt: TimeInterval
}

struct OneTimePreKeyPrivate {
    let id: UInt32
    let privateKey: Data      // X25519 raw private
    let publicKey: Data       // X25519 raw public
}

// MARK: - Bundle verification

extension PreKeyBundle {
    /// Verify the signed pre-key signature with the bundle's identity
    /// key. Run this BEFORE consuming a bundle — if it fails, the
    /// bundle was tampered with somewhere along the path (server,
    /// mesh relay, MITM).
    ///
    /// Returns `true` iff the signature is valid AND the bundle has
    /// the expected raw-byte sizes (32 each for Curve25519).
    func verifySignature() -> Bool {
        guard identityKey.count == 32,
              identityAgreementKey.count == 32,
              signedPreKey.publicKey.count == 32,
              signedPreKey.signature.count == 64 else {
            return false
        }
        return DeviceIdentityService.shared.verify(
            signature: signedPreKey.signature,
            data: signedPreKey.publicKey,
            publicKey: identityKey
        )
    }
}

// MARK: - Initial X3DH message (sender → receiver, first packet)

/// First packet a Double-Ratchet initiator sends to a brand-new peer.
/// Wraps the ciphertext + the X3DH parameters the receiver needs to
/// derive the shared secret on their side.
///
/// After this message, both sides hold an established session and use
/// only `RatchetCiphertext` going forward.
struct X3DHInitialMessage: Codable, Equatable {
    /// Initiator's identity Ed25519 public key. Used by the receiver
    /// to bind the new session to a known signing identity (TOFU).
    let identityKey: Data
    /// Initiator's identity X25519 agreement public key. Used as the
    /// "IK_A" input to the X3DH combinator (DH2 in the spec).
    let identityAgreementKey: Data
    /// Initiator's *ephemeral* X25519 public key — used once, never
    /// stored, gives the session its post-compromise security guarantee.
    let ephemeralKey: Data
    /// Which signed pre-key of the recipient we used. The recipient
    /// looks this up in their private store.
    let signedPreKeyId: UInt32
    /// Which one-time pre-key (if any). Optional — bundles can run dry.
    let oneTimePreKeyId: UInt32?
    /// The first Double-Ratchet ciphertext, already encrypted under
    /// the X3DH-derived root key.
    let firstCiphertext: RatchetCiphertext

    enum CodingKeys: String, CodingKey {
        case identityKey          = "ik"
        case identityAgreementKey = "iak"
        case ephemeralKey         = "ek"
        case signedPreKeyId       = "spkid"
        case oneTimePreKeyId      = "opkid"
        case firstCiphertext      = "ct"
    }
}
