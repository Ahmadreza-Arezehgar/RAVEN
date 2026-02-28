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
    }
    
    /// Update refresh token (for token rotation)
    func updateRefreshToken(_ newToken: String) throws {
        try save(key: refreshTokenKey, value: newToken)
    }
    
    func getUserId() -> String? {
        return load(key: userIdKey)
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
    }
    
    // MARK: - Private Keychain Operations
    
    private func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.saveFailed(errSecParam)
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
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }
    
    private func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return string
    }
    
    private func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
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
