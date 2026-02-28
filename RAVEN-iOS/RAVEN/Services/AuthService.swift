// RAVEN - Auth Service
// Converted from Flutter to Swift

import Foundation
import Combine
import Security

@MainActor
class AuthService: ObservableObject {
    static let shared = AuthService()
    
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var isLoading = false
    @Published var error: String?
    
    private var accessToken: String? {
        get { KeychainHelper.get(key: "jwt_token") }
        set {
            if let value = newValue {
                KeychainHelper.save(key: "jwt_token", value: value)
            } else {
                KeychainHelper.delete(key: "jwt_token")
            }
        }
    }
    
    private var userId: String? {
        get { KeychainHelper.get(key: "user_id") }
        set {
            if let value = newValue {
                KeychainHelper.save(key: "user_id", value: value)
            } else {
                KeychainHelper.delete(key: "user_id")
            }
        }
    }
    
    private init() {}
    
    // MARK: - Session Management
    
    func restoreSession() {
        guard accessToken != nil else {
            isAuthenticated = false
            return
        }
        
        Task {
            do {
                let user = try await APIService.shared.getCurrentUser()
                currentUser = user
                isAuthenticated = true
                print("✅ [Auth] Session restored for: \(user.username)")
            } catch {
                print("❌ [Auth] Session restore failed: \(error)")
                signOut()
            }
        }
    }
    
    // MARK: - Sign In
    
    func signIn(username: String, password: String) async throws {
        isLoading = true
        error = nil
        defer { isLoading = false }
        
        do {
            let response = try await APIService.shared.login(username: username, password: password)
            
            if let token = response.token {
                accessToken = token
                userId = response.userId
                await APIService.shared.setToken(token)
                
                let user = try await APIService.shared.getCurrentUser()
                currentUser = user
                isAuthenticated = true
                
                print("✅ [Auth] Signed in: \(user.username)")
            }
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }
    
    // MARK: - Sign Up
    
    func signUp(
        username: String,
        password: String,
        firstName: String,
        lastName: String,
        birthYear: Int,
        email: String?
    ) async throws {
        isLoading = true
        error = nil
        defer { isLoading = false }
        
        do {
            let response = try await APIService.shared.register(
                username: username,
                password: password,
                firstName: firstName,
                lastName: lastName,
                birthYear: birthYear,
                email: email
            )
            
            if let token = response.token {
                accessToken = token
                userId = response.userId
                await APIService.shared.setToken(token)
                
                let user = try await APIService.shared.getCurrentUser()
                currentUser = user
                isAuthenticated = true
                
                print("✅ [Auth] Signed up: \(user.username)")
            }
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }
    
    // MARK: - OAuth
    
    func signInWithGoogle(idToken: String) async throws {
        isLoading = true
        error = nil
        defer { isLoading = false }
        
        let response = try await APIService.shared.oauthGoogle(idToken: idToken)
        
        if response.needsUsername == true {
            // Store temp token, user needs to set username
            if let tempToken = response.tempToken {
                UserDefaults.standard.set(tempToken, forKey: "temp_oauth_token")
            }
            throw AuthError.needsUsername
        }
        
        if let token = response.token {
            accessToken = token
            await APIService.shared.setToken(token)
            
            let user = try await APIService.shared.getCurrentUser()
            currentUser = user
            isAuthenticated = true
        }
    }
    
    func signInWithApple(identityToken: String, authorizationCode: String) async throws {
        isLoading = true
        error = nil
        defer { isLoading = false }
        
        let response = try await APIService.shared.oauthApple(
            identityToken: identityToken,
            authorizationCode: authorizationCode
        )
        
        if response.needsUsername == true {
            if let tempToken = response.tempToken {
                UserDefaults.standard.set(tempToken, forKey: "temp_oauth_token")
            }
            throw AuthError.needsUsername
        }
        
        if let token = response.token {
            accessToken = token
            await APIService.shared.setToken(token)
            
            let user = try await APIService.shared.getCurrentUser()
            currentUser = user
            isAuthenticated = true
        }
    }
    
    // MARK: - Sign Out
    
    func signOut() {
        accessToken = nil
        userId = nil
        currentUser = nil
        isAuthenticated = false
        
        Task {
            await APIService.shared.setToken(nil)
        }
        
        // Clear all stored data
        UserDefaults.standard.removeObject(forKey: "temp_oauth_token")
        
        print("✅ [Auth] Signed out")
    }
    
    // MARK: - Verification
    
    func sendVerificationCode(to identifier: String, channel: String = "email", purpose: String = "verification") async throws {
        try await APIService.shared.sendVerificationCode(identifier: identifier, channel: channel, purpose: purpose)
    }
    
    func verifyCode(_ code: String, for identifier: String, purpose: String = "verification") async throws -> Bool {
        let response = try await APIService.shared.verifyCode(identifier: identifier, code: code, purpose: purpose)
        return response.verified
    }
}

// MARK: - Auth Errors
enum AuthError: LocalizedError {
    case needsUsername
    case invalidCredentials
    case sessionExpired
    case networkError
    
    var errorDescription: String? {
        switch self {
        case .needsUsername: return "Please set a username to continue"
        case .invalidCredentials: return "Invalid username or password"
        case .sessionExpired: return "Session expired, please login again"
        case .networkError: return "Network error, please try again"
        }
    }
}

// MARK: - Keychain Helper
struct KeychainHelper {
    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    static func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return value
    }
    
    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
    
    static func clearAll() {
        let secClasses = [
            kSecClassGenericPassword,
            kSecClassInternetPassword,
            kSecClassCertificate,
            kSecClassKey,
            kSecClassIdentity
        ]
        
        for secClass in secClasses {
            let query: [String: Any] = [kSecClass as String: secClass]
            SecItemDelete(query as CFDictionary)
        }
    }
}
