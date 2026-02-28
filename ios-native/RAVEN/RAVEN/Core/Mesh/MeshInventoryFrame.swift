//
//  MeshInventoryFrame.swift
//  RAVEN
//
//  Frame types for inventory-based anti-entropy handshake.
//  When two peers connect, they exchange inventory summaries (Bloom filters)
//  so each can request only the messages it's missing.
//

import Foundation

// MARK: - Frame Kind

/// All inventory exchange frame types, tagged for BLE routing
enum MeshInventoryKind: String, Codable {
    case invBloom = "inv_bloom_v1"   // "Here's what I have" (Bloom filter)
    case want    = "want_v1"         // "Send me these IDs"
}

// MARK: - Inventory Bloom Frame

/// Sent on peer connect: compact summary of which message IDs this peer has seen.
/// The receiver compares against its own store and sends a WANT frame for missing IDs.
struct InvBloomFrame: Codable {
    let kind: String  // MeshInventoryKind.invBloom.rawValue
    let windowId: String       // Unique per-exchange (prevents stale replays)
    let bloom: BloomFilter     // Compact set membership filter
    let peerDeviceId: String   // Sender's device fingerprint
    var userId: String?        // Sender's userId (enables bridge downlink identity)
    
    enum CodingKeys: String, CodingKey {
        case kind = "k"
        case windowId = "wid"
        case bloom = "bf"
        case peerDeviceId = "pid"
        case userId = "uid"
    }
}

// MARK: - Want Frame

/// Response to InvBloom: "I have these IDs that your Bloom says you don't have—here are
/// the ones I want from you." The peer checks its store and sends the actual messages.
struct WantFrame: Codable {
    let kind: String  // MeshInventoryKind.want.rawValue
    let windowId: String        // Must match the INV_BLOOM's windowId
    let wantedIds: [String]     // Message IDs the requester is missing
    let peerDeviceId: String    // Sender's device fingerprint
    var userId: String?         // Sender's userId (enables bridge downlink identity)
    
    enum CodingKeys: String, CodingKey {
        case kind = "k"
        case windowId = "wid"
        case wantedIds = "ids"
        case peerDeviceId = "pid"
        case userId = "uid"
    }
}

// MARK: - Inventory Exchange State

/// Per-peer state for rate-limiting inventory exchanges
struct InventoryExchangeState {
    /// Last time we completed an exchange with this peer
    var lastExchangeAt: Date?
    
    /// Minimum interval between full exchanges (avoid spam on reconnect)
    static let minInterval: TimeInterval = 30  // Once per 30 seconds max
    
    /// Whether enough time has passed for a new exchange
    var canExchange: Bool {
        guard let last = lastExchangeAt else { return true }
        return Date().timeIntervalSince(last) >= Self.minInterval
    }
}
