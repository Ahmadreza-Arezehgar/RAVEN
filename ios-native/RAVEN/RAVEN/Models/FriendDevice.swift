//
//  FriendDevice.swift
//  RAVEN
//
//  Model for trusted friend devices in mesh network
//

import Foundation

/// Trust state for friend devices
enum TrustState: String, Codable {
    case pending   // Pairing initiated but not verified
    case trusted   // Verified and trusted for mesh messaging
    case revoked   // Explicitly untrusted (key change or manual revoke)
}

/// Represents a friend's device with cryptographic identity
struct FriendDevice: Identifiable, Codable {
    let id: String  // UUID
    let friendUserId: String  // User ID of the friend
    let fingerprint: String  // Derived from public key
    let publicKey: Data  // Raw Ed25519 signing public key bytes
    var agreementPublicKey: Data?  // Bug 6 fix: X25519 agreement key for ECDH encryption
    var trustState: TrustState
    var verifiedAt: Date?  // When trust was established
    let addedAt: Date  // First encountered
    var deviceName: String?  // Optional device label
    var lastSeenAt: Date?  // Last mesh encounter
    
    init(
        id: String = UUID().uuidString,
        friendUserId: String,
        fingerprint: String,
        publicKey: Data,
        agreementPublicKey: Data? = nil,
        trustState: TrustState = .pending,
        verifiedAt: Date? = nil,
        addedAt: Date = Date(),
        deviceName: String? = nil,
        lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.friendUserId = friendUserId
        self.fingerprint = fingerprint
        self.publicKey = publicKey
        self.agreementPublicKey = agreementPublicKey
        self.trustState = trustState
        self.verifiedAt = verifiedAt
        self.addedAt = addedAt
        self.deviceName = deviceName
        self.lastSeenAt = lastSeenAt
    }
}

// MARK: - Computed Properties

extension FriendDevice {
    
    /// Check if this device is trusted for mesh messaging
    var isTrusted: Bool {
        trustState == .trusted
    }
    
    /// Check if this device requires verification
    var needsVerification: Bool {
        trustState == .pending
    }
    
    /// Get short fingerprint for display
    var shortFingerprint: String {
        fingerprint
    }
    
    /// Get public key as base64
    var publicKeyBase64: String {
        publicKey.base64EncodedString()
    }
}
