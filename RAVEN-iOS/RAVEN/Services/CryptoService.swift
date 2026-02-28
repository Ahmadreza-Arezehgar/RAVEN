// RAVEN - Crypto Service
// Converted from Flutter crypto_service.dart

import Foundation
import CryptoKit
import Security

/// Handles encryption, decryption, and key management
struct CryptoService {
    
    // MARK: - Key Generation
    
    /// Generate new Ed25519 key pair for signing
    static func generateSigningKeyPair() -> (publicKey: String, privateKey: String)? {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        return (
            publicKey: publicKey.rawRepresentation.base64EncodedString(),
            privateKey: privateKey.rawRepresentation.base64EncodedString()
        )
    }
    
    /// Generate new X25519 key pair for encryption
    static func generateEncryptionKeyPair() -> (publicKey: String, privateKey: String)? {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey
        
        return (
            publicKey: publicKey.rawRepresentation.base64EncodedString(),
            privateKey: privateKey.rawRepresentation.base64EncodedString()
        )
    }
    
    // MARK: - Signing
    
    /// Sign data with private key
    static func sign(data: Data, privateKeyBase64: String) -> String? {
        guard let keyData = Data(base64Encoded: privateKeyBase64),
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
            return nil
        }
        
        guard let signature = try? privateKey.signature(for: data) else {
            return nil
        }
        
        return signature.base64EncodedString()
    }
    
    /// Verify signature
    static func verify(data: Data, signatureBase64: String, publicKeyBase64: String) -> Bool {
        guard let signatureData = Data(base64Encoded: signatureBase64),
              let keyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return false
        }
        
        return publicKey.isValidSignature(signatureData, for: data)
    }
    
    // MARK: - Encryption (AES-GCM)
    
    /// Encrypt data with AES-GCM
    static func encrypt(data: Data, key: SymmetricKey) -> Data? {
        guard let sealedBox = try? AES.GCM.seal(data, using: key) else {
            return nil
        }
        return sealedBox.combined
    }
    
    /// Decrypt data with AES-GCM
    static func decrypt(encryptedData: Data, key: SymmetricKey) -> Data? {
        guard let sealedBox = try? AES.GCM.SealedBox(combined: encryptedData),
              let decrypted = try? AES.GCM.open(sealedBox, using: key) else {
            return nil
        }
        return decrypted
    }
    
    /// Encrypt string with password
    static func encryptString(_ text: String, password: String) -> String? {
        guard let data = text.data(using: .utf8) else { return nil }
        let key = deriveKey(from: password)
        guard let encrypted = encrypt(data: data, key: key) else { return nil }
        return encrypted.base64EncodedString()
    }
    
    /// Decrypt string with password
    static func decryptString(_ encryptedBase64: String, password: String) -> String? {
        guard let data = Data(base64Encoded: encryptedBase64) else { return nil }
        let key = deriveKey(from: password)
        guard let decrypted = decrypt(encryptedData: data, key: key) else { return nil }
        return String(data: decrypted, encoding: .utf8)
    }
    
    // MARK: - Key Derivation
    
    /// Derive symmetric key from password using HKDF
    static func deriveKey(from password: String, salt: Data? = nil) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        let saltData = salt ?? Data("RAVEN_SALT".utf8)
        
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: passwordData),
            salt: saltData,
            info: Data("RAVEN_KEY".utf8),
            outputByteCount: 32
        )
        
        return key
    }
    
    /// Derive shared secret from X25519 key exchange
    static func deriveSharedSecret(privateKeyBase64: String, publicKeyBase64: String) -> SymmetricKey? {
        guard let privateKeyData = Data(base64Encoded: privateKeyBase64),
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData),
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData) else {
            return nil
        }
        
        guard let sharedSecret = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey) else {
            return nil
        }
        
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("RAVEN_DH".utf8),
            outputByteCount: 32
        )
    }
    
    // MARK: - Hashing
    
    /// SHA256 hash
    static func sha256(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// SHA256 hash of string
    static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }
    
    // MARK: - Random
    
    /// Generate random bytes
    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
    
    /// Generate random hex string
    static func randomHex(length: Int) -> String {
        randomBytes(count: length / 2).map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Message Signature
    
    /// Sign a message for mesh delivery
    static func signMessage(_ message: ChatMessage, privateKey: String) -> String? {
        let payload = "\(message.id)|\(message.senderId)|\(message.recipientId)|\(message.text)|\(message.timestamp.timeIntervalSince1970)"
        return sign(data: Data(payload.utf8), privateKeyBase64: privateKey)
    }
    
    /// Verify message signature
    static func verifyMessage(_ message: ChatMessage, signature: String, publicKey: String) -> Bool {
        let payload = "\(message.id)|\(message.senderId)|\(message.recipientId)|\(message.text)|\(message.timestamp.timeIntervalSince1970)"
        return verify(data: Data(payload.utf8), signatureBase64: signature, publicKeyBase64: publicKey)
    }
}
