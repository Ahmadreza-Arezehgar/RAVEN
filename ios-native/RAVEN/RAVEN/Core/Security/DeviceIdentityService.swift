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

    // ⚡ Key rotation (audit #5a)
    // We retain the immediately-previous public key + attestation for one
    // rotation window so in-flight messages signed with the old key still
    // verify, and remote peers can validate the rotation chain.
    private let prevPublicKeyTag = "app.raven.device.prev.publickey"
    private let prevAttestationTag = "app.raven.device.prev.attestation" // signature of NEW pubkey by OLD privkey
    private let rotationWindowKey = "app.raven.device.rotation.window.until" // UserDefaults epoch
    /// How long we keep the previous public key valid for verification.
    /// 24h matches `meshTTLSeconds` default — anything in flight will have
    /// expired by the time the window closes.
    static let rotationGraceWindowSeconds: TimeInterval = 24 * 60 * 60
    
    // MARK: - Cached Values
    //
    // ⚠️ Concurrency contract — these four properties are read AND written
    // from arbitrary threads (BLE central queue, BLE peripheral queue, the
    // MainActor, app-launch initialization). They MUST be accessed only via
    // `keyCacheLock`. Reading or writing without the lock can produce a
    // double-init on first peer encounter under load, or torn reads of the
    // private-key reference itself (which would crash in Curve25519's init).

    private var cachedPublicKey: Curve25519.Signing.PublicKey?
    private var cachedPrivateKey: Curve25519.Signing.PrivateKey?
    private var cachedAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var cachedFingerprint: String?
    private let keyCacheLock = NSLock()

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

        // Format as XXXX-XXXX-XXXX
        let formatted = String(base64).enumerated().map { index, char in
            return (index > 0 && index % 4 == 0) ? "-\(char)" : "\(char)"
        }.joined()

        keyCacheLock.lock()
        cachedFingerprint = formatted
        keyCacheLock.unlock()
        return formatted
    }

    /// Get public key data for sharing
    var publicKeyData: Data? {
        keyCacheLock.lock()
        defer { keyCacheLock.unlock() }
        return cachedPublicKey?.rawRepresentation
    }

    /// Get public key as base64 string
    var publicKeyBase64: String? {
        return publicKeyData?.base64EncodedString()
    }

    // Sync helpers that wrap the locks so async callers don't invoke
    // `NSLock.lock/unlock` directly (Swift 6 flags that as an error).
    private func currentCachedKeys() -> (Curve25519.Signing.PrivateKey?, Curve25519.Signing.PublicKey?) {
        keyCacheLock.lock()
        defer { keyCacheLock.unlock() }
        return (cachedPrivateKey, cachedPublicKey)
    }

    private func updateCachedKeys(privateKey: Curve25519.Signing.PrivateKey,
                                  publicKey: Curve25519.Signing.PublicKey) {
        keyCacheLock.lock()
        defer { keyCacheLock.unlock() }
        cachedPrivateKey = privateKey
        cachedPublicKey = publicKey
        cachedFingerprint = nil
    }

    private func clearSharedSecretCache() {
        secretCacheLock.lock()
        defer { secretCacheLock.unlock() }
        sharedSecretCache.removeAll()
    }

    /// Sign data with private key
    func sign(_ data: Data) -> Data? {
        keyCacheLock.lock()
        let privateKey = cachedPrivateKey
        keyCacheLock.unlock()

        guard let privateKey else {
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

    // MARK: - Key Rotation (audit #5a)

    /// Snapshot of the previous identity, kept for one grace window after a
    /// rotation so in-flight messages still verify and peers can confirm
    /// the rotation chain via `prevAttestation` (signature of NEW pubkey by
    /// the OLD privkey).
    struct RotationProof {
        let previousPublicKey: Data
        let attestationOverNewKey: Data
        let validUntil: Date
        var isInWindow: Bool { Date() < validUntil }
    }

    /// Currently-cached rotation proof, if a rotation happened in the last
    /// `rotationGraceWindowSeconds`. Returns nil otherwise.
    var rotationProof: RotationProof? {
        guard let prevPubKey = loadFromKeychain(tag: prevPublicKeyTag),
              let attestation = loadFromKeychain(tag: prevAttestationTag) else {
            return nil
        }
        let until = UserDefaults.standard.double(forKey: rotationWindowKey)
        guard until > 0 else { return nil }
        return RotationProof(
            previousPublicKey: prevPubKey,
            attestationOverNewKey: attestation,
            validUntil: Date(timeIntervalSince1970: until)
        )
    }

    /// Verify a signature against EITHER the current pubkey (passed in) OR
    /// the immediately-previous pubkey if its grace window is still open.
    /// Used for incoming envelopes during the rotation handover so messages
    /// signed just before rotation still verify.
    func verifyAcceptingRotation(signature: Data, data: Data, expectedPublicKey: Data) -> Bool {
        if verify(signature: signature, data: data, publicKey: expectedPublicKey) { return true }
        if let proof = rotationProof, proof.isInWindow,
           proof.previousPublicKey == expectedPublicKey {
            return verify(signature: signature, data: data, publicKey: proof.previousPublicKey)
        }
        return false
    }

    /// Rotate this device's signing keypair.
    /// 1. Generate fresh Ed25519 + X25519 keypairs
    /// 2. Sign the NEW pubkey with the OLD privkey → `attestation`
    ///    (proves continuity — anyone who trusted the old key can verify)
    /// 3. Store: new keys → primary slots, old pubkey + attestation → prev slots
    /// 4. Open a grace window (default 24h) during which we still accept
    ///    signatures made with the previous key.
    /// Returns the rotation proof so callers can broadcast it to peers /
    /// upload to the server for fan-out.
    @discardableResult
    func rotateKeys() async throws -> RotationProof {
        let (oldPrivateKey, oldPublicKey) = currentCachedKeys()

        guard let oldPrivateKey, let oldPublicKey else {
            // Nothing to rotate from — generate a fresh identity.
            try await generateNewIdentity()
            return RotationProof(
                previousPublicKey: Data(),
                attestationOverNewKey: Data(),
                validUntil: Date()
            )
        }

        // 1. Generate fresh keypair
        let newPrivateKey = Curve25519.Signing.PrivateKey()
        let newPublicKey = newPrivateKey.publicKey

        // 2. Attestation: sign(newPub || nowEpoch) with the OLD privkey.
        //    Peers receiving the rotation announcement verify this against
        //    the OLD public key they already trust.
        let now = Date().timeIntervalSince1970
        let nowEncoded = withUnsafeBytes(of: now.bitPattern.littleEndian) { Data($0) }
        let attestationPayload = newPublicKey.rawRepresentation + nowEncoded
        let attestation = try oldPrivateKey.signature(for: attestationPayload)

        // 3. Persist: previous pubkey + attestation BEFORE overwriting current
        try storeKey(oldPublicKey.rawRepresentation, tag: prevPublicKeyTag,
                     accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        try storeKey(attestation, tag: prevAttestationTag,
                     accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)

        // 4. Swap in the new keys
        try storeKey(newPrivateKey.rawRepresentation, tag: privateKeyTag,
                     accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        try storeKey(newPublicKey.rawRepresentation, tag: publicKeyTag,
                     accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        updateCachedKeys(privateKey: newPrivateKey, publicKey: newPublicKey)

        // Rotate the agreement keypair too — it's separate but follows the
        // same lifecycle so ECDH-derived shared secrets are refreshed.
        try generateAgreementKeypair()
        // Wipe any cached shared secrets — they are derived from the OLD agreement key
        clearSharedSecretCache()

        // 5. Open the grace window
        let validUntil = Date().addingTimeInterval(Self.rotationGraceWindowSeconds)
        UserDefaults.standard.set(validUntil.timeIntervalSince1970, forKey: rotationWindowKey)

        #if DEBUG
        print("🔁 [Identity] Rotated signing keys — new fingerprint \(fingerprint ?? "?"), grace until \(validUntil)")
        #endif

        return RotationProof(
            previousPublicKey: oldPublicKey.rawRepresentation,
            attestationOverNewKey: attestation,
            validUntil: validUntil
        )
    }

    /// Verify that a `RotationProof` is genuinely a continuation of `oldKey`.
    /// Used by peers receiving a rotation announcement: given the public key
    /// they already trusted (oldKey) and the announced (newKey, attestation,
    /// timestamp), check the signature matches.
    static func verifyRotationProof(
        oldPublicKey: Data,
        newPublicKey: Data,
        attestation: Data,
        attestedAt: TimeInterval
    ) -> Bool {
        let now = Date().timeIntervalSince1970
        // Only accept proofs no older than 24h to prevent replay of stale rotations
        guard abs(now - attestedAt) < rotationGraceWindowSeconds else { return false }
        guard let oldPub = try? Curve25519.Signing.PublicKey(rawRepresentation: oldPublicKey) else {
            return false
        }
        let nowEncoded = withUnsafeBytes(of: attestedAt.bitPattern.littleEndian) { Data($0) }
        let payload = newPublicKey + nowEncoded
        return oldPub.isValidSignature(attestation, for: payload)
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
        
        // Cache signing keys (lock — could race with concurrent deriveSharedSecret)
        updateCachedKeys(privateKey: privateKey, publicKey: publicKey)

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

        keyCacheLock.lock()
        cachedAgreementPrivateKey = agreementKey
        keyCacheLock.unlock()
        #if DEBUG
        print("🔐 [Identity] Agreement keypair generated")
        #endif
    }
    
    private func loadExistingKeys() throws -> Bool {
        guard let privateKeyData = loadFromKeychain(tag: privateKeyTag),
              let publicKeyData = loadFromKeychain(tag: publicKeyTag) else {
            return false
        }
        
        let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        // Load agreement key if it exists (may be nil on upgrade from older version)
        let agreement: Curve25519.KeyAgreement.PrivateKey? = {
            if let agreementData = loadFromKeychain(tag: agreementPrivateKeyTag) {
                return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementData)
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

        // ⚠️ Multi-thread safe lazy load:
        // Without keyCacheLock here, two BLE callbacks racing on first peer
        // encounter could each (a) see cachedAgreementPrivateKey == nil,
        // (b) call loadFromKeychain in parallel, (c) double-write the cache.
        // The Keychain call is idempotent so the worst-case data corruption
        // is bounded, but the property-write itself is unsynchronised
        // Swift state — torn reads can crash. Lock for the read+lazy-init.
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
        keyCacheLock.lock()
        let cached = cachedAgreementPrivateKey
        keyCacheLock.unlock()
        if let cached {
            return cached.publicKey.rawRepresentation
        }
        return loadFromKeychain(tag: agreementPublicKeyTag)
    }
    
    /// Get agreement public key as base64 string
    var agreementPublicKeyBase64: String? {
        return agreementPublicKeyData?.base64EncodedString()
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
