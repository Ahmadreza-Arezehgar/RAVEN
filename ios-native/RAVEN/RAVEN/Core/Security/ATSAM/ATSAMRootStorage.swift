//
//  ATSAMRootStorage.swift
//  RAVEN — ATSAM
//
//  Per-peer storage for hybrid (X25519 + ML-KEM-768) ATSAM root keys.
//
//  Keychain-backed so the root survives app restart AND device reboot.
//  Each peer's root sits at key `raven.atsam.root.<userId>` with
//  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so it never
//  syncs to iCloud Keychain and never crosses devices.
//
//  Why Keychain rather than UserDefaults:
//  - Root key is a 32-byte symmetric secret. Compromise reveals
//    every sub-key derived from it (BBE discovery, Ghost Route,
//    message sealing) → forward secrecy gone for the lifetime
//    of the pair. Keychain at-rest protection limits exposure
//    to user-mode app processes after first unlock.
//  - UserDefaults is a property list, world-readable inside the
//    app sandbox + visible in iTunes backups. Keys this sensitive
//    must never live there.
//
//  Storage layout per peer:
//    raven.atsam.root.<userId>      → 32 bytes (raw root)
//    raven.atsam.transcript.<userId>→ 32 bytes (transcript hash digest)
//
//  Lookup is O(1) per peer via the Keychain query.
//
//  🔴 ROUND 71 phase 3 follow-up #5 (2026-05-24) — Task #44 / #59:
//  introduced as part of the ATSAM-body integration work. Allows
//  `ATSAMMessageSealer` to fetch a peer's root key when sealing a
//  bridged-or-mesh message body, then derive the per-message AEAD
//  key from the existing `ATSAMKeyTree` HKDF tree.
//

import Foundation
import Security
import CryptoKit

/// Per-peer Keychain store for ATSAM root keys + transcript digests.
///
/// Actor-isolated so concurrent seal calls for the same peer hit the
/// in-memory cache instead of racing the Keychain. The cache is
/// best-effort — Keychain remains the canonical store.
actor ATSAMRootStorage {
    static let shared = ATSAMRootStorage()
    private init() {}

    // MARK: - Keychain access group / service

    /// Service string — same value as the Mac sibling so a future
    /// shared-keychain migration would just need to flip the
    /// access-group flag.
    private static let service = "app.raven.ios.atsam.root"

    /// Account format: `root|<userId>` for the 32-byte root key,
    /// `transcript|<userId>` for the 32-byte transcript hash digest.
    /// Keeping them in the same service simplifies the export tooling.
    private static func rootAccount(for userId: String) -> String {
        "root|\(userId)"
    }
    private static func transcriptAccount(for userId: String) -> String {
        "transcript|\(userId)"
    }
    /// v2 ratchet chain state, one row per direction (see ATSAMChainRatchet).
    /// Same service and protection class as the root: this is key material, and
    /// leaking a chain key surrenders forward secrecy from that index onward.
    private static func chainAccount(for userId: String, sending: Bool) -> String {
        "chain|\(sending ? "s" : "r")|\(userId)"
    }

    // MARK: - In-memory cache

    private var rootCache: [String: ATSAMRootKey] = [:]
    private var transcriptCache: [String: ATSAMTranscript] = [:]

    // MARK: - Public API

    /// Store a freshly-paired root key + transcript for a peer.
    /// Overwrites any prior pairing (rotation case — UI should
    /// confirm with the user via Safety Number sheet before
    /// rotating in production).
    ///
    /// 🔴 ROUND 71 phase 3 follow-up #5 hardening (2026-05-24) —
    /// Tasks #57.* / hacker agent #7 finding: ordering matters
    /// on rotation. Pre-fix we'd `kcDelete(root) → SecItemAdd(new)`
    /// then update the in-memory cache. If `SecItemAdd` failed
    /// (locked Keychain / disk-full / sandbox glitch), the cache
    /// still held the OLD root → next seal() succeeded with a key
    /// that no longer matched Keychain truth → cold-start
    /// disagreement between sender and receiver.
    ///
    /// New order:
    ///   1. Invalidate cache for this userId (so concurrent reads
    ///      block + reload from Keychain).
    ///   2. Write transcript FIRST (hacker #8 finding — readers
    ///      gate on root presence; we want transcript ready
    ///      before root is "live").
    ///   3. Write root LAST. On success: populate cache.
    ///   4. On failure: cache is already empty → subsequent
    ///      seal() returns nil (no root) → caller falls back
    ///      safely instead of using a phantom root.
    func setRoot(_ root: ATSAMRootKey,
                 transcript: ATSAMTranscript,
                 for userId: String) async throws {
        guard !userId.isEmpty, !userId.contains("\0") else {
            throw ATSAMRootStorageError.invalidUserId
        }
        let rootBytes = root._rootBytes
        guard rootBytes.count == ATSAMConstants.Sizes.rootKeyBytes else {
            throw ATSAMRootStorageError.invalidRootBytes
        }
        let transcriptBytes = transcript.hash()
        guard transcriptBytes.count == ATSAMConstants.Sizes.transcriptHashBytes else {
            throw ATSAMRootStorageError.invalidTranscriptBytes
        }
        // 1. Invalidate cache BEFORE the Keychain writes.
        rootCache.removeValue(forKey: userId)
        transcriptCache.removeValue(forKey: userId)
        // 🔴 A NEW ROOT MUST RESET THE RATCHET.
        //
        // v2 chains are seeded from the root, but they are only seeded ONCE and
        // then persist. Leaving the old rows in place means a re-pair is
        // silently ignored: the peer that re-paired seeds fresh chains from the
        // new root while the other side keeps using chains derived from the
        // old one, so every message fails its AEAD in both directions —
        // permanently, because re-pairing again would hit the same stale rows.
        // It would also make a post-compromise Safety-Number rotation useless:
        // the message keys would still descend from the compromised root.
        //
        // Deleting here makes the chains re-seed from whichever root is current.
        chainCache.removeValue(forKey: chainCacheKey(userId, true))
        chainCache.removeValue(forKey: chainCacheKey(userId, false))
        Self.kcDelete(account: Self.chainAccount(for: userId, sending: true))
        Self.kcDelete(account: Self.chainAccount(for: userId, sending: false))
        // 2. Write transcript first.
        try Self.kcSetData(transcriptBytes, account: Self.transcriptAccount(for: userId))
        // 3. Write root. If this fails, the transcript is orphaned —
        // we delete it to keep the pair consistent.
        do {
            try Self.kcSetData(rootBytes, account: Self.rootAccount(for: userId))
        } catch {
            Self.kcDelete(account: Self.transcriptAccount(for: userId))
            throw error
        }
        // 4. Populate cache on success.
        rootCache[userId] = root
        transcriptCache[userId] = transcript
    }

    /// Fetch the cached root for a peer if one is paired.
    /// Returns `nil` when no pairing exists (caller should fall back
    /// to the legacy Noise transport sealer).
    func root(for userId: String) async -> ATSAMRootKey? {
        guard !userId.isEmpty else { return nil }
        if let cached = rootCache[userId] { return cached }
        guard let bytes = Self.kcGetData(account: Self.rootAccount(for: userId)),
              bytes.count == ATSAMConstants.Sizes.rootKeyBytes else {
            return nil
        }
        let root = ATSAMRootKey(rootBytes: bytes)
        rootCache[userId] = root
        return root
    }

    /// Fetch the transcript digest the root was bound to.
    /// Used for change-detection: receivers compare the transcript
    /// they see on the wire against this digest. A mismatch means
    /// either the sender re-paired or someone forged.
    func transcriptDigest(for userId: String) async -> Data? {
        guard !userId.isEmpty else { return nil }
        if let cached = transcriptCache[userId] { return cached.hash() }
        return Self.kcGetData(account: Self.transcriptAccount(for: userId))
    }

    // MARK: - v2 ratchet chain state

    /// In-memory chain cache. Canonical copy is the Keychain; this exists so a
    /// burst of sends does not serialise on Keychain I/O.
    private var chainCache: [String: ATSAMChainState] = [:]

    private func chainCacheKey(_ userId: String, _ sending: Bool) -> String {
        (sending ? "s|" : "r|") + userId
    }

    // NOTE: the earlier `chainState(for:sending:)` / `commitChainState(...)`
    // pair was removed. They were superseded by the two atomic methods below,
    // and keeping them was a live hazard: `chainState` seeded the send chain
    // from `KeychainService.getUserId()` while `reserveSendStep` seeds from the
    // `selfUserId` its caller passes in. Those agree today, but two independent
    // ways to seed the same chain is precisely how they stop agreeing later —
    // and a disagreement silently produces a chain the peer cannot follow.

    /// Atomically reserve the next SENDING index and return its message key.
    ///
    /// 🔴 CONCURRENCY. This must be one indivisible step. The obvious spelling —
    /// `chainState()` → `sendKey()` → `commitChainState()` — is three separate
    /// actor calls, and `chainState()` itself suspends on `await` while it
    /// resolves the root and the local id. Actors are reentrant, so two
    /// concurrent sends to the same peer (DeliveryJobRunner fans out, and the
    /// outbox drains in parallel) could both observe index N and both seal
    /// there. The nonces differ, so there is no keystream reuse — but the
    /// receiver consumes the key at N for whichever arrives first and then
    /// rejects the other as already-used. The user would see a message silently
    /// vanish.
    ///
    /// This method is deliberately NON-async: with no suspension point between
    /// read, advance and commit, no other call can interleave. Callers resolve
    /// `selfUserId` and `root` beforehand and hand them in.
    func reserveSendStep(peerUserId: String,
                         selfUserId: String,
                         root: ATSAMRootKey) throws -> (index: UInt32, key: SymmetricKey) {
        guard !peerUserId.isEmpty, !peerUserId.contains("\0"),
              !selfUserId.isEmpty else {
            throw ATSAMRootStorageError.invalidUserId
        }
        let ck = chainCacheKey(peerUserId, true)

        // Resolve current state: cache → Keychain → seed from the root.
        let current: ATSAMChainState
        if let cached = chainCache[ck] {
            current = cached
        } else if let raw = Self.kcGetData(account: Self.chainAccount(for: peerUserId, sending: true)),
                  let decoded = ATSAMChainState.decode(raw) {
            current = decoded
        } else {
            current = ATSAMChainState(
                chainKey: ATSAMChainRatchet.initialChainKey(root: root,
                                                            senderUserId: selfUserId,
                                                            recipientUserId: peerUserId)
            )
        }

        let step = ATSAMChainRatchet.sendKey(state: current,
                                             senderUserId: selfUserId,
                                             recipientUserId: peerUserId)

        // Persist BEFORE returning the key. If this throws, the index is not
        // consumed and the caller falls back — no ciphertext can exist under a
        // key the chain will hand out again.
        try Self.kcSetData(step.next.encode(),
                           account: Self.chainAccount(for: peerUserId, sending: true))
        chainCache[ck] = step.next

        return (step.index, step.key)
    }

    /// Atomically consume a RECEIVING index: derive the key, hand it to
    /// `verify`, and commit the advanced chain only if verification succeeds.
    ///
    /// 🔴 CONCURRENCY + ORDERING, both of which matter here.
    ///
    /// Ordering: the chain must NOT advance for a frame that fails its AEAD.
    /// Otherwise any peer could ship garbage at a high index and ratchet the
    /// victim forward, destroying the keys for genuine messages still in
    /// flight — remote denial of communication needing no key material.
    ///
    /// Atomicity: doing read → verify → commit as separate actor calls lets two
    /// inbound frames from the same peer both start from one snapshot, so the
    /// last commit wins and silently re-persists a key the other call already
    /// consumed — reopening a replay window in exactly the out-of-order case
    /// the skipped-key cache exists to serve. Keeping the whole sequence inside
    /// one non-async actor method removes the interleaving.
    ///
    /// `verify` must be a pure, synchronous AEAD check — it runs while the
    /// actor is held.
    func consumeReceiveStep(peerUserId: String,
                            selfUserId: String,
                            root: ATSAMRootKey,
                            index: UInt32,
                            verify: (SymmetricKey) -> String?) -> String? {
        guard !peerUserId.isEmpty, !selfUserId.isEmpty else { return nil }
        let ck = chainCacheKey(peerUserId, false)

        let current: ATSAMChainState
        if let cached = chainCache[ck] {
            current = cached
        } else if let raw = Self.kcGetData(account: Self.chainAccount(for: peerUserId, sending: false)),
                  let decoded = ATSAMChainState.decode(raw) {
            current = decoded
        } else {
            current = ATSAMChainState(
                chainKey: ATSAMChainRatchet.initialChainKey(root: root,
                                                            senderUserId: peerUserId,
                                                            recipientUserId: selfUserId)
            )
        }

        guard let opened = try? ATSAMChainRatchet.openKey(
            state: current,
            index: index,
            senderUserId: peerUserId,
            recipientUserId: selfUserId
        ) else { return nil }

        // Verify FIRST. A failure leaves the chain untouched.
        guard let plaintext = verify(opened.key) else { return nil }

        // Success is not accepted until the consumed index is durably persisted.
        // Returning plaintext while only the in-memory cache advanced would let
        // a restart roll the chain back and re-accept a replay. Fail closed: the
        // caller receives nil and therefore must not persist or ACK this frame.
        do {
            try Self.kcSetData(
                opened.next.encode(),
                account: Self.chainAccount(for: peerUserId, sending: false)
            )
        } catch {
            return nil
        }
        chainCache[ck] = opened.next
        return plaintext
    }

    /// Wipe a peer's pairing material. Called when the user
    /// explicitly clears a pairing or when the device is being
    /// signed-out. Idempotent.
    func purge(for userId: String) async {
        guard !userId.isEmpty else { return }
        rootCache.removeValue(forKey: userId)
        transcriptCache.removeValue(forKey: userId)
        chainCache.removeValue(forKey: chainCacheKey(userId, true))
        chainCache.removeValue(forKey: chainCacheKey(userId, false))
        Self.kcDelete(account: Self.rootAccount(for: userId))
        Self.kcDelete(account: Self.transcriptAccount(for: userId))
        Self.kcDelete(account: Self.chainAccount(for: userId, sending: true))
        Self.kcDelete(account: Self.chainAccount(for: userId, sending: false))
    }

    /// Wipe everything. Called on sign-out / "delete my account".
    func purgeAll() async {
        rootCache.removeAll()
        transcriptCache.removeAll()
        chainCache.removeAll()
        Self.kcDeleteAll()
    }

    // MARK: - Keychain helpers

    private static func kcSetData(_ data: Data, account: String) throws {
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]

        // Updating an existing item preserves the prior value if the operation
        // fails. This avoids the delete-then-add rollback hole for ratchet state.
        let updateStatus = SecItemUpdate(
            identityQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw ATSAMRootStorageError.keychainWriteFailed(status: updateStatus)
        }

        var addQuery = identityQuery
        addQuery.merge([
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }

        // Another writer may have inserted between update and add. Retry the
        // non-destructive update once; every other error remains fail-closed.
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                identityQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if retryStatus == errSecSuccess {
                return
            }
            throw ATSAMRootStorageError.keychainWriteFailed(status: retryStatus)
        }
        throw ATSAMRootStorageError.keychainWriteFailed(status: addStatus)
    }

    private static func kcGetData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func kcDelete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func kcDeleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum ATSAMRootStorageError: Error {
    case invalidUserId
    case invalidRootBytes
    case invalidTranscriptBytes
    case keychainWriteFailed(status: OSStatus)
}
