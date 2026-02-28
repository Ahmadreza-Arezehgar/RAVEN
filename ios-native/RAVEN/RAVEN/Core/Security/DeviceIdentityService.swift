//
//  DeviceIdentityService.swift
//  RAVEN
//
//  Cryptographic Device Identity for Mesh Messaging
//  Generates Ed25519 keypair, stores in Keychain, derives fingerprint
//

import Foundation
import Security
import CryptoKit

/// Manages cryptographic device identity for secure mesh messaging
/// - Generates Ed25519 keypair on first launch
/// - Stores private key securely in Keychain
/// - Derives fingerprint from public key hash
final class DeviceIdentityService {
    static let shared = DeviceIdentityService()
    
    // MARK: - Keychain Keys
    
    private let privateKeyTag = "app.raven.device.privatekey"
    private let publicKeyTag = "app.raven.device.publickey"
    private let agreementPrivateKeyTag = "app.raven.device.agreement.privatekey"
    private let agreementPublicKeyTag = "app.raven.device.agreement.publickey"
    private let fingerprintKey = "app.raven.device.fingerprint"
    
    // MARK: - Cached Values
    
    private var cachedPublicKey: Curve25519.Signing.PublicKey?
    private var cachedPrivateKey: Curve25519.Signing.PrivateKey?
    private var cachedAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var cachedFingerprint: String?
    
    // MARK: - Crypto Caches
    private var sharedSecretCache: [Data: SymmetricKey] = [:]
    private let secretCacheLock = NSLock()
    
    // MARK: - Init
    
    private init() {}
    
    // MARK: - Public API
    
    /// Initialize identity - call on app launch
    /// Generates new keypair if none exists
    func initialize() async throws {
        if try loadExistingKeys() {
            // Migrate: generate agreement keypair if missing (upgrade path)
            if cachedAgreementPrivateKey == nil {
                try generateAgreementKeypair()
                #if DEBUG
                print("🔐 [Identity] Migrated — generated agreement keypair")
                #endif
            }
            #if DEBUG
            print("🔐 [Identity] Loaded existing device identity")
            #endif
            return
        }
        
        // Generate new identity
        try await generateNewIdentity()
        #if DEBUG
        print("🔐 [Identity] Generated new device identity")
        #endif
    }
    
    /// Get device fingerprint (derived from public key)
    /// Format: "XXXX-XXXX-XXXX" (12 chars, base64)
    var fingerprint: String? {
        if let cached = cachedFingerprint {
            return cached
        }
        
        guard let publicKey = cachedPublicKey else { return nil }
        
        let hash = SHA256.hash(data: publicKey.rawRepresentation)
        let hashData = Data(hash)
        let base64 = hashData.prefix(9).base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .prefix(12)
        
        // Format as XXXX-XXXX-XXXX
        let formatted = String(base64).enumerated().map { index, char in
            return (index > 0 && index % 4 == 0) ? "-\(char)" : "\(char)"
        }.joined()
        
        cachedFingerprint = formatted
        return formatted
    }
    
    /// Get public key data for sharing
    var publicKeyData: Data? {
        return cachedPublicKey?.rawRepresentation
    }
    
    /// Get public key as base64 string
    var publicKeyBase64: String? {
        return publicKeyData?.base64EncodedString()
    }
    
    /// Sign data with private key
    func sign(_ data: Data) -> Data? {
        guard let privateKey = cachedPrivateKey else {
            #if DEBUG
            print("⚠️ [Identity] No private key for signing")
            #endif
            return nil
        }
        
        do {
            let signature = try privateKey.signature(for: data)
            return signature
        } catch {
            #if DEBUG
            print("❌ [Identity] Signing failed: \(error)")
            #endif
            return nil
        }
    }
    
    /// Verify signature with a public key
    func verify(signature: Data, data: Data, publicKey: Data) -> Bool {
        do {
            let pubKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            return pubKey.isValidSignature(signature, for: data)
        } catch {
            #if DEBUG
            print("⚠️ [Identity] Signature verification failed: \(error)")
            #endif
            return false
        }
    }
    
    /// Derive fingerprint from any public key
    static func deriveFingerprint(from publicKey: Data) -> String {
        let hash = SHA256.hash(data: publicKey)
        let hashData = Data(hash)
        let base64 = hashData.prefix(9).base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .prefix(12)
        
        return String(base64).enumerated().map { index, char in
            return (index > 0 && index % 4 == 0) ? "-\(char)" : "\(char)"
        }.joined()
    }
    
    /// Generate verification code for pairing (6 digits)
    /// Bug 7 fix: Keys sorted lexicographically so both devices produce the same code
    static func generateVerificationCode(localPubKey: Data, remotePubKey: Data, nonce: Data) -> String {
        // Sort keys lexicographically to guarantee both devices concatenate in same order
        let sortedKeys = [localPubKey, remotePubKey].sorted {
            $0.base64EncodedString() < $1.base64EncodedString()
        }
        
        var combined = Data()
        combined.append(sortedKeys[0])
        combined.append(sortedKeys[1])
        combined.append(nonce)
        
        let hash = SHA256.hash(data: combined)
        let hashData = Data(hash)
        
        // Take first 4 bytes as UInt32, mod 1000000
        let value = hashData.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let code = value % 1000000
        
        return String(format: "%06d", code)
    }
    
    // MARK: - Private Methods
    
    private func generateNewIdentity() async throws {
        // Generate Ed25519 signing keypair
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        // Store signing keys in Keychain
        try storeKey(privateKey.rawRepresentation, tag: privateKeyTag, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        try storeKey(publicKey.rawRepresentation, tag: publicKeyTag, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        
        // Cache signing keys
        cachedPrivateKey = privateKey
        cachedPublicKey = publicKey
        cachedFingerprint = nil
        
        // Generate separate X25519 key agreement keypair for ECDH
        try generateAgreementKeypair()
        
        #if DEBUG
        print("🔐 [Identity] Signing + Agreement keypairs generated - Fingerprint: \(fingerprint ?? "unknown")")
        #endif
    }
    
    /// Generate and store a dedicated X25519 KeyAgreement keypair.
    /// Separate from the Ed25519 signing key — different curve encodings.
    private func generateAgreementKeypair() throws {
        let agreementKey = Curve25519.KeyAgreement.PrivateKey()
        
        try storeKey(agreementKey.rawRepresentation, tag: agreementPrivateKeyTag, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        try storeKey(agreementKey.publicKey.rawRepresentation, tag: agreementPublicKeyTag, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        
        cachedAgreementPrivateKey = agreementKey
        #if DEBUG
        print("🔐 [Identity] Agreement keypair generated")
        #endif
    }
    
    private func loadExistingKeys() throws -> Bool {
        guard let privateKeyData = loadFromKeychain(tag: privateKeyTag),
              let publicKeyData = loadFromKeychain(tag: publicKeyTag) else {
            return false
        }
        
        cachedPrivateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        cachedPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        cachedFingerprint = nil
        
        // Load agreement key if it exists (may be nil on upgrade from older version)
        if let agreementData = loadFromKeychain(tag: agreementPrivateKeyTag) {
            cachedAgreementPrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementData)
        }
        
        return true
    }
    
    // MARK: - Keychain Operations
    
    private func storeKey(_ data: Data, tag: String, accessible: CFString) throws {
        // Delete query: match by class + tag only (NOT by data)
        // Including kSecValueData would search for the NEW key's data, which won't exist yet
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8)
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // Add query: includes all attributes
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ]
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw IdentityError.keychainStoreFailed(status)
        }
    }
    
    private func loadFromKeychain(tag: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            return nil
        }
        
        return result as? Data
    }
    
    // MARK: - Errors
    
    enum IdentityError: Error {
        case keychainStoreFailed(OSStatus)
        case keychainLoadFailed(OSStatus)
        case invalidKeyData
    }
}

// MARK: - Shared Secret (ECDH for encrypted messaging)

extension DeviceIdentityService {
    
    /// Derive shared secret with peer's public key (for encryption)
    /// Uses the dedicated X25519 KeyAgreement key - NOT the Ed25519 signing key.
    func deriveSharedSecret(with peerPublicKey: Data) -> SymmetricKey? {
        secretCacheLock.lock()
        if let cached = sharedSecretCache[peerPublicKey] {
            secretCacheLock.unlock()
            return cached
        }
        secretCacheLock.unlock()
        
        let agreementKey: Curve25519.KeyAgreement.PrivateKey
        if let cached = cachedAgreementPrivateKey {
            agreementKey = cached
        } else if let keyData = loadFromKeychain(tag: agreementPrivateKeyTag),
                  let loaded = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData) {
            cachedAgreementPrivateKey = loaded
            agreementKey = loaded
        } else {
            return nil
        }
        
        do {
            let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
            let sharedSecret = try agreementKey.sharedSecretFromKeyAgreement(with: peerKey)
            
            let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data("RAVEN-MESH".utf8),
                sharedInfo: Data(),
                outputByteCount: 32
            )
            
            // Cache the result
            secretCacheLock.lock()
            if sharedSecretCache.count > 1000 { sharedSecretCache.removeAll() } // Prevent unbounded memory growth
            sharedSecretCache[peerPublicKey] = symmetricKey
            secretCacheLock.unlock()
            
            return symmetricKey
        } catch {
            return nil
        }
    }
    
    /// Get the X25519 agreement public key (for sharing with peers for ECDH)
    var agreementPublicKeyData: Data? {
        if let cached = cachedAgreementPrivateKey {
            return cached.publicKey.rawRepresentation
        }
        return loadFromKeychain(tag: agreementPublicKeyTag)
    }
    
    /// Get agreement public key as base64 string
    var agreementPublicKeyBase64: String? {
        return agreementPublicKeyData?.base64EncodedString()
    }
}
