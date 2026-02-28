//
//  ServerReceipt.swift
//  RAVEN
//
//  Receipt that proves a message has been uploaded to the server.
//  Gossipped via mesh so other nodes don't re-upload the same message.
//

import Foundation

/// Proof that a message has been accepted by the server.
/// When a bridge node successfully uploads a mesh message, it creates
/// this receipt and gossips it to nearby peers. Any peer that receives
/// this receipt marks the message as `serverUploaded = true` and will
/// never attempt to upload it again.
struct ServerReceipt: Codable, Hashable {
    /// The message ID that was uploaded
    let messageId: String
    
    /// When the server acknowledged receipt
    let serverReceivedAt: Date
    
    /// Server's monotonic sequence number (for ordering, if available)
    let serverSequence: Int64?
    
    /// The device that performed the upload (for audit trail)
    let uploaderDeviceId: String
    
    // MARK: - Compact BLE encoding keys
    
    enum CodingKeys: String, CodingKey {
        case messageId = "mid"
        case serverReceivedAt = "sra"
        case serverSequence = "ssq"
        case uploaderDeviceId = "uid"
    }
    
    // MARK: - Serialization
    
    /// Encode to compact JSON data for BLE transmission
    func toData() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    /// Decode from BLE received data
    static func fromData(_ data: Data) -> ServerReceipt? {
        try? JSONDecoder().decode(ServerReceipt.self, from: data)
    }
}

// MARK: - BLE Tagged Wrapper

/// Tagged container for BLE transmission so peers can identify the payload type
struct ServerReceiptWrapper: Codable {
    let kind: String  // "server_receipt_v1"
    let receipt: ServerReceipt
}
