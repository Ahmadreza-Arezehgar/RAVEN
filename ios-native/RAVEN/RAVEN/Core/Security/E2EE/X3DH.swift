//
//  X3DH.swift
//  RAVEN
//
//  Extended Triple Diffie-Hellman key agreement (Signal X3DH spec).
//  Establishes the initial root key for a Double-Ratchet session,
//  asynchronously (the receiver does not need to be online).
//
//  Initiator A and recipient B compute the same shared secret SK by
//  combining four (or three, if no one-time pre-key is available)
//  Diffie-Hellman outputs:
//
//      DH1 = DH(IK_A, SPK_B)   ← authenticates A's identity to B
//      DH2 = DH(EK_A, IK_B)    ← authenticates B's identity to A
//      DH3 = DH(EK_A, SPK_B)   ← forward-secrecy contribution
//      DH4 = DH(EK_A, OPK_B)   ← one-time post-compromise security
//
//  SK = HKDF(DH1 ‖ DH2 ‖ DH3 [‖ DH4])
//
//  After X3DH, the initiator immediately moves to Double Ratchet
//  using SK as the initial root key — see DoubleRatchet.swift.
//

import Foundation
import CryptoKit

enum X3DH {

    // MARK: - Initiator side

    /// Run X3DH as the *initiator*. Produces:
    ///   • the shared secret to seed Double Ratchet
    ///   • the ephemeral public key the recipient will need to reproduce SK
    ///
    /// Caller is responsible for calling `bundle.verifySignature()` first.
    static func initiate(
        ourIdentityAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        peerBundle: PreKeyBundle
    ) throws -> InitiatorResult {

        // 1. Generate a fresh single-use ephemeral key. Unlike OPKs,
        //    this lives only in this function's scope — the private
        //    half is discarded the moment we're done.
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()

        // 2. Reconstruct peer pubkeys from raw bytes.
        let peerIK  = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: peerBundle.identityAgreementKey
        )
        let peerSPK = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: peerBundle.signedPreKey.publicKey
        )
        let peerOPK = try peerBundle.oneTimePreKey.map {
            try Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0.publicKey)
        }

        // 3. Compute the four Diffie-Hellmans.
        //    Note: the order DH1 ‖ DH2 ‖ DH3 ‖ DH4 must match the
        //    responder's combinator exactly.
        let dh1 = try ourIdentityAgreementPrivateKey.sharedSecretFromKeyAgreement(with: peerSPK)
        let dh2 = try ephemeral.sharedSecretFromKeyAgreement(with: peerIK)
        let dh3 = try ephemeral.sharedSecretFromKeyAgreement(with: peerSPK)
        let dh4 = try peerOPK.map { try ephemeral.sharedSecretFromKeyAgreement(with: $0) }

        // 4. Concat raw secret bytes and HKDF down to a 32-byte SK.
        let sk = combine(dh1: dh1, dh2: dh2, dh3: dh3, dh4: dh4)

        return InitiatorResult(
            sharedSecret: sk,
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            usedSignedPreKeyId: peerBundle.signedPreKey.id,
            usedOneTimePreKeyId: peerBundle.oneTimePreKey?.id
        )
    }

    // MARK: - Responder side

    /// Reproduce the X3DH shared secret on the recipient side, given
    /// the parameters from the initiator's first message.
    ///
    /// The caller looks up the matching SPK (and OPK if present) in
    /// the local private bundle store and passes them in. After this
    /// call the OPK should be deleted from the store — that's what
    /// gives X3DH its one-time post-compromise property.
    static func respond(
        ourIdentityAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        ourSignedPreKeyPrivate: Curve25519.KeyAgreement.PrivateKey,
        ourOneTimePreKeyPrivate: Curve25519.KeyAgreement.PrivateKey?,
        peerIdentityAgreementKey: Data,
        peerEphemeralKey: Data
    ) throws -> SymmetricKey {

        let peerIK = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerIdentityAgreementKey)
        let peerEK = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeralKey)

        // Mirror the initiator's combinator with sides swapped.
        let dh1 = try ourSignedPreKeyPrivate.sharedSecretFromKeyAgreement(with: peerIK)
        let dh2 = try ourIdentityAgreementPrivateKey.sharedSecretFromKeyAgreement(with: peerEK)
        let dh3 = try ourSignedPreKeyPrivate.sharedSecretFromKeyAgreement(with: peerEK)
        let dh4 = try ourOneTimePreKeyPrivate.map {
            try $0.sharedSecretFromKeyAgreement(with: peerEK)
        }

        return combine(dh1: dh1, dh2: dh2, dh3: dh3, dh4: dh4)
    }

    // MARK: - Combinator

    /// HKDF-SHA256 over the concatenated DH outputs, with a constant
    /// 32-byte zero-prefix per Signal spec to avoid known-key attacks.
    private static func combine(
        dh1: SharedSecret,
        dh2: SharedSecret,
        dh3: SharedSecret,
        dh4: SharedSecret?
    ) -> SymmetricKey {
        var ikm = Data()
        // Spec: prefix with F = 0xFF * 32 (Curve25519 max field) to
        // domain-separate from raw DH outputs.
        ikm.append(Data(repeating: 0xFF, count: 32))
        ikm.append(contentsOf: dh1.withUnsafeBytes { Array($0) })
        ikm.append(contentsOf: dh2.withUnsafeBytes { Array($0) })
        ikm.append(contentsOf: dh3.withUnsafeBytes { Array($0) })
        if let dh4 = dh4 {
            ikm.append(contentsOf: dh4.withUnsafeBytes { Array($0) })
        }

        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data(repeating: 0, count: 32), // 32 zero bytes per spec
            info: RatchetCrypto.infoX3DH,
            outputByteCount: RatchetCrypto.keyByteCount
        )
        return key
    }
}

// MARK: - Result types

extension X3DH {
    struct InitiatorResult {
        /// The 32-byte secret to seed Double Ratchet's root key.
        let sharedSecret: SymmetricKey
        /// Ephemeral X25519 public key — must be sent to the recipient
        /// in the X3DHInitialMessage so they can reproduce SK.
        let ephemeralPublicKey: Data
        /// Which of the recipient's signed pre-keys was used.
        let usedSignedPreKeyId: UInt32
        /// Which one-time pre-key (if any) was consumed.
        let usedOneTimePreKeyId: UInt32?
    }
}
