//
//  ATSAMChainRatchet.swift
//  RAVEN — ATSAM
//
//  Forward secrecy for ATSAM message sealing (wire protocol v2).
//
//  THE PROBLEM THIS SOLVES
//  ----------------------
//  ATSAM v1 derives every message key as a deterministic function of the
//  long-lived pairing root:
//
//      K_msg = HKDF(seed(K_root), sender ‖ recipient ‖ msgId)
//
//  `msgId` makes each key distinct, which bounds the blast radius of a nonce
//  collision — but it provides NO forward secrecy. Every input except K_root
//  travels in the clear, so an adversary who later extracts K_root from a
//  device can recompute every message key that pair ever used and decrypt the
//  entire archived conversation. The v1 header said "forward secrecy" about
//  its fresh nonces; that was wrong, and the public protocol page now says so.
//
//  THE CONSTRUCTION
//  ----------------
//  A symmetric chain ratchet, one chain per (pair, direction):
//
//      CK₀^{S→R} = HKDF(K_root, info = "ATSAM/v2/chain-init" ‖ 0 ‖ S ‖ 0 ‖ R)
//      K_msg,i   = HKDF(CK_i,  salt = "ATSAM/v2/msg-seal/salt",
//                              info = "ATSAM/v2/msg-key" ‖ 0 ‖ S ‖ 0 ‖ R ‖ 0 ‖ msgId)
//      CK_{i+1}  = HKDF(CK_i,  info = "ATSAM/v2/chain-advance")
//
//  After a message at index i is sealed or opened, CK_i is overwritten by
//  CK_{i+1} and the old chain key is gone. HKDF is one-way, so CK_{i+1} does
//  not reveal CK_i, and therefore does not reveal K_msg,i. That is the forward
//  secrecy: a device seized at index 400 cannot produce the keys for messages
//  1…399, because the material required to derive them no longer exists
//  anywhere.
//
//  Direction separation falls out of the ordered (S, R) pair in the chain-init
//  info string: A→B and B→A start from different chain keys, so a reflected
//  ciphertext cannot authenticate.
//
//  WHY THIS IS HARDER HERE THAN IN A NORMAL MESSENGER
//  --------------------------------------------------
//  RAVEN is delay-tolerant. Messages legitimately arrive out of order, and a
//  message carried by a mesh mule can surface days after later ones. A naive
//  ratchet drops all of them. So the receiver keeps a bounded cache of skipped
//  message keys: when index i arrives ahead of the expected index, the keys for
//  the gap are derived, stored, and the chain advances past them. A late
//  message then finds its key in the cache — and the key is DELETED on use, so
//  a replay of the same index fails and forward secrecy is preserved for
//  everything already consumed.
//
//  The cache is bounded (`maxSkippedKeys`) and so is a single forward jump
//  (`maxForwardJump`). Without those bounds a hostile peer could send index
//  2³²−1 and force four billion HKDF invocations, or pin unbounded key
//  material in the Keychain. Exceeding either bound is a hard reject.
//
//  HONEST LIMITS
//  -------------
//  • A message delayed beyond `maxSkippedKeys` messages of traffic in the same
//    direction is undecryptable — permanently. This is a real trade-off against
//    v1's "always decryptable, never forward secret". It is the correct trade
//    for a security protocol, but it is a trade.
//  • Forward secrecy here is per-message-key, not post-compromise security. An
//    adversary who steals K_root can still derive all FUTURE chain state. Full
//    post-compromise security needs a DH ratchet, which needs a round trip the
//    mesh cannot guarantee. Out of scope, and not claimed.
//  • State is per-device. A second device paired to the same peer runs its own
//    chains.
//

import Foundation
import CryptoKit

// MARK: - Labels

extension ATSAMConstants.KDFLabel {
    /// Seeds a directional chain from the pairing root.
    static let chainInit = ATSAMConstants.KDFLabel(rawValue: "ATSAM/v2/chain-init")
    /// Derives the per-message AEAD key from the current chain key.
    static let chainMsgKey = ATSAMConstants.KDFLabel(rawValue: "ATSAM/v2/msg-key")
    /// Advances the chain. One-way: CK_{i+1} reveals nothing about CK_i.
    static let chainAdvance = ATSAMConstants.KDFLabel(rawValue: "ATSAM/v2/chain-advance")
}

// MARK: - Errors

enum ATSAMRatchetError: Error, Equatable {
    /// Index is further ahead than `maxForwardJump`. Either a hostile peer
    /// trying to burn CPU, or a chain desync that a re-pair must resolve.
    case forwardJumpTooLarge(requested: UInt32, limit: UInt32)
    /// Index is behind the chain and no cached key exists: already consumed
    /// (replay), or evicted for being too old.
    case keyUnavailable(index: UInt32)
    /// Chain state could not be persisted — fail closed rather than seal under
    /// a key we cannot reproduce.
    case stateNotPersisted
}

// MARK: - Chain state

/// One direction of one pair's ratchet.
///
/// `Sendable` and value-typed on purpose: the storage actor owns the canonical
/// copy, and callers mutate a local copy that is only committed after the
/// cryptography has succeeded. That ordering is what stops a malformed inbound
/// frame from advancing a victim's chain (see `ATSAMChainRatchet.openKey`).
struct ATSAMChainState: Sendable, Equatable {

    /// Current chain key. Overwritten on every advance; the prior value is not
    /// retained anywhere.
    private(set) var chainKey: Data

    /// Index the chain key corresponds to — i.e. the next index this chain can
    /// derive directly.
    private(set) var index: UInt32

    /// Message keys derived past-but-not-yet-used, so out-of-order delivery
    /// still opens. Keyed by index. Entries are deleted on use.
    private(set) var skipped: [UInt32: Data]

    init(chainKey: Data, index: UInt32 = 0, skipped: [UInt32: Data] = [:]) {
        self.chainKey = chainKey
        self.index = index
        self.skipped = skipped
    }

    // MARK: Mutation (module-internal; all state changes funnel through these)

    fileprivate mutating func advance() {
        chainKey = ATSAMChainRatchet.advanceChainKey(chainKey)
        index &+= 1
    }

    fileprivate mutating func stashSkipped(_ key: Data, at idx: UInt32, cap: Int) {
        skipped[idx] = key
        // Evict oldest first: a late message is far likelier to be recent than
        // ancient, and unbounded growth is both a DoS vector and a forward-
        // secrecy leak (keys that should have been destroyed sticking around).
        while skipped.count > cap, let oldest = skipped.keys.min() {
            skipped.removeValue(forKey: oldest)
        }
    }

    /// Take a cached key, removing it. Removal is the point: it makes a replay
    /// of that index fail, and it destroys the key material.
    fileprivate mutating func takeSkipped(_ idx: UInt32) -> Data? {
        skipped.removeValue(forKey: idx)
    }
}

// MARK: - Persistence encoding

extension ATSAMChainState {

    /// Wire layout (Keychain blob):
    ///   chainKey(32) ‖ index(4 BE) ‖ count(2 BE) ‖ count × [ idx(4 BE) ‖ key(32) ]
    ///
    /// Fixed-width throughout, so decoding needs no length negotiation.
    func encode() -> Data {
        var out = Data()
        out.append(chainKey)
        var idx = index.bigEndian
        withUnsafeBytes(of: &idx) { out.append(contentsOf: $0) }

        // Deterministic order keeps the blob stable for equal states, which
        // makes the Keychain write idempotent and the tests reproducible.
        let entries = skipped.sorted { $0.key < $1.key }
        var count = UInt16(min(entries.count, Int(UInt16.max))).bigEndian
        withUnsafeBytes(of: &count) { out.append(contentsOf: $0) }
        for (i, k) in entries {
            var be = i.bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
            out.append(k)
        }
        return out
    }

    /// Strict decoder. This parses bytes that live outside the process, so it
    /// validates every length rather than trusting the blob — a truncated or
    /// corrupted item must yield nil (and a fresh reseed) instead of a
    /// half-initialised chain.
    static func decode(_ data: Data) -> ATSAMChainState? {
        let keyLen = ATSAMConstants.Sizes.subKeyBytes
        let header = keyLen + 4 + 2
        guard data.count >= header else { return nil }

        let ck = data.subdata(in: 0..<keyLen)
        let idx = data.subdata(in: keyLen..<(keyLen + 4)).withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        }
        let count = Int(data.subdata(in: (keyLen + 4)..<header).withUnsafeBytes {
            UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self))
        })
        guard count <= ATSAMChainRatchet.maxSkippedKeys else { return nil }

        let entrySize = 4 + keyLen
        guard data.count == header + count * entrySize else { return nil }

        var skipped: [UInt32: Data] = [:]
        var cursor = header
        for _ in 0..<count {
            let i = data.subdata(in: cursor..<(cursor + 4)).withUnsafeBytes {
                UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
            }
            skipped[i] = data.subdata(in: (cursor + 4)..<(cursor + entrySize))
            cursor += entrySize
        }
        return ATSAMChainState(chainKey: ck, index: idx, skipped: skipped)
    }
}

// MARK: - Ratchet

enum ATSAMChainRatchet {

    /// Cap on cached skipped keys per direction. 256 messages of same-direction
    /// traffic is a wide reordering window for a mesh; beyond it we would be
    /// storing key material that forward secrecy says should be gone.
    static let maxSkippedKeys: Int = 256

    /// Cap on a single forward jump. Bounds the HKDF work one inbound frame can
    /// force, and bounds how much cache one frame can populate.
    static let maxForwardJump: UInt32 = 256

    // MARK: Derivation

    /// Seed a directional chain from the pairing root.
    ///
    /// The ordered (sender, recipient) pair is what separates the two
    /// directions. NUL-free identifiers are required by the caller, which keeps
    /// the 0x00-separated encoding injective.
    static func initialChainKey(root: ATSAMRootKey,
                                senderUserId: String,
                                recipientUserId: String) -> Data {
        var info = Data()
        info.append(ATSAMConstants.KDFLabel.chainInit.bytes)
        info.append(0x00)
        info.append(Data(senderUserId.utf8))
        info.append(0x00)
        info.append(Data(recipientUserId.utf8))

        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: root._rootBytes),
            info: info,
            outputByteCount: ATSAMConstants.Sizes.subKeyBytes
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    /// One-way chain advance. HKDF's PRF property is what makes CK_{i+1}
    /// useless for recovering CK_i, and hence what makes consumed message keys
    /// unrecoverable.
    static func advanceChainKey(_ chainKey: Data) -> Data {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: chainKey),
            info: ATSAMConstants.KDFLabel.chainAdvance.bytes,
            outputByteCount: ATSAMConstants.Sizes.subKeyBytes
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    /// Derive the AEAD key for one message from a chain key.
    ///
    /// DELIBERATELY NOT a function of `msgId`. A receiver has to derive the keys
    /// for messages that have not arrived yet — that is what the skipped-key
    /// cache is — and it cannot know their identifiers in advance. The only
    /// alternative would be caching the *chain* keys instead, which would be
    /// strictly worse: CK_j yields CK_{j+1}, CK_{j+2}, … so retaining it would
    /// surrender forward secrecy for the entire rest of the conversation.
    ///
    /// The message identifier is instead bound into the AEAD's associated data
    /// by the sealer, which gives the same anti-relabelling guarantee: change
    /// `msgId` and the tag check fails. This is the standard split — key from
    /// the chain, metadata in the AD.
    static func messageKey(chainKey: Data,
                           senderUserId: String,
                           recipientUserId: String) -> SymmetricKey {
        var info = Data()
        info.append(ATSAMConstants.KDFLabel.chainMsgKey.bytes)
        info.append(0x00)
        info.append(Data(senderUserId.utf8))
        info.append(0x00)
        info.append(Data(recipientUserId.utf8))

        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: chainKey),
            salt: Data("ATSAM/v2/msg-seal/salt".utf8),
            info: info,
            outputByteCount: ATSAMConstants.Sizes.subKeyBytes
        )
    }

    // MARK: Send

    /// Produce the next sending key and the state that must be committed
    /// afterwards.
    ///
    /// The caller commits only once the message is actually sealed. If sealing
    /// fails, nothing is committed and the index is simply reused — which is
    /// safe, because no ciphertext under that key ever existed.
    static func sendKey(state: ATSAMChainState,
                        senderUserId: String,
                        recipientUserId: String) -> (index: UInt32, key: SymmetricKey, next: ATSAMChainState) {
        let idx = state.index
        let key = messageKey(chainKey: state.chainKey,
                             senderUserId: senderUserId,
                             recipientUserId: recipientUserId)
        var next = state
        next.advance()
        return (idx, key, next)
    }

    // MARK: Receive

    /// Resolve the key for an inbound index, plus the state to commit *if* the
    /// AEAD subsequently verifies.
    ///
    /// CRITICAL ORDERING: this function is pure and commits nothing. The caller
    /// MUST verify the ciphertext before persisting `next`. If state advanced
    /// on receipt instead, any nearby peer could ship a garbage frame at a high
    /// index and ratchet a victim's chain forward, destroying the keys for
    /// genuine messages still in flight — a trivial remote denial of
    /// communication. Deriving first and committing only on success closes it.
    static func openKey(state: ATSAMChainState,
                        index: UInt32,
                        senderUserId: String,
                        recipientUserId: String) throws -> (key: SymmetricKey, next: ATSAMChainState) {

        var working = state

        // Case 1 — a message we already ratcheted past. Only openable if its
        // key is still cached, and using it consumes it.
        if index < working.index {
            guard let cached = working.takeSkipped(index) else {
                throw ATSAMRatchetError.keyUnavailable(index: index)
            }
            return (SymmetricKey(data: cached), working)
        }

        // Case 2 — ahead of the chain. Derive across the gap, caching the keys
        // for messages that have not arrived yet.
        let jump = index &- working.index
        guard jump <= maxForwardJump else {
            throw ATSAMRatchetError.forwardJumpTooLarge(requested: jump, limit: maxForwardJump)
        }
        while working.index < index {
            let skippedKey = messageKey(chainKey: working.chainKey,
                                        senderUserId: senderUserId,
                                        recipientUserId: recipientUserId)
            let raw = skippedKey.withUnsafeBytes { Data($0) }
            working.stashSkipped(raw, at: working.index, cap: maxSkippedKeys)
            working.advance()
        }

        // Case 3 — exactly the expected index.
        let key = messageKey(chainKey: working.chainKey,
                             senderUserId: senderUserId,
                             recipientUserId: recipientUserId)
        working.advance()
        return (key, working)
    }
}
