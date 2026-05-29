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

    /// Wipe a peer's pairing material. Called when the user
    /// explicitly clears a pairing or when the device is being
    /// signed-out. Idempotent.
    func purge(for userId: String) async {
        guard !userId.isEmpty else { return }
        rootCache.removeValue(forKey: userId)
        transcriptCache.removeValue(forKey: userId)
        Self.kcDelete(account: Self.rootAccount(for: userId))
        Self.kcDelete(account: Self.transcriptAccount(for: userId))
    }

    /// Wipe everything. Called on sign-out / "delete my account".
    func purgeAll() async {
        rootCache.removeAll()
        transcriptCache.removeAll()
        Self.kcDeleteAll()
    }

    // MARK: - Keychain helpers

    private static func kcSetData(_ data: Data, account: String) throws {
        // Delete-then-add (idempotent overwrite — Keychain has no
        // built-in upsert that survives every iOS version cleanly).
        kcDelete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ATSAMRootStorageError.keychainWriteFailed(status: status)
        }
    }

    private static func kcGetData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
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
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func kcDeleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
