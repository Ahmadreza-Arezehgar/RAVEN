//
//  OutboxEntry.swift
//  RAVEN
//
//  Unified Outbox entry - ONE row per message with both server and mesh states
//  Core of "never lose messages" + "don't duplicate" guarantee
//

import Foundation

// MARK: - Route State

/// State machine for each delivery channel (server/mesh)
enum RouteState: Int, Codable {
    case idle = 0       // Not yet queued
    case queued = 1     // Waiting to send
    case sending = 2    // Actively being sent
    case sent = 3       // Sent but not confirmed delivered
    case delivered = 4  // Confirmed delivered to recipient
    case stopped = 5    // Stopped (other channel delivered first)
    case failed = 6     // Permanent failure
}

// MARK: - Delivery Via

/// Which channel delivered the message first
enum DeliveryVia: String, Codable {
    case server
    case mesh
}

// MARK: - Outbox Entry

/// Single persistent entry per message for reliable delivery
/// Both server and mesh states tracked in same row
struct OutboxEntry: Codable, Identifiable {
    /// Client-generated UUID - MUST be stable across routes
    let clientMessageId: String
    
    /// Recipient user ID
    let receiverId: String
    
    /// Message payload (encrypted or plain)
    let payloadCiphertext: String
    
    /// When message was created
    let createdAt: Date
    
    /// Server channel state
    var serverState: RouteState
    
    /// Mesh channel state
    var meshState: RouteState
    
    /// Which channel delivered first
    var deliveredVia: DeliveryVia?
    
    /// When message was delivered
    var deliveredAt: Date?
    
    // MARK: - Delivery Timeline (Observability)
    
    /// When the first mesh broadcast was attempted
    var firstMeshSendAt: Date?
    
    /// When the first server upload was attempted
    var firstServerUploadAt: Date?
    
    /// When the server acknowledged receipt
    var serverAckAt: Date?
    
    /// When cancellation was propagated (stop command sent)
    var cancellationPropagatedAt: Date?
    
    // MARK: - Identifiable
    
    var id: String { clientMessageId }
    
    // MARK: - Computed
    
    /// Is this message fully delivered?
    var isDelivered: Bool {
        deliveredVia != nil
    }
    
    /// Can we attempt server delivery?
    var canSendViaServer: Bool {
        serverState == .queued || serverState == .failed
    }
    
    /// Can we attempt mesh delivery?
    var canSendViaMesh: Bool {
        meshState == .queued || meshState == .failed
    }
    
    /// End-to-end delivery latency (if delivered)
    var deliveryLatency: TimeInterval? {
        guard let delivered = deliveredAt else { return nil }
        return delivered.timeIntervalSince(createdAt)
    }
}

// MARK: - Factory

extension OutboxEntry {
    /// Create a new outbox entry for a message
    static func create(
        clientMessageId: String,
        receiverId: String,
        payload: String,
        serverState: RouteState = .queued,
        meshState: RouteState = .idle
    ) -> OutboxEntry {
        OutboxEntry(
            clientMessageId: clientMessageId,
            receiverId: receiverId,
            payloadCiphertext: payload,
            createdAt: Date(),
            serverState: serverState,
            meshState: meshState,
            deliveredVia: nil,
            deliveredAt: nil,
            firstMeshSendAt: nil,
            firstServerUploadAt: nil,
            serverAckAt: nil,
            cancellationPropagatedAt: nil
        )
    }
}
