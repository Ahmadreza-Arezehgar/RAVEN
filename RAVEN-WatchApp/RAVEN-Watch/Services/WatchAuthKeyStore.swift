//
//  WatchAuthKeyStore.swift  (Watch-side)
//  RAVEN-Watch
//
//  🔴 ROUND 26 (2026-05-16) — hacker-audit MESH-HIGH-3.
//
//  Companion to the iPhone's `WatchAuthKeyStore`. The iPhone ships a
//  per-install 32-byte AES key to this Watch over WCSession
//  `updateApplicationContext` whenever the session activates (see
//  `WatchBridgeService.publishAuthWrapKey` on the iPhone target). We
//  cache the key in the Watch's own Keychain — NOT in any App Group
//  — so that:
//
//    • The key is not visible to other processes via the App Group
//      container that the auth.json file lives in.
//    • The key survives Watch reboot (Keychain has its own persistence).
//    • Recovering the key requires both the Watch's Keychain AND
//      the encrypted token blob; neither alone leaks the bearer.
//
//  `RemoteAPI.token` checks for `raven.auth.token.enc` first; if
//  present AND we have a cached wrap key, it decrypts and returns
//  the plaintext token in memory. There is no on-disk plaintext
//  fallback; missing key or tamper fails closed.

import Foundation
import CryptoKit
import Security

actor WatchAuthKeyStore {
    static let shared = WatchAuthKeyStore()

    private let service = "app.raven.watch.auth-key"
    private let account = "raven-watch-auth-key-v1"

    private init() {}

    /// Persist a freshly-received wrap key from the iPhone.
    /// Idempotent: overwrites the previous entry if any. Returns
    /// `true` on success.
    @discardableResult
    func install(_ keyData: Data) -> Bool {
        // Reject obviously-wrong sizes — defensive against a corrupt
        // applicationContext blob.
        guard keyData.count == 32 else { return false }

        // Delete any previous entry first; SecItemUpdate is fiddly
        // for raw-data passwords and a tiny delete-then-add is fine
        // because this Keychain entry is rarely touched.
        let baseQuery: [String: Any] = [
            kSecClass as String:                kSecClassGenericPassword,
            kSecAttrService as String:          service,
            kSecAttrAccount as String:          account
        ]
        SecItemDelete(baseQuery as CFDictionary)

        var insertQuery = baseQuery
        insertQuery[kSecValueData as String] = keyData
        insertQuery[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insertQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Read the cached wrap key. Returns nil before the iPhone has
    /// shipped its first key; the caller must fail closed in that window.
    func readKey() -> SymmetricKey? {
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
        return SymmetricKey(data: data)
    }

    /// Decrypt the base64 `raven.auth.token.enc` blob the iPhone
    /// wrote to the App Group file. Returns nil on missing key or
    /// AEAD-tamper; callers must not use a plaintext fallback.
    func decryptToken(base64Blob: String) -> String? {
        guard let key = readKey() else { return nil }
        guard let raw = Data(base64Encoded: base64Blob) else { return nil }
        do {
            let sealed = try ChaChaPoly.SealedBox(combined: raw)
            let plain = try ChaChaPoly.open(sealed, using: key)
            return String(data: plain, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
