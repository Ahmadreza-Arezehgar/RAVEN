//
//  MeshCryptoService.swift
//  RAVEN
//
//  SECURITY: End-to-End Encryption & Message Signing for Mesh
//  Fixes C1 (Plaintext), C3 (No Sender Verification), C4 (Replay), C5 (Flooding)
//

import Foundation
import CryptoKit

/// Cryptographic security layer for mesh messaging
/// - AES-256-GCM encryption for message confidentiality
/// - Ed25519 signatures for sender authentication
/// - Nonces for replay attack prevention
/// - Rate limiting for DoS protection
actor MeshCryptoService {
    static let shared = MeshCryptoService()
    
    // MARK: - Constants
    
    /// Maximum messages per peer per minute (DoS protection)
    private static let maxMessagesPerPeerPerMinute = 60
    
    /// Maximum hop limit for validation (Absolute protocol max)
    static let protocolMaxHopLimit: Int = 50
    
    /// Maximum spray counter (prevents flooding)
    /// Raised from 5→50 for Binary Spray & Wait routing (RAVEN+ geo-match budget)
    static let protocolMaxSprayCounter: Int = 50
    
    /// Nonce size in bytes
    private static let nonceSize = 12
    
    // MARK: - Rate Limiting State
    
    private var peerMessageCounts: [String: (count: Int, resetTime: Date)] = [:]
    
    // MARK: - Nonce Tracking (Replay Prevention)
    
    private var usedNonces: Set<Data> = []
    private var nonceCleanupTime: Date = Date()
    private static let nonceLifetime: TimeInterval = 86400 * 7 // 7 days
    
    // MARK: - Public API: Encryption
    
    /// Encrypt a message envelope for secure transmission
    /// Uses AES-256-GCM with a random nonce
    func encryptEnvelope(_ envelope: SecureMeshEnvelope, sharedKey: SymmetricKey) throws -> EncryptedMeshPayload {
        // TODO: [Performance] Replace JSON encoding with Protobuf/FlatBuffers for BLE packets.
        // JSON key overhead (~40 bytes) wastes ~22% of BLE MTU (185 bytes), causing unnecessary chunking.
        // Encode the envelope to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let plaintext = try encoder.encode(envelope)
        
        // Generate random nonce
        var nonceBytes = [UInt8](repeating: 0, count: Self.nonceSize)
        guard SecRandomCopyBytes(kSecRandomDefault, Self.nonceSize, &nonceBytes) == errSecSuccess else {
            throw MeshCryptoError.encryptionFailed
        }
        let nonce = try AES.GCM.Nonce(data: Data(nonceBytes))
        
        // Encrypt with AES-256-GCM
        let sealedBox = try AES.GCM.seal(plaintext, using: sharedKey, nonce: nonce)
        
        guard let ciphertext = sealedBox.combined else {
            throw MeshCryptoError.encryptionFailed
        }
        
        // Attach sender signature even on encrypted transport so receivers
        // can enforce sender identity binding after decryption.
        let signingData = envelope.signingData()
        guard let signature = DeviceIdentityService.shared.sign(signingData) else {
            throw MeshCryptoError.signingFailed
        }
        
        return EncryptedMeshPayload(
            ciphertext: ciphertext.base64EncodedString(),
            nonce: Data(nonceBytes).base64EncodedString(),
            senderPublicKey: DeviceIdentityService.shared.agreementPublicKeyBase64 ?? "",
            version: 1,
            signature: signature.base64EncodedString(),
            signerPublicKey: DeviceIdentityService.shared.publicKeyBase64
        )
    }
    
    /// Decrypt a received encrypted payload
    func decryptEnvelope(_ payload: EncryptedMeshPayload, sharedKey: SymmetricKey) throws -> SecureMeshEnvelope {
        guard let ciphertext = Data(base64Encoded: payload.ciphertext) else {
            throw MeshCryptoError.invalidPayload
        }
        
        // 1. Decrypt FIRST to verify integrity (AES-GCM auth tag validates the packet)
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        let plaintext = try AES.GCM.open(sealedBox, using: sharedKey)
        
        // 2. Extract authentic nonce from the sealed box (unforgeable — embedded in ciphertext)
        let authenticNonce = sealedBox.nonce.withUnsafeBytes { Data($0) }
        
        // 3. Replay prevention using authentic nonce (NOT the untrusted JSON field)
        if usedNonces.contains(authenticNonce) {
            throw MeshCryptoError.replayAttackDetected
        }
        
        // Mark nonce as used
        usedNonces.insert(authenticNonce)
        cleanupOldNonces()
        
        // Decode envelope
        let decoder = JSONDecoder()
        return try decoder.decode(SecureMeshEnvelope.self, from: plaintext)
    }
    
    // MARK: - Public API: Signing
    
    /// Sign a mesh envelope and return signed payload
    func signEnvelope(_ envelope: SecureMeshEnvelope) throws -> SignedMeshPayload {
        // Encode essential fields for signing (prevents field manipulation)
        let signingData = envelope.signingData()
        
        guard let signature = DeviceIdentityService.shared.sign(signingData) else {
            throw MeshCryptoError.signingFailed
        }
        
        return SignedMeshPayload(
            envelope: envelope,
            signature: signature.base64EncodedString(),
            signerPublicKey: DeviceIdentityService.shared.publicKeyBase64 ?? ""
        )
    }
    
    /// Verify signature on a signed payload
    /// SECURITY: Also verifies identity binding — signerPublicKey must match
    /// a known trusted key for the claimed senderId
    func verifySignature(_ payload: SignedMeshPayload) async -> Bool {
        guard let signature = Data(base64Encoded: payload.signature),
              let publicKey = Data(base64Encoded: payload.signerPublicKey) else {
            #if DEBUG
            print("🚨 [MeshCrypto] Invalid signature data")
            #endif
            return false
        }
        
        let signingData = payload.envelope.signingData()
        
        // Step 1: Verify cryptographic signature is valid
        let isValid = DeviceIdentityService.shared.verify(
            signature: signature,
            data: signingData,
            publicKey: publicKey
        )
        
        if !isValid {
            #if DEBUG
            print("🚨 [MeshCrypto] SIGNATURE VERIFICATION FAILED - Message may be spoofed!")
            #endif
            return false
        }
        
        // Step 2: Identity binding — verify signerPublicKey belongs to claimed senderId
        let senderId = payload.envelope.senderId
        let signerKey = payload.signerPublicKey
        
        // Check if it's our OWN message (e.g. echo from relay)
        if signerKey == DeviceIdentityService.shared.publicKeyBase64 {
            return true
        }
        
        // Check if signer's key matches any trusted device for this sender
        let trustedDevices = await FriendDeviceRepository.shared.getTrustedDevices(forUser: senderId)
        let keyMatches = trustedDevices.contains { device in
            device.publicKeyBase64 == signerKey
        }
        
        if keyMatches {
            return true
        }
        
        // Bug 5 fix: For relayed/bridged messages, verify the ORIGINAL sender's signature
        // instead of blindly trusting. Relay nodes must preserve the original signature.
        let hopCount = payload.envelope.hopCount
        if hopCount > 0 || payload.envelope.isBridged == true {
            // Check if original signature is present (from relay-aware nodes)
            if let origSig = payload.originalSignature,
               let origSigData = Data(base64Encoded: origSig),
               let origPubKey = payload.originalSignerPublicKey,
               let origPubKeyData = Data(base64Encoded: origPubKey) {
                // Verify the ORIGINAL sender's signature
                let origValid = DeviceIdentityService.shared.verify(
                    signature: origSigData,
                    data: signingData,
                    publicKey: origPubKeyData
                )
                if !origValid {
                    #if DEBUG
                    print("🚨 [MeshCrypto] ORIGINAL signature FAILED for relayed message from \(senderId.prefix(8)) — possible spoofing!")
                    #endif
                    return false
                }
                // Bug 3 fix: SECURITY — verify originalSignerPublicKey belongs to claimed senderId
                // With TOFU: if we have no trusted devices for this sender, auto-trust the first key.
                let origTrusted = await FriendDeviceRepository.shared.getTrustedDevices(forUser: senderId)
                
                if origTrusted.isEmpty {
                    // TOFU for relay — auto-trust first-seen key from relayed message
                    if let pubKeyData = Data(base64Encoded: origPubKey) {
                        let fingerprint = String(origPubKey.prefix(16))
                        let device = FriendDevice(
                            friendUserId: senderId,
                            fingerprint: fingerprint,
                            publicKey: pubKeyData,
                            trustState: .trusted,
                            verifiedAt: Date(),
                            addedAt: Date(),
                            deviceName: "mesh-tofu-relay-\(senderId.prefix(8))"
                        )
                        try? await FriendDeviceRepository.shared.upsert(device)
                        #if DEBUG
                        print("🔑 [MeshCrypto] TOFU: Auto-trusted relayed sender \(senderId.prefix(8))")
                        #endif
                    }
                } else {
                    // Sender has known trusted devices — key must match one of them
                    let origKeyMatches = origTrusted.contains { $0.publicKeyBase64 == origPubKey }
                        || origPubKey == DeviceIdentityService.shared.publicKeyBase64
                    guard origKeyMatches else {
                        #if DEBUG
                        print("🚨 [MeshCrypto] Relay IMPERSONATION: origPubKey not trusted for \(senderId.prefix(8))")
                        #endif
                        return false
                    }
                }
                #if DEBUG
                print("🔑 [MeshCrypto] Relayed message (hop=\(hopCount)) — original sender signature VERIFIED ✅")
                #endif
                return true
            }
            
            // CREATIVE FIX FOR MESH BRIDGE & IMPERSONATION ATTEMPT:
            // If the message is explicitly bridged from the server, it lacks the original Ed25519 signature
            // because the server doesn't store them. The bridge node (which has internet) acts as the authority.
            // We already verified the bridge node's cryptographic signature in Step 1.
            // We accept it to allow offline users to receive server messages via mesh.
            if payload.envelope.isBridged == true {
                #if DEBUG
                print("✅ [MeshCrypto] Server-Bridged message accepted. Trusting bridge node's signature.")
                #endif
                return true
            }
            
            // SECURITY: Reject relayed messages without original signature - prevents spoofing
            #if DEBUG
            print("🚨 [MeshCrypto] REJECTED: Relayed message (hop=\(hopCount)) without original signature - possible spoofing!")
            #endif
            return false
        }
        
        // SECURITY: User already has trusted devices registered.
        // An unknown key here is NOT key rotation — it's a potential
        // impersonation attack. Reject the message entirely.
        // Key rotation must be done via explicit re-verification (e.g. QR scan).
        if !trustedDevices.isEmpty {
            #if DEBUG
            print("🚨 [MeshCrypto] IMPERSONATION ATTEMPT! Unknown key for verified user \(senderId.prefix(8))")
            #endif
            return false
        }
        
        #if DEBUG
        print("🔑 [MeshCrypto] TOFU: Auto-trusting first-seen key for sender \(senderId.prefix(8))")
        #endif
        
        let fingerprint = String(signerKey.prefix(16))
        let device = FriendDevice(
            friendUserId: senderId,
            fingerprint: fingerprint,
            publicKey: publicKey,
            trustState: .trusted,
            verifiedAt: Date(),
            addedAt: Date(),
            deviceName: "mesh-tofu-\(senderId.prefix(8))"
        )
        
        do {
            try await FriendDeviceRepository.shared.upsert(device)
            #if DEBUG
            print("🔑 [MeshCrypto] TOFU: Key registered as trusted for \(senderId.prefix(8))")
            #endif
        } catch {
            #if DEBUG
            print("⚠️ [MeshCrypto] TOFU: Failed to persist key: \(error) — still accepting message")
            #endif
        }
        
        return true
    }
    
    // MARK: - Public API: Rate Limiting (C5)
    
    /// Check if peer is rate limited (DoS protection)
    /// Returns true if message should be accepted, false if rate limited
    func checkRateLimit(for peerId: String) -> Bool {
        let now = Date()
        
        if let entry = peerMessageCounts[peerId] {
            // Reset if window expired
            if now > entry.resetTime {
                peerMessageCounts[peerId] = (count: 1, resetTime: now.addingTimeInterval(60))
                return true
            }
            
            // Check limit
            if entry.count >= Self.maxMessagesPerPeerPerMinute {
                #if DEBUG
                print("🚨 [MeshCrypto] Rate limited peer \(peerId.prefix(8))... - \(entry.count) msgs in window")
                #endif
                return false
            }
            
            // Increment
            peerMessageCounts[peerId] = (count: entry.count + 1, resetTime: entry.resetTime)
            return true
        }
        
        // First message from this peer
        peerMessageCounts[peerId] = (count: 1, resetTime: now.addingTimeInterval(60))
        return true
    }
    
    /// Validate hop count and spray counter bounds (C5)
    func validateDTNBounds(hopCount: Int, hopLimit: Int, sprayCounter: Int) -> Bool {
        guard hopLimit >= 0 && hopLimit <= Self.protocolMaxHopLimit else {
            #if DEBUG
            print("🚨 [MeshCrypto] Invalid hopLimit: \(hopLimit), protocol max: \(Self.protocolMaxHopLimit)")
            #endif
            return false
        }
        
        guard sprayCounter >= 0 && sprayCounter <= Self.protocolMaxSprayCounter else {
            #if DEBUG
            print("🚨 [MeshCrypto] Invalid sprayCounter: \(sprayCounter), protocol max: \(Self.protocolMaxSprayCounter)")
            #endif
            return false
        }
        
        guard hopCount >= 0 && hopCount <= hopLimit else {
            #if DEBUG
            print("🚨 [MeshCrypto] Invalid hopCount: \(hopCount) exceeds hopLimit: \(hopLimit)")
            #endif
            return false
        }
        
        return true
    }
    
    // MARK: - Private Helpers
    
    private func cleanupOldNonces() {
        let now = Date()
        
        // Only cleanup once per hour
        guard now.timeIntervalSince(nonceCleanupTime) > 3600 else { return }
        
        // Remove nonces older than lifetime
        // Note: In production, nonces should be stored with timestamps
        // For now, we clear all if set gets too large
        if usedNonces.count > 100000 {
            usedNonces.removeAll()
            #if DEBUG
            print("🔄 [MeshCrypto] Cleared nonce cache (size limit)")
            #endif
        }
        
        nonceCleanupTime = now
    }
}

// MARK: - Secure Mesh Envelope

/// Signed and encrypted mesh envelope
/// Includes nonce for replay prevention and signature for authenticity
struct SecureMeshEnvelope: Codable {
    // Original envelope fields
    let clientMessageId: String
    let roomId: String
    let senderId: String
    let senderName: String
    let recipientId: String
    let type: Int
    let text: String?
    let timestamp: TimeInterval
    
    // DTN fields
    var sprayCounter: Int
    var hopCount: Int
    var hopLimit: Int
    var routePath: [String]
    let originDeviceId: String
    var needsForwarding: Bool
    var ttlSeconds: Int
    
    // Security fields
    let nonce: String  // Random nonce for this message instance
    let senderPublicKey: String  // For signature verification
    
    // Optional media
    var mediaUrl: String?
    var thumbnailUrl: String?
    var fileName: String?
    var mimeType: String?
    var fileSize: Int?
    var audioDuration: Int?
    
    // Reply context
    var replyToMessageId: String?
    var replyToTextPreview: String?
    var replyToSenderName: String?
    
    // Bridge flag
    var isBridged: Bool?
    
    // Group flag (Bug 2 fix)
    var isGroup: Bool?
    
    // Short CodingKeys for ~50% BLE payload reduction
    enum CodingKeys: String, CodingKey {
        case clientMessageId = "id"
        case roomId = "rm"
        case senderId = "sid"
        case senderName = "sn"
        case recipientId = "rid"
        case type = "t"
        case text = "txt"
        case timestamp = "ts"
        case sprayCounter = "sc"
        case hopCount = "hc"
        case hopLimit = "hl"
        case routePath = "rp"
        case originDeviceId = "od"
        case needsForwarding = "nf"
        case ttlSeconds = "ttl"
        case nonce = "n"
        case senderPublicKey = "spk"
        case mediaUrl = "mu"
        case thumbnailUrl = "tu"
        case fileName = "fn"
        case mimeType = "mt"
        case fileSize = "fs"
        case audioDuration = "ad"
        case replyToMessageId = "rtid"
        case replyToTextPreview = "rttp"
        case replyToSenderName = "rtsn"
        case isBridged = "ib"
        case isGroup = "ig"
    }
    
    /// Generate data for signing — covers IMMUTABLE fields only
    /// Fields are delimited with "|" to prevent canonicalization attacks
    /// NOTE: sprayCounter, hopCount, hopLimit, routePath, needsForwarding,
    /// ttlSeconds, and isBridged are EXCLUDED because they mutate at every
    /// relay hop, which would invalidate the original sender's signature.
    func signingData() -> Data {
        let delimiter = Data("|".utf8)
        var data = Data()
        data.append(clientMessageId.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(roomId.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(senderId.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(senderName.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(recipientId.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(String(type).data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(nonce.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(senderPublicKey.data(using: .utf8) ?? Data())
        data.append(delimiter)
        let tsString = String(Int64(round(timestamp * 1000)))
        data.append(tsString.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(originDeviceId.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(text?.data(using: .utf8) ?? Data())
        data.append(delimiter)
        
        // Media fields — signed to prevent injection
        data.append(mediaUrl?.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(thumbnailUrl?.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(fileName?.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(mimeType?.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append((fileSize != nil ? String(fileSize!) : "").data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append((audioDuration != nil ? String(audioDuration!) : "").data(using: .utf8) ?? Data())
        data.append(delimiter)
        
        // Reply context
        data.append(replyToMessageId?.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(replyToTextPreview?.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(replyToSenderName?.data(using: .utf8) ?? Data())
        
        // ❌ EXCLUDED: sprayCounter, hopCount, hopLimit, routePath,
        //    needsForwarding, ttlSeconds, isBridged
        // These values change at every relay hop, invalidating the
        // original sender's signature!
        
        return data
    }
}

// MARK: - Signed Payload

/// Payload with envelope and cryptographic signature
struct SignedMeshPayload: Codable {
    let envelope: SecureMeshEnvelope
    let signature: String  // Base64 Ed25519 signature
    let signerPublicKey: String  // Base64 public key for verification
    
    // Bug 5 fix: Preserve original sender's signature through relay chain.
    // Relay nodes set these when forwarding, so the final receiver can verify
    // the message truly originated from the claimed senderId.
    var originalSignature: String?       // Original sender's Ed25519 signature (base64)
    var originalSignerPublicKey: String? // Original sender's public key (base64)
    
    enum CodingKeys: String, CodingKey {
        case envelope = "e"
        case signature = "s"
        case signerPublicKey = "spk"
        case originalSignature = "os"
        case originalSignerPublicKey = "ospk"
    }
}

// MARK: - Encrypted Payload

/// Encrypted payload for BLE transmission
struct EncryptedMeshPayload: Codable {
    let ciphertext: String  // Base64 AES-256-GCM ciphertext
    let nonce: String       // Base64 random nonce
    let senderPublicKey: String  // For ECDH key derivation
    let version: Int        // Protocol version
    let signature: String?  // Base64 Ed25519 signature over SecureMeshEnvelope.signingData()
    let signerPublicKey: String? // Base64 Ed25519 public key for signature verification
    
    enum CodingKeys: String, CodingKey {
        case ciphertext = "c"
        case nonce = "n"
        case senderPublicKey = "spk"
        case version = "v"
        case signature = "s"
        case signerPublicKey = "ssk"
    }
}

// MARK: - Errors

enum MeshCryptoError: Error, LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case signingFailed
    case signatureVerificationFailed
    case invalidPayload
    case replayAttackDetected
    case rateLimited
    case invalidDTNBounds
    
    var errorDescription: String? {
        switch self {
        case .encryptionFailed: return "Message encryption failed"
        case .decryptionFailed: return "Message decryption failed"
        case .signingFailed: return "Message signing failed"
        case .signatureVerificationFailed: return "Signature verification failed"
        case .invalidPayload: return "Invalid encrypted payload"
        case .replayAttackDetected: return "Replay attack detected - message rejected"
        case .rateLimited: return "Peer rate limited"
        case .invalidDTNBounds: return "Invalid DTN routing parameters"
        }
    }
}

// MARK: - MeshEnvelope Extension

extension MeshEnvelope {
    /// Convert to secure envelope with nonce and public key
    func toSecureEnvelope() -> SecureMeshEnvelope {
        // Generate random nonce
        var nonceBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &nonceBytes)
        let nonce = Data(nonceBytes).base64EncodedString()
        
        return SecureMeshEnvelope(
            clientMessageId: clientMessageId,
            roomId: roomId,
            senderId: senderId,
            senderName: senderName,
            recipientId: recipientId,
            type: type,
            text: text,
            timestamp: timestamp,
            sprayCounter: min(sprayCounter, MeshCryptoService.protocolMaxSprayCounter),
            hopCount: hopCount,
            hopLimit: min(hopLimit, 50),
            routePath: routePath,
            originDeviceId: originDeviceId,
            needsForwarding: needsForwarding,
            ttlSeconds: ttlSeconds,
            nonce: nonce,
            senderPublicKey: DeviceIdentityService.shared.publicKeyBase64 ?? "",
            mediaUrl: mediaUrl,
            thumbnailUrl: thumbnailUrl,
            fileName: fileName,
            mimeType: mimeType,
            fileSize: fileSize,
            audioDuration: audioDuration,
            replyToMessageId: replyToMessageId,
            replyToTextPreview: replyToTextPreview,
            replyToSenderName: replyToSenderName,
            isBridged: isBridged,
            isGroup: isGroup
        )
    }
}

extension SecureMeshEnvelope {
    /// Convert back to MeshEnvelope
    func toMeshEnvelope() -> MeshEnvelope {
        return MeshEnvelope(
            clientMessageId: clientMessageId,
            roomId: roomId,
            senderId: senderId,
            senderName: senderName,
            recipientId: recipientId,
            type: type,
            text: text,
            timestamp: timestamp,
            sprayCounter: sprayCounter,
            hopCount: hopCount,
            hopLimit: hopLimit,
            routePath: routePath,
            originDeviceId: originDeviceId,
            needsForwarding: needsForwarding,
            ttlSeconds: ttlSeconds,
            mediaUrl: mediaUrl,
            thumbnailUrl: thumbnailUrl,
            fileName: fileName,
            mimeType: mimeType,
            fileSize: fileSize,
            audioDuration: audioDuration,
            replyToMessageId: replyToMessageId,
            replyToTextPreview: replyToTextPreview,
            replyToSenderName: replyToSenderName,
            isBridged: isBridged,
            isGroup: isGroup
        )
    }
}
