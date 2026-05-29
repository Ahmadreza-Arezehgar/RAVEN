// KeychainService — minimal token storage for the App Store build.
//
// Sandbox-friendly: uses `kSecClassGenericPassword` items keyed on a
// `service` string (the app's bundle identifier), no `kSecAttrAccessGroup`
// — keychain-access-groups need a paid team's `application-identifier`
// prefix and the App Sandbox container provides a private keychain
// scope per app, which is exactly what we want.

import Foundation
import Security

enum KeychainKey: String {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case userId = "user_id"
    case username = "username"
}

struct KeychainService {
    static let shared = KeychainService()
    private init() {}

    private var service: String {
        Bundle.main.bundleIdentifier ?? "app.raven.macos"
    }

    func set(_ value: String?, for key: KeychainKey) {
        if let value = value {
            write(value, for: key)
        } else {
            delete(key)
        }
    }

    func read(_ key: KeychainKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    func write(_ value: String, for key: KeychainKey) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attrs) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func delete(_ key: KeychainKey) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func wipe() {
        for key in [KeychainKey.accessToken, .refreshToken, .userId, .username] {
            delete(key)
        }
    }
}
