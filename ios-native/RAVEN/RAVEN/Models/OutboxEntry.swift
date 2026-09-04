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
    case sent = 3       // Sent / forwarded (transport success)
    case delivered = 4  // Legacy first-arrival custody — not protocol Delivered
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
    
    /// First-arrival custody recorded (a channel reported arrival).
    /// Not protocol Delivered — UI must use `MessageStatus` from a verified ACK.
    var hasFirstArrival: Bool {
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
    /// Create a new outbox entry for a message.
    ///
    /// 🔴 SECURITY FIX (2026-05-16 — round 10): the previous
    /// implementation stored `payload` straight into
    /// `payloadCiphertext` without any encryption, which made
    /// every `MessageRouter` server send leak plaintext over the
    /// wire even though the field name implied otherwise. Now we
    /// run the body through `MessageContentSealer` so the rest of
    /// the pipeline really does ship opaque bytes (Noise-sealed
    /// when a session is live, transparent-plaintext-flagged
    /// otherwise — see `MessageContentSealer.SealReason`).
    static func create(
        clientMessageId: String,
        receiverId: String,
        payload: String,
        serverState: RouteState = .queued,
        meshState: RouteState = .idle
    ) async -> OutboxEntry {
        // Round 12: pass the receiverId in so the sealer can lazy-
        // fetch + verify the recipient's prekey bundle on miss. The
        // directory is the SoT for verified peer agreement keys.
        let sealed = await MessageContentSealer.seal(
            plaintext: payload,
            recipientUserId: receiverId,
            recipientAgreementPubKey: nil,
            msgId: clientMessageId
        )
        // Round 15 — mirror the seal verdict so the sender's bubble
        // gets a lock badge that matches what the receiver sees.
        await MessageContentSealer.recordSealVerdict(sealed.reason, for: clientMessageId)
        return OutboxEntry(
            clientMessageId: clientMessageId,
            receiverId: receiverId,
            payloadCiphertext: sealed.base64,
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
