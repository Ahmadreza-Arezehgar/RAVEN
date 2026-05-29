//
//  WatchAuthKeyStore.swift  (iPhone-side)
//  RAVEN
//
//  🔴 ROUND 26 (2026-05-16) — hacker-audit MESH-HIGH-3.
//
//  Closes the "auth token plaintext in App Group" leak. Before this
//  round, `WatchSnapshotProjector.publishAuthToken` wrote the bearer
//  token to `group.app.raven.shared/auth.json` in cleartext. Any
//  process with the App Group entitlement (or any backup-extraction
//  attack post-unlock) recovered the token verbatim and impersonated
//  the user against `/api/messages/send`.
//
//  The fix in this file is the iPhone half of a per-pair symmetric
//  key derivation:
//
//    1. iPhone generates a 32-byte AES-256 key on first invocation
//       and stores it in the iPhone Keychain WITHOUT an access
//       group — so only the iPhone app process can read it. A
//       jailbroken Watch process cannot pull this key from anywhere
//       it has access to.
//    2. The same key is shipped to the paired Watch via
//       `WCSession.updateApplicationContext` on every session
//       activation (see `WatchBridgeService`). Apple's WCSession
//       transport is end-to-end encrypted between paired devices,
//       so the key never appears in any cleartext channel.
//    3. The Watch caches the key in its own Keychain (the same
//       pattern, no access group). See `WatchAuthKeyStore.swift`
//       in the `RAVEN-Watch` target.
//    4. `WatchSnapshotProjector` now writes the token AS
//       `ChaChaPoly.seal(token, using: key).combined` (base64) to
//       the App Group file under the key `raven.auth.token.enc`.
//       The legacy plaintext `raven.auth.token` is ALSO written for
//       backward-compat with older Watch builds — when the entire
//       Watch fleet has the new RemoteAPI, the plaintext write can
//       be deleted in a flag-day round.

import Foundation
import CryptoKit
import Security

/// Manages the iPhone-side persistence of the Watch-auth wrap key.
/// Actor-isolated so accidental concurrent generates produce exactly
/// one key per install.
actor WatchAuthKeyStore {
    static let shared = WatchAuthKeyStore()

    /// Keychain `kSecAttrService` value. Stable string so the same
    /// app-update sequence finds the existing key on re-launch.
    private let service = "app.raven.ios.watch-auth-key"
    /// Keychain `kSecAttrAccount` — a fixed sentinel because we only
    /// store one key.
    private let account = "raven-watch-auth-key-v1"

    private init() {}

    /// Returns the existing key or generates+stores a new one.
    /// Idempotent — repeated calls on the same install always
    /// return the same key.
    func getOrCreateKey() -> SymmetricKey? {
        if let existing = loadFromKeychain() {
            return SymmetricKey(data: existing)
        }
        var fresh = Data(count: 32)
        let status = fresh.withUnsafeMutableBytes { buf -> OSStatus in
            guard let base = buf.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, 32, base)
        }
        guard status == errSecSuccess else { return nil }
        guard saveToKeychain(fresh) else { return nil }
        return SymmetricKey(data: fresh)
    }

    /// Encrypt a bearer token. Output format = `ChaChaPoly.SealedBox.combined`
    /// (12-byte nonce || ciphertext || 16-byte tag), base64-encoded so
    /// it can ride inside the App Group JSON file. Returns nil when
    /// the key isn't available (e.g. Keychain access denied — should
    /// not happen on a running, unlocked device).
    func encryptToken(_ token: String) -> String? {
        guard let key = getOrCreateKey() else { return nil }
        let plain = Data(token.utf8)
        // ChaChaPoly is the same primitive we use for sealed messages
        // in `MessageContentSealer`, so we don't pull in a new
        // crypto module just for the Watch path. AES-GCM would have
        // worked too; ChaChaPoly's portable performance is better on
        // 32-bit Watch hardware.
        guard let sealed = try? ChaChaPoly.seal(plain, using: key) else {
            return nil
        }
        return sealed.combined.base64EncodedString()
    }

    /// Raw key bytes — used by `WatchBridgeService` to ship the key
    /// to the paired Watch over WCSession applicationContext. Caller
    /// should treat the return value as sensitive (no logging, zero
    /// after use). Returns nil if Keychain access fails.
    func rawKeyBytes() -> Data? {
        return loadFromKeychain()
    }

    // MARK: - Keychain wiring

    /// Single-write keychain semantics: refuse to overwrite an
    /// existing entry. Forces callers to think about why they'd
    /// want to rotate the wrap key (which would invalidate every
    /// existing encrypted token across paired Watches).
    private func saveToKeychain(_ data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:                kSecClassGenericPassword,
            kSecAttrService as String:          service,
            kSecAttrAccount as String:          account,
            kSecValueData as String:            data,
            kSecAttrAccessible as String:       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        // Insert; if it already exists, treat as success.
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    private func loadFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String:                kSecClassGenericPassword,
            kSecAttrService as String:          service,
            kSecAttrAccount as String:          account,
            kSecReturnData as String:           true,
            kSecMatchLimit as String:           kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return data
    }
}
