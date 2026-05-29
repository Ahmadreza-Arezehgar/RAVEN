// DeviceIdentityService — Ed25519 + X25519 device identity for BLE mesh.
//
// Direct port of `ios-native/RAVEN/RAVEN/Core/Security/DeviceIdentityService.swift`
// with two simplifications for the macOS App Store build:
//   • No key rotation grace window (user-visible feature; defer to a
//     later release).
//   • No `FriendDeviceRepository` dependency — the iOS-side trusted
//     device registry isn't on this build yet.
//
// CryptoKit + Security framework are identical on macOS, so the
// keychain semantics, keypair generation and signing all work as-is.
// We pin the same `kSecAttrApplicationTag` strings as iOS so a future
// shared keychain group could let two builds share the same identity.

import Foundation
import Security
import CryptoKit

final class DeviceIdentityService: @unchecked Sendable {
    static let shared = DeviceIdentityService()

    // MARK: - Keychain tags (match iOS for parity)

    private let privateKeyTag = "app.raven.device.privatekey"
    private let publicKeyTag = "app.raven.device.publickey"
    private let agreementPrivateKeyTag = "app.raven.device.agreement.privatekey"
    private let agreementPublicKeyTag = "app.raven.device.agreement.publickey"

    // MARK: - Cached values (lock-protected — accessed from BLE queues)

    private var cachedPublicKey: Curve25519.Signing.PublicKey?
    private var cachedPrivateKey: Curve25519.Signing.PrivateKey?
    private var cachedAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var cachedFingerprint: String?
    private let keyCacheLock = NSLock()

    private var sharedSecretCache: [Data: SymmetricKey] = [:]
    /// Insertion-order log paired with `sharedSecretCache` so we can
    /// evict the oldest half on cap-hit instead of nuking the entire
    /// map. Updated under `secretCacheLock`.
    private var sharedSecretCacheOrder: [Data] = []
    private let secretCacheLock = NSLock()

    private init() {}

    // MARK: - Public API

    /// Initialize identity. Call on app launch (after auth bootstrap).
    func initialize() async throws {
        if try loadExistingKeys() {
            if cachedAgreementPrivateKey == nil {
                try generateAgreementKeypair()
            }
            return
        }
        try generateNewIdentity()
    }

    /// XXXX-XXXX-XXXX fingerprint derived from the SHA-256 of the
    /// signing public key. Cached after first computation.
    var fingerprint: String? {
        keyCacheLock.lock()
        if let cached = cachedFingerprint {
            keyCacheLock.unlock()
            return cached
        }
        guard let publicKey = cachedPublicKey else {
            keyCacheLock.unlock()
            return nil
        }
        keyCacheLock.unlock()

        let hash = SHA256.hash(data: publicKey.rawRepresentation)
        let hashData = Data(hash)
        let base64 = hashData.prefix(9).base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .prefix(12)

        let formatted = String(base64).enumerated().map { idx, char in
            (idx > 0 && idx % 4 == 0) ? "-\(char)" : "\(char)"
        }.joined()

        keyCacheLock.lock()
        cachedFingerprint = formatted
        keyCacheLock.unlock()
        return formatted
    }

    var publicKeyData: Data? {
        keyCacheLock.lock()
        defer { keyCacheLock.unlock() }
        return cachedPublicKey?.rawRepresentation
    }

    var publicKeyBase64: String? { publicKeyData?.base64EncodedString() }

    /// Sign data with the Ed25519 private key.
    func sign(_ data: Data) -> Data? {
        keyCacheLock.lock()
        let privateKey = cachedPrivateKey
        keyCacheLock.unlock()

        guard let privateKey else { return nil }
        return try? privateKey.signature(for: data)
    }

    /// Verify Ed25519 signature.
    func verify(signature: Data, data: Data, publicKey: Data) -> Bool {
        guard let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return pubKey.isValidSignature(signature, for: data)
    }

    /// Static — derives the same XXXX-XXXX-XXXX fingerprint format used
    /// for the local key, given any peer's public-key bytes.
    static func deriveFingerprint(from publicKey: Data) -> String {
        let hash = SHA256.hash(data: publicKey)
        let hashData = Data(hash)
        let base64 = hashData.prefix(9).base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .prefix(12)
        return String(base64).enumerated().map { idx, char in
            (idx > 0 && idx % 4 == 0) ? "-\(char)" : "\(char)"
        }.joined()
    }

    /// Six-digit verification code for offline pairing — both parties
    /// compute the same value if their public keys + nonce match.
    /// Lexicographic ordering ensures the result is symmetric.
    static func generateVerificationCode(localPubKey: Data, remotePubKey: Data, nonce: Data) -> String {
        let sortedKeys = [localPubKey, remotePubKey].sorted {
            $0.base64EncodedString() < $1.base64EncodedString()
        }
        var combined = Data()
        combined.append(sortedKeys[0])
        combined.append(sortedKeys[1])
        combined.append(nonce)
        let hash = SHA256.hash(data: combined)
        let hashData = Data(hash)
        let value = hashData.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let code = value % 1_000_000
        return String(format: "%06d", code)
    }

    // MARK: - Private

    private func generateNewIdentity() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        try storeKey(privateKey.rawRepresentation,
                     tag: privateKeyTag,
                     accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        try storeKey(publicKey.rawRepresentation,
                     tag: publicKeyTag,
                     accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)

        keyCacheLock.lock()
        cachedPrivateKey = privateKey
        cachedPublicKey = publicKey
        cachedFingerprint = nil
        keyCacheLock.unlock()

        try generateAgreementKeypair()
    }

    private func generateAgreementKeypair() throws {
        let agreementKey = Curve25519.KeyAgreement.PrivateKey()
        try storeKey(agreementKey.rawRepresentation,
                     tag: agreementPrivateKeyTag,
                     accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        try storeKey(agreementKey.publicKey.rawRepresentation,
                     tag: agreementPublicKeyTag,
                     accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        keyCacheLock.lock()
        cachedAgreementPrivateKey = agreementKey
        keyCacheLock.unlock()
    }

    private func loadExistingKeys() throws -> Bool {
        guard let privateKeyData = loadFromKeychain(tag: privateKeyTag),
              let publicKeyData = loadFromKeychain(tag: publicKeyTag)
        else { return false }

        let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        let agreement: Curve25519.KeyAgreement.PrivateKey? = {
            if let data = loadFromKeychain(tag: agreementPrivateKeyTag) {
                return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
            }
            return nil
        }()

        keyCacheLock.lock()
        cachedPrivateKey = priv
        cachedPublicKey = pub
        cachedFingerprint = nil
        if let agreement { cachedAgreementPrivateKey = agreement }
        keyCacheLock.unlock()
        return true
    }

    private func storeKey(_ data: Data, tag: String, accessible: CFString) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8)
        ]
        SecItemDelete(deleteQuery as CFDictionary)

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
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    enum IdentityError: Error {
        case keychainStoreFailed(OSStatus)
        case keychainLoadFailed(OSStatus)
        case invalidKeyData
    }
}

// MARK: - Shared secret (ECDH)

extension DeviceIdentityService {
    /// Derive an HKDF-derived AES key for an X25519 ECDH against the
    /// peer's agreement public key. Cached per peer.
    func deriveSharedSecret(with peerPublicKey: Data) -> SymmetricKey? {
        secretCacheLock.lock()
        if let cached = sharedSecretCache[peerPublicKey] {
            secretCacheLock.unlock()
            return cached
        }
        secretCacheLock.unlock()

        keyCacheLock.lock()
        let agreementKey: Curve25519.KeyAgreement.PrivateKey
        if let cached = cachedAgreementPrivateKey {
            agreementKey = cached
            keyCacheLock.unlock()
        } else if let keyData = loadFromKeychain(tag: agreementPrivateKeyTag),
                  let loaded = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData) {
            cachedAgreementPrivateKey = loaded
            agreementKey = loaded
            keyCacheLock.unlock()
        } else {
            keyCacheLock.unlock()
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
            secretCacheLock.lock()
            // Cap the cache so a flood of unique peers can't OOM us.
            // Previously this called `removeAll()`, which flushed every
            // cached ECDH derivation — including hot peers — every time
            // the 1001st distinct peer was seen. Use a bounded LRU
            // eviction (drop the oldest half) so frequently-talked-to
            // peers stay warm across crowded sessions.
            if sharedSecretCache.count >= 1000 {
                let drop = sharedSecretCacheOrder.count / 2
                let evicted = sharedSecretCacheOrder.prefix(drop)
                sharedSecretCacheOrder.removeFirst(drop)
                for k in evicted { sharedSecretCache.removeValue(forKey: k) }
            }
            if sharedSecretCache[peerPublicKey] == nil {
                sharedSecretCacheOrder.append(peerPublicKey)
            }
            sharedSecretCache[peerPublicKey] = symmetricKey
            secretCacheLock.unlock()
            return symmetricKey
        } catch {
            return nil
        }
    }

    var agreementPublicKeyData: Data? {
        keyCacheLock.lock()
        let cached = cachedAgreementPrivateKey
        keyCacheLock.unlock()
        if let cached { return cached.publicKey.rawRepresentation }
        return loadFromKeychain(tag: agreementPublicKeyTag)
    }

    var agreementPublicKeyBase64: String? { agreementPublicKeyData?.base64EncodedString() }

    /// Raw 32-byte X25519 private key from the keychain. Exposed so
    /// the BLE-login Phase-2 receiver can ECDH-decrypt the bridged
    /// JWT envelope without going through the closure-based borrowing
    /// in `withAgreementPrivateKey` (which is convenient for chat,
    /// awkward for a one-shot decrypt called from a non-throwing
    /// dispatcher). nil before `initialize()` has materialised the key.
    var agreementPrivateKeyData: Data? {
        keyCacheLock.lock()
        let cached = cachedAgreementPrivateKey
        keyCacheLock.unlock()
        if let cached { return cached.rawRepresentation }
        return loadFromKeychain(tag: agreementPrivateKeyTag)
    }

    /// Borrow the long-term Curve25519 agreement private key for the
    /// duration of `body`. Used by `NoiseSessionStore` to drive the
    /// IK handshake without holding the key beyond the call. Returns
    /// nil if the key isn't materialized yet (e.g. before
    /// `initialize()` has run).
    func withAgreementPrivateKey<T>(_ body: (Curve25519.KeyAgreement.PrivateKey) throws -> T) rethrows -> T? {
        keyCacheLock.lock()
        let key = cachedAgreementPrivateKey
        keyCacheLock.unlock()
        guard let key else { return nil }
        return try body(key)
    }
}
