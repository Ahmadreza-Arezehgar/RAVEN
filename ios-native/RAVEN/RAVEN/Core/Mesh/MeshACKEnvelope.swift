//
//  MeshACKEnvelope.swift
//  RAVEN
//
//  Lightweight ACK envelope for mesh delivery/read receipts
//

import Foundation

/// Status acknowledgment types
enum ACKStatus: String, Codable {
    case delivered = "delivered"
    case read = "read"
}

/// Compact ACK envelope for mesh delivery receipts
/// Much smaller than full message envelope - only essential fields
/// SECURITY: Includes Ed25519 signature to prevent forged ACKs
struct MeshACKEnvelope: Codable {
    // MARK: - Identifiers
    
    let originalMessageId: String    // ID of message being acknowledged
    let senderId: String             // Who is sending the ACK (the receiver)
    let recipientId: String          // Original message sender (who needs to know)
    
    // MARK: - Status
    
    let status: ACKStatus            // delivered or read
    let timestamp: TimeInterval      // When status changed (Unix timestamp)
    let pathUsed: String?            // server/mesh path used at receiver side
    
    // MARK: - Relay Metadata (for ACK store & forward)
    
    /// Current relay hop for this ACK
    let hopCount: Int
    /// Maximum hops ACK can travel in mesh
    let hopLimit: Int
    /// Device route to avoid loops
    let routePath: [String]
    /// Device that originally generated this ACK
    let originDeviceId: String
    
    // MARK: - Envelope Type Marker
    
    let isACK: Bool                  // Marker to distinguish from regular messages
    
    // MARK: - Security (Ed25519 signature)
    
    var signature: String?           // Ed25519 signature (base64)
    var signerPublicKey: String?     // Signer's public key (base64)
    
    // MARK: - Initialization
    
    init(
        originalMessageId: String,
        senderId: String,
        recipientId: String,
        status: ACKStatus,
        pathUsed: String? = nil,
        originDeviceId: String = "",
        hopCount: Int = 0,
        hopLimit: Int = PremiumLimits.meshHopLimit,
        routePath: [String]? = nil,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        isACK: Bool = true
    ) {
        self.originalMessageId = originalMessageId
        self.senderId = senderId
        self.recipientId = recipientId
        self.status = status
        self.pathUsed = pathUsed
        self.originDeviceId = originDeviceId
        self.hopCount = hopCount
        self.hopLimit = hopLimit
        self.routePath = routePath ?? (originDeviceId.isEmpty ? [] : [originDeviceId])
        self.timestamp = timestamp
        self.isACK = isACK
        self.signature = nil
        self.signerPublicKey = nil
    }
    
    // MARK: - Security Methods
    
    /// Data used for signing: critical fields that must not be tampered (delimited to prevent canonicalization attacks)
    func signingData() -> Data {
        let delimiter = Data("|".utf8)
        var data = Data()
        data.append(originalMessageId.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(senderId.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(recipientId.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(status.rawValue.data(using: .utf8) ?? Data())
        data.append(delimiter)
        // Fix: Use Int64 millis string with round() for deterministic signing across JSON round-trip
        let tsString = String(Int64(round(timestamp * 1000)))
        data.append(tsString.data(using: .utf8) ?? Data())
        return data
    }
    
    /// Sign this ACK with device identity
    mutating func sign() {
        let data = signingData()
        if let sig = DeviceIdentityService.shared.sign(data) {
            signature = sig.base64EncodedString()
            signerPublicKey = DeviceIdentityService.shared.publicKeyBase64
        }
    }
    
    /// Verify the signature on this ACK
    func isSignatureValid() -> Bool {
        guard let sigBase64 = signature,
              let sig = Data(base64Encoded: sigBase64),
              let pubKeyBase64 = signerPublicKey,
              let pubKey = Data(base64Encoded: pubKeyBase64) else {
            return false
        }
        return DeviceIdentityService.shared.verify(
            signature: sig,
            data: signingData(),
            publicKey: pubKey
        )
    }
    
    // MARK: - Relay Helpers
    
    /// Stable idempotency key for ACK relays/uplinks.
    var relayKey: String {
        "\(originalMessageId)|\(senderId)|\(recipientId)|\(status.rawValue)"
    }
    
    /// Whether this ACK can still be forwarded in mesh.
    var canForward: Bool {
        hopCount < hopLimit
    }
    
    func hasPassedThrough(deviceId: String) -> Bool {
        routePath.contains(deviceId)
    }
    
    func forwarded(by deviceId: String) -> MeshACKEnvelope {
        var newPath = routePath
        if !deviceId.isEmpty && !newPath.contains(deviceId) {
            newPath.append(deviceId)
        }
        
        // 🛡️ SECURITY: Preserve original signature and signerPublicKey
        // Relay must NOT re-sign — downstream verifies the ORIGINAL signer
        var ack = MeshACKEnvelope(
            originalMessageId: originalMessageId,
            senderId: senderId,
            recipientId: recipientId,
            status: status,
            pathUsed: pathUsed,
            originDeviceId: originDeviceId,
            hopCount: hopCount + 1,
            hopLimit: hopLimit,
            routePath: newPath,
            timestamp: timestamp,
            isACK: isACK
        )
        ack.signature = self.signature
        ack.signerPublicKey = self.signerPublicKey
        return ack
    }
    
    // MARK: - Codable
    
    enum CodingKeys: String, CodingKey {
        case originalMessageId
        case senderId
        case recipientId
        case status
        case timestamp
        case pathUsed
        case hopCount
        case hopLimit
        case routePath
        case originDeviceId
        case isACK
        case signature
        case signerPublicKey
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        originalMessageId = try container.decode(String.self, forKey: .originalMessageId)
        senderId = try container.decode(String.self, forKey: .senderId)
        recipientId = try container.decode(String.self, forKey: .recipientId)
        status = try container.decode(ACKStatus.self, forKey: .status)
        timestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .timestamp) ?? Date().timeIntervalSince1970
        pathUsed = try container.decodeIfPresent(String.self, forKey: .pathUsed)
        
        // Backward compatibility with older ACK envelopes.
        hopCount = try container.decodeIfPresent(Int.self, forKey: .hopCount) ?? 0
        hopLimit = try container.decodeIfPresent(Int.self, forKey: .hopLimit) ?? PremiumLimits.meshHopLimit
        routePath = try container.decodeIfPresent([String].self, forKey: .routePath) ?? []
        originDeviceId = try container.decodeIfPresent(String.self, forKey: .originDeviceId) ?? ""
        isACK = try container.decodeIfPresent(Bool.self, forKey: .isACK) ?? true
        
        // Security fields (optional for backward compatibility)
        signature = try container.decodeIfPresent(String.self, forKey: .signature)
        signerPublicKey = try container.decodeIfPresent(String.self, forKey: .signerPublicKey)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(originalMessageId, forKey: .originalMessageId)
        try container.encode(senderId, forKey: .senderId)
        try container.encode(recipientId, forKey: .recipientId)
        try container.encode(status, forKey: .status)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(pathUsed, forKey: .pathUsed)
        try container.encode(hopCount, forKey: .hopCount)
        try container.encode(hopLimit, forKey: .hopLimit)
        try container.encode(routePath, forKey: .routePath)
        try container.encode(originDeviceId, forKey: .originDeviceId)
        try container.encode(isACK, forKey: .isACK)
        try container.encodeIfPresent(signature, forKey: .signature)
        try container.encodeIfPresent(signerPublicKey, forKey: .signerPublicKey)
    }
    
    // MARK: - Serialization
    
    /// Encode to compact JSON data for BLE transmission
    /// SECURITY: Signs ACK before encoding
    func toData() -> Data? {
        var signed = self
        if signed.signature == nil {
            signed.sign()
        }
        return try? JSONEncoder().encode(signed)
    }
    
    /// Decode from BLE received data
    static func fromData(_ data: Data) -> MeshACKEnvelope? {
        try? JSONDecoder().decode(MeshACKEnvelope.self, from: data)
    }
}
