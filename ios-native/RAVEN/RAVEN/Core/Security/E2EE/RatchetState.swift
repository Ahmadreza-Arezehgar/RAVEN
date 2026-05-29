//
//  RatchetState.swift
//  RAVEN
//
//  In-memory representation of one Double-Ratchet session. Persistable
//  to SQLite by RatchetSessionStore.
//
//  A session exists between (this device) ↔ (one specific peer device).
//  Multi-device users will have multiple sessions, one per peer device.
//
//  ⚠️ Concurrency: a `RatchetState` is mutated by `encrypt`/`decrypt`,
//  so it must NOT be shared between concurrent calls for the same peer.
//  E2EEService serialises access per peer.
//

import Foundation
import CryptoKit

/// Mutable state of one Double-Ratchet session. Mirrors the symbol
/// names used in the Signal spec to keep the algorithm readable.
struct RatchetState {

    // MARK: - DH ratchet

    /// Our current DH ratchet keypair. We rotate it the first time we
    /// reply after receiving a message that carried a new DH from the
    /// peer.
    var DHs: Curve25519.KeyAgreement.PrivateKey

    /// Peer's current DH ratchet public key. Nil until we've received
    /// at least one message (initiator side starts without it).
    var DHr: Data?

    // MARK: - Symmetric chains

    /// Root key — feeds KDF_RK on every DH ratchet step.
    var rootKey: SymmetricKey

    /// Sending chain key. Nil immediately after a DH-ratchet receive
    /// step until we send our next message.
    var sendingChainKey: SymmetricKey?
    /// Receiving chain key. Nil before we've ever received from the peer.
    var receivingChainKey: SymmetricKey?

    // MARK: - Counters

    /// Next message number we will use when sending.
    var Ns: UInt32 = 0
    /// Next message number we expect when receiving.
    var Nr: UInt32 = 0
    /// Number of messages in our previous sending chain — sent in the
    /// header so the receiver knows how many keys to skip-cache when
    /// they DH-ratchet.
    var PN: UInt32 = 0

    // MARK: - Skipped keys cache

    /// Out-of-order message keys we've derived but not yet consumed.
    /// Bounded by `maxSkippedKeysPerSession` so a malicious peer can't
    /// blow up our memory by replaying huge `n` values.
    var skippedMessageKeys: [SkippedKeyID: SymmetricKey] = [:]

    /// Hard cap on the skipped-keys cache. 1000 covers normal
    /// out-of-order delivery on lossy mesh and is small enough that a
    /// flood is rejected fast.
    static let maxSkippedKeysPerSession = 1000

    // MARK: - Init helpers

    /// Build the initiator's first state right after X3DH. The
    /// initiator owes the responder one message (which kicks off the
    /// DH ratchet on the responder's side).
    static func initialiseAsInitiator(
        sharedSecret SK: SymmetricKey,
        peerSignedPreKey peerSPK: Data
    ) throws -> RatchetState {
        let ourDH = Curve25519.KeyAgreement.PrivateKey()
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerSPK)
        let dhOut = try ourDH.sharedSecretFromKeyAgreement(with: peerKey)
        let (newRoot, sendingChain) = RatchetCrypto.kdfRootKey(rootKey: SK, dhOutput: dhOut)

        return RatchetState(
            DHs: ourDH,
            DHr: peerSPK,
            rootKey: newRoot,
            sendingChainKey: sendingChain,
            receivingChainKey: nil
        )
    }

    /// Build the responder's first state. The responder cannot derive
    /// a sending chain yet — that happens lazily on the first message
    /// they encrypt back, after which a DH ratchet step rotates DHs.
    static func initialiseAsResponder(
        sharedSecret SK: SymmetricKey,
        ourSignedPreKeyPrivate: Curve25519.KeyAgreement.PrivateKey
    ) -> RatchetState {
        return RatchetState(
            DHs: ourSignedPreKeyPrivate,
            DHr: nil,
            rootKey: SK,
            sendingChainKey: nil,
            receivingChainKey: nil
        )
    }
}
