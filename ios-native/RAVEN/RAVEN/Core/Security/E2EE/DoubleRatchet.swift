//
//  DoubleRatchet.swift
//  RAVEN
//
//  Pure functions implementing the Signal Double Ratchet spec
//  (https://signal.org/docs/specifications/doubleratchet/).
//
//  These functions take a `RatchetState` inout, mutate it, and produce
//  a `RatchetCiphertext` (encrypt) or plaintext (decrypt). Storage,
//  routing, and concurrency live one layer up in E2EEService.
//
//  Properties this gives us:
//   • Forward secrecy — every message uses a fresh key derived from
//     the chain key; once advanced, prior keys are unrecoverable.
//   • Post-compromise security — once a peer's DH ratchet step lands,
//     the next root key includes brand-new DH output, so a passive
//     attacker who stole an old state cannot keep reading.
//   • Out-of-order delivery — receiver caches up to N skipped message
//     keys so messages that arrive late still decrypt.
//

import Foundation
import CryptoKit

enum DoubleRatchet {

    // MARK: - Encrypt

    /// Encrypt a single message under the current sending chain.
    /// Advances `Ns`, derives a fresh message key, and returns the
    /// header-bound ciphertext.
    ///
    /// Pre-condition: the session has a sending chain. Initiator side
    /// has one immediately after `RatchetState.initialiseAsInitiator`.
    /// Responder side gets one after their first DH-ratchet send step
    /// (handled inside this function).
    static func encrypt(
        state: inout RatchetState,
        plaintext: Data,
        associatedData externalAD: Data
    ) throws -> RatchetCiphertext {
        // Lazy DH-ratchet send step — happens on responder's first reply.
        if state.sendingChainKey == nil {
            try performSendingDHRatchet(state: &state)
        }

        guard let chainKey = state.sendingChainKey else {
            throw RatchetError.sessionNotInitialised
        }

        // Step the chain key, derive the message key.
        let (newChain, messageKey) = RatchetCrypto.kdfChainKey(chainKey)
        state.sendingChainKey = newChain

        // Build the header.
        let header = RatchetHeader(
            dh: state.DHs.publicKey.rawRepresentation,
            pn: state.PN,
            n:  state.Ns
        )
        state.Ns &+= 1   // wrap-safe; in practice we'll never overflow

        // AEAD with header bound as Associated Data.
        let headerAD = try header.canonicalAssociatedData()
        var fullAD = externalAD
        fullAD.append(headerAD)

        let body = try RatchetCrypto.aeadEncrypt(
            plaintext: plaintext,
            messageKey: messageKey,
            associatedData: fullAD
        )

        return RatchetCiphertext(header: header, body: body)
    }

    // MARK: - Decrypt

    /// Decrypt one inbound message. Handles three cases:
    ///   1. Header DH matches state.DHr  — normal in-order receive.
    ///   2. Header DH is new             — DH-ratchet receive step,
    ///      then in-order receive.
    ///   3. Message number is in the past — pull from skipped cache.
    static func decrypt(
        state: inout RatchetState,
        ciphertext: RatchetCiphertext,
        associatedData externalAD: Data
    ) throws -> Data {
        // Case 3: skipped key already cached.
        let skippedID = SkippedKeyID(dh: ciphertext.header.dh, n: ciphertext.header.n)
        if let cachedKey = state.skippedMessageKeys.removeValue(forKey: skippedID) {
            return try aeadOpen(
                ciphertext: ciphertext,
                key: cachedKey,
                externalAD: externalAD
            )
        }

        // Case 2: peer rotated their DH key.
        if ciphertext.header.dh != state.DHr {
            try skipReceivingMessageKeys(state: &state, until: ciphertext.header.pn)
            try performReceivingDHRatchet(state: &state, peerDH: ciphertext.header.dh)
        }

        // Case 1: in-order (or close to it) — skip up to header.n,
        // derive the matching key, decrypt.
        try skipReceivingMessageKeys(state: &state, until: ciphertext.header.n)

        guard let chainKey = state.receivingChainKey else {
            throw RatchetError.sessionNotInitialised
        }
        let (newChain, messageKey) = RatchetCrypto.kdfChainKey(chainKey)
        state.receivingChainKey = newChain
        state.Nr &+= 1

        return try aeadOpen(
            ciphertext: ciphertext,
            key: messageKey,
            externalAD: externalAD
        )
    }

    // MARK: - DH ratchet steps

    /// Receiver-side DH ratchet: peer sent a new DH pubkey.
    /// 1. Compute DH(ourOldDHs, peerNewDH) → derive new receiving chain.
    /// 2. Generate fresh ourNewDHs.
    /// 3. Compute DH(ourNewDHs, peerNewDH) → derive new sending chain.
    /// 4. Reset counters; remember PN.
    private static func performReceivingDHRatchet(
        state: inout RatchetState,
        peerDH: Data
    ) throws {
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerDH)

        // First leg: receive chain from old DHs ↔ new peer DH.
        let dh1 = try state.DHs.sharedSecretFromKeyAgreement(with: peerKey)
        let (rk1, recvChain) = RatchetCrypto.kdfRootKey(rootKey: state.rootKey, dhOutput: dh1)

        state.PN = state.Ns        // bookkeeping for the chain we're closing
        state.Ns = 0
        state.Nr = 0
        state.DHr = peerDH
        state.receivingChainKey = recvChain

        // Second leg: new send chain from fresh DHs ↔ peer new DH.
        let newDHs = Curve25519.KeyAgreement.PrivateKey()
        let dh2 = try newDHs.sharedSecretFromKeyAgreement(with: peerKey)
        let (rk2, sendChain) = RatchetCrypto.kdfRootKey(rootKey: rk1, dhOutput: dh2)

        state.DHs = newDHs
        state.rootKey = rk2
        state.sendingChainKey = sendChain
    }

    /// Sender-side DH ratchet — only used by the responder right
    /// before their *first* outbound message. Responder has DHr set
    /// (it's the initiator's first DH key) but no sending chain yet.
    private static func performSendingDHRatchet(state: inout RatchetState) throws {
        guard let dhrData = state.DHr else {
            // No peer DH known — we're the initiator and got initialised
            // with a sending chain already. This branch should be
            // unreachable, but throw defensively.
            throw RatchetError.sessionNotInitialised
        }
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: dhrData)
        let newDHs = Curve25519.KeyAgreement.PrivateKey()
        let dhOut = try newDHs.sharedSecretFromKeyAgreement(with: peerKey)
        let (newRoot, sendChain) = RatchetCrypto.kdfRootKey(rootKey: state.rootKey, dhOutput: dhOut)

        state.PN = state.Ns
        state.Ns = 0
        state.DHs = newDHs
        state.rootKey = newRoot
        state.sendingChainKey = sendChain
    }

    // MARK: - Skipped keys

    /// Walk the receiving chain forward, caching message keys along
    /// the way, until we reach `until`. Caps the cache size to defeat
    /// memory-blowup DoS.
    private static func skipReceivingMessageKeys(
        state: inout RatchetState,
        until: UInt32
    ) throws {
        guard let dhrData = state.DHr else {
            // Nothing to skip — first message ever from this peer.
            return
        }
        guard state.receivingChainKey != nil else { return }

        // Bound the gap: an attacker can fabricate huge n values to
        // force expensive HMAC iterations. Cap at the cache limit.
        let gap = Int64(until) - Int64(state.Nr)
        if gap > Int64(RatchetState.maxSkippedKeysPerSession) {
            throw RatchetError.skippedKeyLimitExceeded
        }

        while state.Nr < until {
            guard let chainKey = state.receivingChainKey else { return }
            let (newChain, messageKey) = RatchetCrypto.kdfChainKey(chainKey)
            state.receivingChainKey = newChain

            let id = SkippedKeyID(dh: dhrData, n: state.Nr)
            state.skippedMessageKeys[id] = messageKey
            state.Nr &+= 1

            if state.skippedMessageKeys.count > RatchetState.maxSkippedKeysPerSession {
                throw RatchetError.skippedKeyLimitExceeded
            }
        }
    }

    // MARK: - AEAD wrapper

    private static func aeadOpen(
        ciphertext: RatchetCiphertext,
        key: SymmetricKey,
        externalAD: Data
    ) throws -> Data {
        let headerAD = try ciphertext.header.canonicalAssociatedData()
        var fullAD = externalAD
        fullAD.append(headerAD)
        return try RatchetCrypto.aeadDecrypt(
            ciphertext: ciphertext.body,
            messageKey: key,
            associatedData: fullAD
        )
    }
}
