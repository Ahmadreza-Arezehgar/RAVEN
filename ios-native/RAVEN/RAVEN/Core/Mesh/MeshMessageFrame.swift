//
//  MeshMessageFrame.swift
//  RAVEN
//
//  Generic message frame for feature-level mesh messages.
//  Each feature (Flock, Echo, Proximity) wraps its payload in this frame
//  for consistent routing, dedup, and signature handling.
//

import Foundation

// MARK: - Mesh Message Frame

/// Generic envelope for feature-specific mesh messages.
///
/// Usage:
/// ```swift
/// let frame = MeshMessageFrame(
///     kind: .clubPing,
///     payload: ClubPingPayload(clubId: ..., senderId: ..., ...),
///     senderId: userId,
///     hopLimit: 3,
///     sprayCounter: 10
/// )
/// ```
struct MeshMessageFrame<P: Codable>: Codable {
    /// Message kind — determines which handler processes this frame
    let mk: MeshMessageKind
    
    /// Feature-specific payload
    let payload: P
    
    /// Sender's user ID
    let senderId: String
    
    /// Unique message ID for dedup
    let messageId: String
    
    /// Current hop count (incremented at each relay)
    var hopCount: Int
    
    /// Maximum hops allowed
    let hopLimit: Int
    
    /// Remaining spray copies (Binary Spray & Wait)
    var sprayCounter: Int
    
    /// Creation timestamp (ms since epoch)
    let timestamp: Int64
    
    /// Route path — device IDs that have handled this message
    var routePath: [String]
    
    /// TTL in seconds
    var ttlSeconds: Int
    
    /// Ed25519 signature (base64)
    var signature: String?
    
    /// Signer's public key (base64)
    var signerPublicKey: String?
    
    // MARK: - Coding Keys (short for BLE efficiency)
    
    enum CodingKeys: String, CodingKey {
        case mk
        case payload = "p"
        case senderId = "sid"
        case messageId = "mid"
        case hopCount = "hc"
        case hopLimit = "hl"
        case sprayCounter = "sc"
        case timestamp = "ts"
        case routePath = "rp"
        case ttlSeconds = "ttl"
        case signature = "s"
        case signerPublicKey = "spk"
    }
    
    // MARK: - Init
    
    init(
        kind: MeshMessageKind,
        payload: P,
        senderId: String,
        messageId: String = UUID().uuidString,
        hopCount: Int = 0,
        hopLimit: Int = 8,
        sprayCounter: Int = 50,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        routePath: [String] = [],
        ttlSeconds: Int = 3600
    ) {
        self.mk = kind
        self.payload = payload
        self.senderId = senderId
        self.messageId = messageId
        self.hopCount = hopCount
        self.hopLimit = hopLimit
        self.sprayCounter = sprayCounter
        self.timestamp = timestamp
        self.routePath = routePath
        self.ttlSeconds = ttlSeconds
    }
    
    // MARK: - Validation
    
    /// Check if this frame has expired based on TTL.
    var isExpired: Bool {
        let created = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        return Date() > created.addingTimeInterval(TimeInterval(ttlSeconds))
    }
    
    /// Check if this frame should still be processed.
    var isValid: Bool {
        hopCount < hopLimit && sprayCounter > 0 && !isExpired
    }
    
    /// Check if a device has already handled this frame.
    func hasPassedThrough(deviceId: String) -> Bool {
        routePath.contains(deviceId)
    }
    
    /// Create a forwarded copy with updated DTN counters.
    func forwarded(by deviceId: String) -> MeshMessageFrame<P> {
        var copy = self
        copy.hopCount += 1
        copy.routePath.append(deviceId)
        return copy
    }
    
    // MARK: - Serialization
    
    /// Encode to Data for mesh transmission.
    func toData() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Sign the frame in place with the device's Ed25519 key.
    /// Receivers verify against `MeshSignatureVerifier.canonicalSigningData(from:)`,
    /// so the signed bytes are produced by clearing s/spk, encoding, then running
    /// the same canonicalization helper.
    mutating func sign() {
        signature = nil
        signerPublicKey = nil

        guard let raw = try? JSONEncoder().encode(self),
              let canonical = MeshSignatureVerifier.canonicalSigningData(from: raw),
              let sig = DeviceIdentityService.shared.sign(canonical),
              let pk = DeviceIdentityService.shared.publicKeyBase64 else {
            #if DEBUG
            print("⚠️ [MeshMessageFrame] sign() failed — frame will be rejected on receipt")
            #endif
            return
        }

        signature = sig.base64EncodedString()
        signerPublicKey = pk
    }
}

// MARK: - Raw Frame (for JSON peeking)

/// Minimal struct for peeking at the `mk` field before full decode.
/// Used in BLEMeshEngine handler dispatch.
struct MeshMessageFrameHeader: Decodable {
    let mk: MeshMessageKind
    let mid: String?
    
    enum CodingKeys: String, CodingKey {
        case mk
        case mid
    }
}
