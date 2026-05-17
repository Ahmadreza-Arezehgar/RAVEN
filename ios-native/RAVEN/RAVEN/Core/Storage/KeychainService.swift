import Foundation
import Security

// MARK: - Token Scope
enum TokenScope: String, Codable {
    case restricted  // Before email verification
    case full        // After email verification
}

// MARK: - Keychain Service
actor KeychainService {
    static let shared = KeychainService()
    
    private let service = "app.raven.ios"
    private let tokenKey = "auth_token"
    private let scopeKey = "token_scope"
    private let userIdKey = "user_id"
    private let refreshTokenKey = "refresh_token"
    
    // MARK: - Memory Cache (avoid repeated Keychain reads)
    private var cachedToken: String?
    private var cachedScope: TokenScope?
    private var cachedUserId: String?
    private var isCacheLoaded = false
    
    private init() {}
    
    // MARK: - Token Management
    
    func saveToken(_ token: String, scope: TokenScope, userId: String, refreshToken: String? = nil) throws {
        // Save access token
        try save(key: tokenKey, value: token)
        try save(key: scopeKey, value: scope.rawValue)
        try save(key: userIdKey, value: userId)

        // Save refresh token if provided
        if let refreshToken = refreshToken {
            try save(key: refreshTokenKey, value: refreshToken)
        }

        // ✅ Update memory cache
        cachedToken = token
        cachedScope = scope
        cachedUserId = userId
        isCacheLoaded = true

        // Mirror the bearer token into the shared App Group container
        // so the paired Apple Watch's standalone-LTE fallback can hit
        // the REST API directly when the iPhone is unreachable.
        Task { @MainActor in
            WatchSnapshotProjector.shared.publishAuthToken(token)
        }
    }
    
    func getToken() -> (token: String, scope: TokenScope)? {
        // ✅ Return cached token if available (fast path)
        if isCacheLoaded {
            if let token = cachedToken, let scope = cachedScope {
                return (token, scope)
            }
            return nil
        }
        
        // First read: load from Keychain and cache
        guard let token = load(key: tokenKey),
              let scopeString = load(key: scopeKey),
              let scope = TokenScope(rawValue: scopeString) else {
            isCacheLoaded = true  // Mark as loaded even if empty
            return nil
        }
        
        // Cache for next time
        cachedToken = token
        cachedScope = scope
        cachedUserId = load(key: userIdKey)
        isCacheLoaded = true
        
        return (token, scope)
    }
    
    /// Pre-load tokens from Keychain into memory (call on app launch)
    func warmUp() {
        if !isCacheLoaded {
            _ = getToken()  // This will populate cache
            #if DEBUG
            print("🔑 [Keychain] Token cache warmed up")
            #endif
        }
    }
    
    func getRefreshToken() -> String? {
        return load(key: refreshTokenKey)
    }
    
    func updateAccessToken(_ newToken: String) throws {
        try save(key: tokenKey, value: newToken)
        cachedToken = newToken  // ✅ Update cache
        // Keep the Watch's standalone-LTE auth file in sync after a
        // token rotation, otherwise the next 401 retry on the Watch
        // would use a stale token.
        Task { @MainActor in
            WatchSnapshotProjector.shared.publishAuthToken(newToken)
        }
    }
    
    /// Update refresh token (for token rotation)
    func updateRefreshToken(_ newToken: String) throws {
        try save(key: refreshTokenKey, value: newToken)
    }
    
    /// BUG FIX (2026-05-10): mirror the same in-memory cache the
    /// access token uses. The previous version did a fresh `load()`
    /// from the keychain on every call while `cachedToken` was the
    /// authoritative source for `getToken()` — after a `deleteAll()`
    /// race, `getToken()` returned nil while `getUserId()` still
    /// pulled a stale id from disk, signing background-service
    /// requests on behalf of the wrong user. Cache + load now move
    /// together so both views stay consistent.
    func getUserId() -> String? {
        if let cached = cachedUserId { return cached }
        let fromDisk = load(key: userIdKey)
        if let fromDisk { cachedUserId = fromDisk }
        return fromDisk
    }
    
    func upgradeToFullToken(_ newToken: String) throws {
        try save(key: tokenKey, value: newToken)
        try save(key: scopeKey, value: TokenScope.full.rawValue)
        
        // ✅ Update cache
        cachedToken = newToken
        cachedScope = .full
    }
    
    func isRestricted() -> Bool {
        guard let (_, scope) = getToken() else { return true }
        return scope == .restricted
    }
    
    func deleteAll() throws {
        try delete(key: tokenKey)
        try delete(key: scopeKey)
        try delete(key: userIdKey)
        try delete(key: refreshTokenKey)
        try? delete(key: pushTokenKey)  // Force re-registration on next login

        // ✅ Clear memory cache
        cachedToken = nil
        cachedScope = nil
        cachedUserId = nil
        isCacheLoaded = true  // Keep flag true, just mark as "loaded empty"

        // Sign-out also revokes the Watch's standalone-LTE access by
        // wiping the shared-container auth file.
        Task { @MainActor in
            WatchSnapshotProjector.shared.publishAuthToken(nil)
        }
    }
    
    // MARK: - Private Keychain Operations
    //
    // On Mac Catalyst ad-hoc-signed builds (the local DMG distribution path)
    // the system Keychain refuses every SecItem operation with
    // errSecMissingEntitlement (-34018) because there's no team-prefixed
    // application-identifier baked into the binary. On notarized Developer ID
    // builds the entitlement IS present and Keychain works normally.
    //
    // To keep the local-DMG flow usable, we fall back to a per-user
    // file-backed store when Keychain refuses us. The store lives at
    // ~/Library/Application Support/RAVEN/secrets.plist with file mode 0600
    // (owner-read-write only). This is functionally equivalent to the
    // Keychain's per-app default access group from a threat-model standpoint
    // for a non-sandboxed local app — both are protected by the user's login.

    private static let fallbackFileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("RAVEN", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                  withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("secrets.plist")
    }()

    /// Sticky flag — once any SecItem operation returns errSecMissingEntitlement
    /// we know the binary is in the broken-Keychain state and route every
    /// subsequent call to the fallback store. Avoids repeated -34018 logs.
    private var keychainUnavailable = false

    private func loadFallbackDict() -> [String: String] {
        guard let data = try? Data(contentsOf: Self.fallbackFileURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
            return [:]
        }
        return dict
    }

    private func writeFallbackDict(_ dict: [String: String]) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict,
                                                              format: .binary,
                                                              options: 0) else {
            return
        }
        try? data.write(to: Self.fallbackFileURL, options: [.atomic, .completeFileProtection])
        // Ensure 0600 even if the OS didn't honor `.completeFileProtection`.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                ofItemAtPath: Self.fallbackFileURL.path)
    }

    private func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.saveFailed(errSecParam)
        }

        if keychainUnavailable {
            var dict = loadFallbackDict()
            dict[key] = value
            writeFallbackDict(dict)
            return
        }

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new - SECURITY: AfterFirstUnlockThisDeviceOnly = device-bound, no backup,
        // AND accessible when device is locked (critical for background push token reads)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            // Switch to fallback for the rest of the process lifetime.
            keychainUnavailable = true
            #if DEBUG
            print("⚠️ [Keychain] errSecMissingEntitlement on save — falling back to file store")
            #endif
            var dict = loadFallbackDict()
            dict[key] = value
            writeFallbackDict(dict)
            return
        }
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private func load(key: String) -> String? {
        if keychainUnavailable {
            return loadFallbackDict()[key]
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecMissingEntitlement {
            keychainUnavailable = true
            #if DEBUG
            print("⚠️ [Keychain] errSecMissingEntitlement on load — falling back to file store")
            #endif
            return loadFallbackDict()[key]
        }

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    private func delete(key: String) throws {
        if keychainUnavailable {
            var dict = loadFallbackDict()
            dict.removeValue(forKey: key)
            writeFallbackDict(dict)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecMissingEntitlement {
            keychainUnavailable = true
            var dict = loadFallbackDict()
            dict.removeValue(forKey: key)
            writeFallbackDict(dict)
            return
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
    
    // MARK: - Push Token
    
    private let pushTokenKey = "push_token"
    
    func savePushToken(_ token: String) {
        try? save(key: pushTokenKey, value: token)
    }
    
    func getPushToken() -> String? {
        return load(key: pushTokenKey)
    }
    
    // MARK: - Contact Sync Salt
    
    private let contactSaltKey = "contact_sync_salt"
    
    func saveContactSyncSalt(_ salt: String) {
        try? save(key: contactSaltKey, value: salt)
    }
    
    func getContactSyncSalt() -> String? {
        return load(key: contactSaltKey)
    }
}

// MARK: - Keychain Error
enum KeychainError: Error {
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)
}
