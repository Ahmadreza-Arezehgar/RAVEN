//
//  RelayReceipt.swift
//  RAVEN
//
//  Signed relay receipt — sent by the first relay node that receives a message,
//  propagated back toward the sender to confirm "in transit" status.
//
//  Design constraints:
//  - Size ~100 bytes (minimal mesh overhead)
//  - TTL 1 hour (state indicator needs real-time data, not historical)
//  - Only first relay sends receipt (not every hop)
//  - Signature by relay node (not sender)
//  - Privacy: relay node ID is HMAC-hashed
//

import Foundation
import CryptoKit

// MARK: - Relay Receipt

struct RelayReceipt: Codable {
    let receiptId: String           // UUID string
    let originalMessageId: String   // Message this receipt is for
    let relayNodeIdHashed: String   // HMAC hash of relay node (privacy)
    let receivedAt: TimeInterval    // Unix timestamp
    let hopCount: UInt8             // Hop count at relay point
    let signature: String?          // Ed25519 signature (base64)
    let signerPublicKey: String?    // Relay node's public key (base64)
    
    // Short coding keys for BLE efficiency
    enum CodingKeys: String, CodingKey {
        case receiptId = "ri"
        case originalMessageId = "omi"
        case relayNodeIdHashed = "rnh"
        case receivedAt = "ra"
        case hopCount = "hc"
        case signature = "s"
        case signerPublicKey = "spk"
    }
    
    /// TTL for relay receipts (1 hour)
    static let ttlSeconds: TimeInterval = 3600
    
    /// Marker byte to distinguish receipts from other mesh packet types
    static let typeMarker = "RR"
    
    // MARK: - Creation
    
    /// Create a relay receipt for a message we just relayed.
    static func create(
        for messageId: String,
        hopCount: UInt8
    ) -> RelayReceipt {
        // HMAC hash our device ID for privacy
        let deviceId = DeviceIdentityService.shared.fingerprint ?? ""
        let hmacKey = SymmetricKey(data: SHA256.hash(data: Data("raven-receipt-key".utf8)))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(deviceId.utf8), using: hmacKey)
        let hashedId = Data(mac).prefix(12).base64EncodedString()
        
        var receipt = RelayReceipt(
            receiptId: UUID().uuidString,
            originalMessageId: messageId,
            relayNodeIdHashed: hashedId,
            receivedAt: Date().timeIntervalSince1970,
            hopCount: hopCount,
            signature: nil,
            signerPublicKey: nil
        )
        
        // Sign the receipt
        receipt = receipt.signed()
        return receipt
    }
    
    // MARK: - Signing
    
    /// Data used for signing — covers all immutable fields.
    func signingData() -> Data {
        let delimiter = Data("|".utf8)
        var data = Data()
        data.append(receiptId.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(originalMessageId.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(relayNodeIdHashed.data(using: .utf8) ?? Data())
        data.append(delimiter)
        let tsString = String(Int64(round(receivedAt * 1000)))
        data.append(tsString.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(Data([hopCount]))
        return data
    }
    
    /// Return a signed copy of this receipt.
    func signed() -> RelayReceipt {
        let data = signingData()
        guard let sig = DeviceIdentityService.shared.sign(data) else { return self }
        
        return RelayReceipt(
            receiptId: receiptId,
            originalMessageId: originalMessageId,
            relayNodeIdHashed: relayNodeIdHashed,
            receivedAt: receivedAt,
            hopCount: hopCount,
            signature: sig.base64EncodedString(),
            signerPublicKey: DeviceIdentityService.shared.publicKeyBase64
        )
    }
    
    /// Verify the signature on this receipt.
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
    
    /// Check if this receipt has expired.
    var isExpired: Bool {
        let created = Date(timeIntervalSince1970: receivedAt)
        return Date() > created.addingTimeInterval(Self.ttlSeconds)
    }
    
    // MARK: - Serialization
    
    /// Encode to Data with type marker for mesh transmission.
    func toData() -> Data? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        // Prepend type marker so packet processor can distinguish receipts
        let marker = RelayReceipt.typeMarker.data(using: .utf8)!
        return marker + data
    }
    
    /// Decode from Data (strips type marker).
    static func fromData(_ data: Data) -> RelayReceipt? {
        let markerLen = typeMarker.utf8.count
        guard data.count > markerLen else { return nil }
        let prefix = String(data: data.prefix(markerLen), encoding: .utf8)
        guard prefix == typeMarker else { return nil }
        return try? JSONDecoder().decode(RelayReceipt.self, from: data.dropFirst(markerLen))
    }
}
