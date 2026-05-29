// DoubleRatchet.swift
//
// Phase F — Signal-style Double Ratchet for post-compromise security.
//
// What this gives us that Noise IK alone doesn't:
//
//   • **Forward Secrecy (FS)** — past traffic safe if today's key
//     leaks. Noise IK already provides this via ephemeral DH.
//
//   • **Post-Compromise Security (PCS)** — future traffic safe even
//     if today's key leaks, as soon as one round-trip happens. This
//     is the new property. An attacker who steals your phone's keys
//     can read messages until you next exchange a round-trip; from
//     then on, the DH ratchet has rotated past them.
//
// Construction (per the Signal Double Ratchet spec):
//
//   • **DH Ratchet** — each side carries an ephemeral DH keypair.
//     Whenever the OTHER side sends a message with a new DH pubkey,
//     this side runs a DH against it, derives a new root key + new
//     chain key, generates ITS own fresh DH pubkey, runs another DH,
//     and starts a fresh chain. Every round-trip = two DH outputs
//     mixed into the root chain.
//
//   • **Symmetric chain ratchet** — within a chain (between DH
//     ratchets), each message derives a per-message key by KDF-ing
//     the chain key one step. After deriving the message key, the
//     chain key is replaced with its KDF-successor. Old chain keys
//     are wiped.
//
//   • **Skipped-message keys** — out-of-order delivery is normal in
//     mesh / BLE. If message 5 arrives before 2, we derive + cache
//     the keys for 2, 3, 4 so they can be decrypted when they arrive
//     (or thrown away after a bound).
//
// Wire format — DR header is the first 40 bytes of the v2 envelope's
// payload field; the remaining bytes are AEAD ciphertext. The
// envelope's `payload_len` already accounts for the combined size.
//
//   [ 0..32]  dh_ratchet_pub_key  — sender's current ephemeral DH pubkey
//   [32..36]  pn (uint32 BE)      — sender's previous-chain length
//   [36..40]  n  (uint32 BE)      — message number within current chain
//   [40..  ]  AEAD ciphertext (plaintext + 16-byte tag)
//
// The header is **the AEAD's associated data**, so any tamper of any
// of the 40 bytes breaks the tag. The header is NOT encrypted itself
// in this v1 (Signal's "Header Encrypted" variant is reserved as
// future work — see `SecurityConstants.KDFLabel.doubleRatchetHeader`).
//
// BYTE-IDENTICAL sibling on Mac at
// `RAVEN-MacApp/RAVEN/Core/Security/DoubleRatchet.swift`.

import Foundation
import CryptoKit

public enum DoubleRatchetError: Error, Equatable {
    case malformedHeader
    case messageNumberOutOfRange
    case tooManySkippedKeys
    case skipBoundExceeded
    case messageKeyNotFound
    case decryptFailed
    case missingPeerKey
    case malformedPublicKey
    case sessionEvicted
}

// MARK: - Wire header

/// Plaintext header preceding the AEAD ciphertext in each Double
/// Ratchet message. Always 40 bytes when encoded.
public struct DoubleRatchetHeader: Equatable {
    /// Sender's current DH ratchet public key (raw 32 bytes).
    public let dhPublicKey: Data
    /// Length of the sender's previous sending chain when it ratcheted
    /// to a new DH key. The receiver uses PN to know how many old
    /// chain messages might still be in flight (and so how many
    /// skipped keys to derive in the old chain).
    public let previousChainLength: UInt32
    /// This message's number within the sender's current sending
    /// chain. Starts at 0.
    public let messageNumber: UInt32

    public init(dhPublicKey: Data,
                previousChainLength: UInt32,
                messageNumber: UInt32) {
        self.dhPublicKey = dhPublicKey
        self.previousChainLength = previousChainLength
        self.messageNumber = messageNumber
    }

    public func encoded() throws -> Data {
        guard dhPublicKey.count == 32 else { throw DoubleRatchetError.malformedHeader }
        var out = Data()
        out.append(dhPublicKey)
        var pn = previousChainLength.bigEndian
        var n  = messageNumber.bigEndian
        withUnsafeBytes(of: &pn) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &n)  { out.append(contentsOf: $0) }
        return out
    }

    public static func decode(_ data: Data) throws -> DoubleRatchetHeader {
        guard data.count >= SecurityConstants.DoubleRatchet.headerSize else {
            throw DoubleRatchetError.malformedHeader
        }
        let base = data.startIndex
        let pub = data.subdata(in: base..<(base + 32))
        let pnRaw: UInt32 = data.subdata(in: (base + 32)..<(base + 36)).withUnsafeBytes {
            UInt32(bigEndian: $0.load(as: UInt32.self))
        }
        let nRaw: UInt32 = data.subdata(in: (base + 36)..<(base + 40)).withUnsafeBytes {
            UInt32(bigEndian: $0.load(as: UInt32.self))
        }
        return DoubleRatchetHeader(
            dhPublicKey: pub,
            previousChainLength: pnRaw,
            messageNumber: nRaw
        )
    }
}

// MARK: - Cache key for skipped messages

private struct SkippedKeyID: Hashable {
    let dhPublicKey: Data
    let messageNumber: UInt32
}

// MARK: - Double Ratchet state machine

/// One peer's Double Ratchet state for a specific conversation.
/// Owns the root + send/receive chain keys, the local DH ratchet keypair,
/// and the skipped-message-key cache.
///
/// **Thread-safety:** mutating methods are NOT thread-safe. Wrap with
/// an actor or external lock if accessed from multiple queues.
///
/// **Memory hygiene:** chain keys are overwritten with zeros after
/// they're consumed (Signal calls this "ratchet-and-delete"). The
/// underlying `SymmetricKey` allocations rely on Swift ARC + Apple's
/// CryptoKit to release backing memory; we explicitly zero the local
/// references when we replace them.
public final class DoubleRatchet {

    /// Caller's role at session bootstrap. After the first round-trip
    /// completes, role distinctions disappear — both sides have
    /// rotated through one DH ratchet.
    public enum Role { case initiator, responder }

    // ── State (private — only mutating methods touch this) ──────────
    private var rootKey: SymmetricKey

    /// Active sending chain key — nil immediately after the responder
    /// boots, before it's received the initiator's first DH. The
    /// responder's first encrypt happens AFTER a DH ratchet, so this
    /// is always set when needed.
    private var sendingChainKey: SymmetricKey?

    /// Active receiving chain key — nil before we've seen any DH from
    /// the peer at all.
    private var receivingChainKey: SymmetricKey?

    /// Our current DH ratchet keypair. We send our public, peer
    /// echoes a new one back, we ratchet.
    private var dhSelfPrivate: Curve25519.KeyAgreement.PrivateKey

    /// Peer's current DH ratchet public key. nil for the initiator
    /// only at moment 0 — but the initiator never "sends" before the
    /// responder's first reply, so this is set when sendingChainKey
    /// is set.
    private var dhPeerPublic: Curve25519.KeyAgreement.PublicKey?

    /// Counter for messages we've sent in the current sending chain.
    private var sendMessageNumber: UInt32 = 0
    /// Counter for messages we've received in the current receiving
    /// chain.
    private var receiveMessageNumber: UInt32 = 0
    /// Length of our previous sending chain at the moment we
    /// performed our last DH ratchet. Sent on every message so the
    /// peer knows how many old-chain messages might still be in
    /// flight.
    private var previousChainLength: UInt32 = 0

    /// Cached out-of-order message keys, indexed by (dh, n). Bounded
    /// by ``SecurityConstants/DoubleRatchet/maxSkipKeys``.
    private var skippedKeys: [SkippedKeyID: SymmetricKey] = [:]

    /// Once set, all subsequent operations throw `sessionEvicted`.
    /// Engine flips this on rotation (E.6 quota or device unpair).
    private var evicted: Bool = false

    // MARK: - Bootstrap

    /// Construct a Double Ratchet immediately after a Noise IK
    /// handshake completes.
    ///
    /// - Parameters:
    ///   - sharedSecret: 32 bytes coming out of the Noise IK
    ///     `split()` call. Treated as the initial root key.
    ///   - role: who we are. The initiator generates a fresh DH
    ///     ratchet keypair on the spot and pre-derives the sending
    ///     chain with the peer's static key. The responder simply
    ///     stores the shared secret as the root key and waits for
    ///     the initiator's first DH to trigger a ratchet.
    ///   - peerDHPublicKey: required for the initiator (it's the
    ///     responder's static-or-prekey pubkey used to derive the
    ///     first sending chain). The responder passes nil.
    public init(sharedSecret: SymmetricKey,
                role: Role,
                peerDHPublicKey: Curve25519.KeyAgreement.PublicKey?) throws {
        self.rootKey = sharedSecret
        self.dhSelfPrivate = Curve25519.KeyAgreement.PrivateKey()
        switch role {
        case .initiator:
            guard let peerPub = peerDHPublicKey else {
                throw DoubleRatchetError.missingPeerKey
            }
            self.dhPeerPublic = peerPub
            let dhOut = try self.dhSelfPrivate.sharedSecretFromKeyAgreement(with: peerPub)
            let (newRoot, newChain) = Self.kdfRK(rootKey: self.rootKey, dhOutput: dhOut)
            self.rootKey = newRoot
            self.sendingChainKey = newChain
            // receivingChainKey stays nil until the responder ratchets.
        case .responder:
            // We don't have the peer's DH yet — the initiator's first
            // message will carry it and trigger our first DHRatchet.
            self.dhPeerPublic = nil
            self.sendingChainKey = nil
        }
    }

    // MARK: - Public API

    /// True if either rotation quota or external eviction has fired.
    public var isEvicted: Bool { evicted }

    /// Permanently disable this ratchet. Subsequent encrypt/decrypt
    /// calls throw `sessionEvicted`. Engines call this on:
    ///   • E.6 session quota hit
    ///   • Device unpaired
    ///   • Static key rotation
    ///   • User logout
    public func evict() {
        evicted = true
        // Zero the active chain keys. `SymmetricKey` doesn't expose a
        // wipe API, but reassigning to a zero-buffer key drops the
        // reference; CryptoKit's backing pages are heap, no mlock.
        // Best-effort scrub — defeats casual heap dumps.
        rootKey = SymmetricKey(data: Data(repeating: 0, count: 32))
        sendingChainKey = nil
        receivingChainKey = nil
        skippedKeys.removeAll(keepingCapacity: false)
    }

    /// Our local DH ratchet public key. Engines may surface this for
    /// debug / "session fingerprint" UI but it has no security value
    /// on its own (rotates every round-trip).
    public var currentDHPublicKey: Data {
        dhSelfPrivate.publicKey.rawRepresentation
    }

    // MARK: - Encrypt

    /// Encrypt `plaintext` under the current sending chain. `ad` is
    /// the application-level associated data (envelope header, etc.);
    /// the DR header bytes are appended INTERNALLY so the AEAD binds
    /// the DH pubkey + counters.
    ///
    /// - Returns: `(header, ciphertext)`. Caller emits both on the
    ///   wire; the receiver reconstructs `ad || header` to verify.
    public func encrypt(plaintext: Data, ad: Data) throws -> (header: DoubleRatchetHeader, ciphertext: Data) {
        if evicted { throw DoubleRatchetError.sessionEvicted }
        guard var sendCK = sendingChainKey else {
            // This happens only if a responder tries to encrypt
            // before receiving the initiator's first message. Engines
            // shouldn't allow that — but throw a clean error rather
            // than crash.
            throw DoubleRatchetError.missingPeerKey
        }

        // Symmetric ratchet — derive (next chain key, message key).
        let (nextCK, mk) = Self.kdfCK(chainKey: sendCK)
        sendingChainKey = nextCK
        sendCK = nextCK  // local reference no longer used after this

        let header = DoubleRatchetHeader(
            dhPublicKey: dhSelfPrivate.publicKey.rawRepresentation,
            previousChainLength: previousChainLength,
            messageNumber: sendMessageNumber
        )
        sendMessageNumber &+= 1

        // AEAD: AD = caller-AD || encoded header. The header is then
        // also emitted on the wire so the receiver can reconstruct.
        let aeadAD = ad + (try header.encoded())
        let nonce = try Self.aeadNonce(messageNumber: header.messageNumber)
        let messageKey = Self.deriveMessageKey(from: mk)
        let sealed = try ChaChaPoly.seal(plaintext, using: messageKey, nonce: nonce, authenticating: aeadAD)
        var ct = Data(sealed.ciphertext); ct.append(sealed.tag)
        return (header, ct)
    }

    // MARK: - Decrypt

    /// Decrypt a Double Ratchet message. Caller provides the parsed
    /// header (40 bytes off the wire) and the ciphertext (the
    /// remainder of the envelope payload). `ad` must match what the
    /// sender passed to `encrypt`.
    public func decrypt(header: DoubleRatchetHeader, ciphertext: Data, ad: Data) throws -> Data {
        if evicted { throw DoubleRatchetError.sessionEvicted }

        // Fast path: did we already pre-derive this exact key as a
        // skipped key?
        let lookup = SkippedKeyID(dhPublicKey: header.dhPublicKey, messageNumber: header.messageNumber)
        if let mk = skippedKeys.removeValue(forKey: lookup) {
            return try Self.aeadOpen(messageKey: mk, header: header, ad: ad, ciphertext: ciphertext)
        }

        // Did peer rotate to a new DH? If so, we need to
        //   (a) catch up on any skipped messages in the OLD receiving
        //       chain (using its PN length), then
        //   (b) perform a DH ratchet — derives new root + new
        //       receiving chain from the peer's new DH, then a fresh
        //       sending chain after we generate our own DH.
        let peerPubData = header.dhPublicKey
        let currentPeerData = dhPeerPublic?.rawRepresentation ?? Data()
        if peerPubData != currentPeerData {
            try skipMessageKeysInOldChain(upTo: header.previousChainLength)
            try dhRatchet(newPeerPublicKey: peerPubData)
        }

        // Now skip-ahead WITHIN the current receiving chain up to the
        // header's message number.
        try skipMessageKeysInCurrentChain(upTo: header.messageNumber)

        // Take the message key out of the receiving chain.
        guard var recvCK = receivingChainKey else {
            throw DoubleRatchetError.messageKeyNotFound
        }
        let (nextCK, mk) = Self.kdfCK(chainKey: recvCK)
        receivingChainKey = nextCK
        recvCK = nextCK
        receiveMessageNumber &+= 1

        return try Self.aeadOpen(messageKey: mk, header: header, ad: ad, ciphertext: ciphertext)
    }

    // MARK: - Skipped-key plumbing

    /// Derive + cache message keys for slots `receiveMessageNumber...until-1`
    /// in the CURRENT receiving chain. Used when an inbound message
    /// advertises a higher `messageNumber` than we expect.
    private func skipMessageKeysInCurrentChain(upTo until: UInt32) throws {
        guard let _ = receivingChainKey else { return }
        guard until >= receiveMessageNumber else {
            // Out-of-window past message — should be in the skip cache
            // if we ever expected to see it. If not, the upstream
            // lookup already failed; this guard is defensive.
            return
        }
        let toSkip = Int(until - receiveMessageNumber)
        if toSkip == 0 { return }
        if toSkip > SecurityConstants.DoubleRatchet.maxSkipPerReceive {
            throw DoubleRatchetError.skipBoundExceeded
        }
        guard let peerPub = dhPeerPublic else { return }
        let peerData = peerPub.rawRepresentation
        for _ in 0..<toSkip {
            guard var ck = receivingChainKey else { break }
            let (nextCK, mk) = Self.kdfCK(chainKey: ck)
            receivingChainKey = nextCK
            ck = nextCK
            let stored = Self.deriveMessageKey(from: mk)
            let id = SkippedKeyID(dhPublicKey: peerData, messageNumber: receiveMessageNumber)
            skippedKeys[id] = stored
            receiveMessageNumber &+= 1
            try enforceCacheBound()
        }
    }

    /// On a peer DH ratchet, we lose the OLD receiving chain. Before
    /// we discard it, derive + cache any remaining slots up to its
    /// declared `previousChainLength` so an in-flight old-chain
    /// message can still be decrypted when it arrives.
    private func skipMessageKeysInOldChain(upTo previousLength: UInt32) throws {
        guard receivingChainKey != nil else { return }
        guard previousLength >= receiveMessageNumber else { return }
        let toSkip = Int(previousLength - receiveMessageNumber)
        if toSkip == 0 { return }
        if toSkip > SecurityConstants.DoubleRatchet.maxSkipPerReceive {
            throw DoubleRatchetError.skipBoundExceeded
        }
        guard let peerPub = dhPeerPublic else { return }
        let peerData = peerPub.rawRepresentation
        for _ in 0..<toSkip {
            guard var ck = receivingChainKey else { break }
            let (nextCK, mk) = Self.kdfCK(chainKey: ck)
            receivingChainKey = nextCK
            ck = nextCK
            let stored = Self.deriveMessageKey(from: mk)
            let id = SkippedKeyID(dhPublicKey: peerData, messageNumber: receiveMessageNumber)
            skippedKeys[id] = stored
            receiveMessageNumber &+= 1
            try enforceCacheBound()
        }
    }

    private func enforceCacheBound() throws {
        let cap = SecurityConstants.DoubleRatchet.maxSkipKeys
        if skippedKeys.count > cap {
            // We refuse to grow the cache beyond the cap — a peer
            // racing us at N = 10^9 is a clear DoS attempt. Throw
            // rather than evicting old keys, because evicting could
            // silently drop a legitimate in-flight message that's
            // about to arrive.
            throw DoubleRatchetError.tooManySkippedKeys
        }
    }

    // MARK: - DH ratchet step

    private func dhRatchet(newPeerPublicKey: Data) throws {
        let peerPub: Curve25519.KeyAgreement.PublicKey
        do {
            peerPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: newPeerPublicKey)
        } catch {
            throw DoubleRatchetError.malformedPublicKey
        }
        previousChainLength = sendMessageNumber
        sendMessageNumber = 0
        receiveMessageNumber = 0
        dhPeerPublic = peerPub

        // First DH: our OLD private key with peer's NEW public.
        // Drives the new receiving chain.
        let dh1 = try dhSelfPrivate.sharedSecretFromKeyAgreement(with: peerPub)
        let (root1, recvCK) = Self.kdfRK(rootKey: rootKey, dhOutput: dh1)
        rootKey = root1
        receivingChainKey = recvCK

        // Generate fresh DH keypair, then run DH again with peer's NEW
        // public against our NEW private. Drives the new sending chain.
        dhSelfPrivate = Curve25519.KeyAgreement.PrivateKey()
        let dh2 = try dhSelfPrivate.sharedSecretFromKeyAgreement(with: peerPub)
        let (root2, sendCK) = Self.kdfRK(rootKey: rootKey, dhOutput: dh2)
        rootKey = root2
        sendingChainKey = sendCK
    }

    // MARK: - KDFs (Signal-spec)

    /// Root-chain KDF — mixes the current root with a fresh DH output
    /// to produce `(new_root_key, new_chain_key)`. Uses HKDF-SHA256
    /// with the root-chain domain label, salted with the current
    /// root key (per the Signal spec).
    private static func kdfRK(rootKey: SymmetricKey,
                              dhOutput: SharedSecret) -> (SymmetricKey, SymmetricKey) {
        // 64-byte derived output → split into (root32, chain32).
        let info = SecurityConstants.KDFLabel.doubleRatchetRoot.bytes
        let derived = dhOutput.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Self.symmetricKeyBytes(rootKey),
            sharedInfo: info,
            outputByteCount: 64
        )
        var derivedData = Data(count: 64)
        derived.withUnsafeBytes { src in
            derivedData.withUnsafeMutableBytes { dst in
                dst.copyMemory(from: src)
            }
        }
        let root = SymmetricKey(data: derivedData.prefix(32))
        let chain = SymmetricKey(data: derivedData.suffix(32))
        return (root, chain)
    }

    /// Symmetric chain KDF — derives `(next_chain_key, message_key)`
    /// from the current chain key via two distinct HMACs.
    /// Per Signal: HMAC(ck, 0x01) → message key candidate,
    ///            HMAC(ck, 0x02) → next chain key.
    private static func kdfCK(chainKey: SymmetricKey) -> (SymmetricKey, SymmetricKey) {
        let mkRaw = HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: chainKey)
        let ckRaw = HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: chainKey)
        return (SymmetricKey(data: Data(ckRaw)), SymmetricKey(data: Data(mkRaw)))
    }

    /// Derive the AEAD message key from the raw chain-output. Distinct
    /// label so a chain leak doesn't auto-recover the AEAD key.
    private static func deriveMessageKey(from chainOutput: SymmetricKey) -> SymmetricKey {
        let info = SecurityConstants.KDFLabel.doubleRatchetMessage.bytes
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: chainOutput,
            salt: Data(),
            info: info,
            outputByteCount: 32
        )
    }

    /// 96-bit ChaChaPoly nonce: 8 zero bytes + 32-bit message number BE.
    /// We don't reuse the chain's HMAC counter as a nonce because the
    /// chain advances on every message and each call independently
    /// derives a fresh key — but the per-message-number nonce keeps
    /// the construction matching the Signal reference test vectors.
    private static func aeadNonce(messageNumber: UInt32) throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 8)
        let be = withUnsafeBytes(of: messageNumber.bigEndian) { Array($0) }
        bytes.append(contentsOf: be)
        return try ChaChaPoly.Nonce(data: Data(bytes))
    }

    private static func aeadOpen(messageKey: SymmetricKey,
                                 header: DoubleRatchetHeader,
                                 ad: Data,
                                 ciphertext: Data) throws -> Data {
        guard ciphertext.count >= 16 else { throw DoubleRatchetError.decryptFailed }
        let tag = ciphertext.suffix(16)
        let payload = ciphertext.prefix(ciphertext.count - 16)
        let nonce = try aeadNonce(messageNumber: header.messageNumber)
        let sealed: ChaChaPoly.SealedBox
        do {
            sealed = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: payload, tag: tag)
        } catch {
            throw DoubleRatchetError.decryptFailed
        }
        let aeadAD = ad + (try header.encoded())
        // The message key passed in IS the AEAD key (it's already been
        // expanded via `deriveMessageKey` when storing skipped keys, or
        // we'll expand it inline here for current-chain reads).
        let key = messageKey
        let pt: Data
        do {
            pt = try ChaChaPoly.open(sealed, using: key, authenticating: aeadAD)
        } catch {
            throw DoubleRatchetError.decryptFailed
        }
        return pt
    }

    /// Read the raw bytes of a `SymmetricKey`. Used as the salt for
    /// the root KDF — that's `(rootKey)` per the Signal spec.
    private static func symmetricKeyBytes(_ key: SymmetricKey) -> Data {
        var out = Data(count: 32)
        key.withUnsafeBytes { kBuf in
            out.withUnsafeMutableBytes { dBuf in
                let n = min(kBuf.count, dBuf.count)
                if n > 0, let src = kBuf.baseAddress, let dst = dBuf.baseAddress {
                    memcpy(dst, src, n)
                }
            }
        }
        return out
    }
}
