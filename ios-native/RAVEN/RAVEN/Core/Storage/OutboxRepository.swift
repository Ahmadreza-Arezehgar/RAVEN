//
//  OutboxRepository.swift
//  RAVEN
//
//  Persistent storage for outbox entries
//  Ensures idempotent message handling and deduplication
//

import Foundation

// MARK: - Outbox Repository

actor OutboxRepository {
    static let shared = OutboxRepository()
    
    private let db = DatabaseService.shared
    
    private init() {}
    
    // MARK: - Insert
    
    /// Insert a new outbox entry (upserts for live location updates)
    func insert(_ entry: OutboxEntry) async throws {
        let createdAt = SharedDateFormatters.formatISO8601(entry.createdAt)
        
        // FIX 9: ON CONFLICT DO UPDATE instead of IGNORE
        // Live location reuses the same messageId — IGNORE silently drops updates
        let sql = """
            INSERT INTO outbox 
            (client_message_id, receiver_id, payload, created_at, server_state, mesh_state, delivered_via, delivered_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(client_message_id) DO UPDATE SET
                payload = excluded.payload,
                server_state = excluded.server_state,
                mesh_state = excluded.mesh_state,
                delivered_via = excluded.delivered_via
        """
        
        try await db.execute(sql, params: [
            entry.clientMessageId,
            entry.receiverId,
            entry.payloadCiphertext,
            createdAt,
            entry.serverState.rawValue,
            entry.meshState.rawValue,
            entry.deliveredVia?.rawValue ?? NSNull(),
            entry.deliveredAt.map { SharedDateFormatters.formatISO8601($0) } ?? NSNull()
        ])
        
        #if DEBUG
        print("📦 [Outbox] Inserted entry: \(entry.clientMessageId.prefix(8))")
        #endif
    }
    
    // MARK: - Get Ready Entries
    
    /// Get entries ready for server delivery
    func getReadyForServer() async throws -> [OutboxEntry] {
        let sql = """
            SELECT * FROM outbox 
            WHERE server_state = ? AND delivered_via IS NULL
            ORDER BY created_at ASC
            LIMIT 20
        """
        
        let rows = try await db.query(sql, params: [RouteState.queued.rawValue])
        return rows.compactMap { parseEntry($0) }
    }
    
    /// Get entries ready for mesh delivery
    func getReadyForMesh() async throws -> [OutboxEntry] {
        let sql = """
            SELECT * FROM outbox 
            WHERE mesh_state = ? AND delivered_via IS NULL
            ORDER BY created_at ASC
            LIMIT 20
        """
        
        let rows = try await db.query(sql, params: [RouteState.queued.rawValue])
        return rows.compactMap { parseEntry($0) }
    }
    
    /// Get entry by client message ID
    func get(clientMessageId: String) async throws -> OutboxEntry? {
        let sql = "SELECT * FROM outbox WHERE client_message_id = ? LIMIT 1"
        let rows = try await db.query(sql, params: [clientMessageId])
        return rows.first.flatMap { parseEntry($0) }
    }
    
    // MARK: - Update State
    
    /// Update server channel state
    func updateServerState(clientMessageId: String, state: RouteState) async throws {
        let sql = "UPDATE outbox SET server_state = ? WHERE client_message_id = ?"
        try await db.execute(sql, params: [state.rawValue, clientMessageId])
        #if DEBUG
        print("🔄 [Outbox] Server state → \(state) for \(clientMessageId.prefix(8))")
        #endif
    }
    
    /// Update mesh channel state
    func updateMeshState(clientMessageId: String, state: RouteState) async throws {
        let sql = "UPDATE outbox SET mesh_state = ? WHERE client_message_id = ?"
        try await db.execute(sql, params: [state.rawValue, clientMessageId])
        #if DEBUG
        print("🔄 [Outbox] Mesh state → \(state) for \(clientMessageId.prefix(8))")
        #endif
    }
    
    /// First-arrival custody: stop both channels after a path reports arrival.
    /// This is **not** protocol `DELIVERED_TO_DEVICE` — that stays on
    /// `MessageRepository.markDelivered` after a verified sealed ACK.
    func markFirstArrival(clientMessageId: String, via: DeliveryVia) async throws {
        let now = SharedDateFormatters.formatISO8601(Date())
        
        let sql = """
            UPDATE outbox 
            SET server_state = ?, mesh_state = ?, delivered_via = ?, delivered_at = ?
            WHERE client_message_id = ?
        """
        
        try await db.execute(sql, params: [
            RouteState.stopped.rawValue,
            RouteState.stopped.rawValue,
            via.rawValue,
            now,
            clientMessageId
        ])
        
        #if DEBUG
        print("📤 [Outbox] First arrival via \(via.rawValue): \(clientMessageId.prefix(8))")
        #endif
    }
    
    /// Update a specific timeline timestamp (set-once: only writes if currently NULL)
    func updateTimeline(clientMessageId: String, field: TimelineField, date: Date = Date()) async throws {
        let iso = SharedDateFormatters.formatISO8601(date)
        let sql = "UPDATE outbox SET \(field.column) = ? WHERE client_message_id = ? AND \(field.column) IS NULL"
        try await db.execute(sql, params: [iso, clientMessageId])
    }
    
    /// Timeline fields that can be stamped exactly once
    enum TimelineField {
        case firstMeshSend
        case firstServerUpload
        case serverAck
        case cancellationPropagated
        
        var column: String {
            switch self {
            case .firstMeshSend:            return "first_mesh_send_at"
            case .firstServerUpload:        return "first_server_upload_at"
            case .serverAck:                return "server_ack_at"
            case .cancellationPropagated:   return "cancellation_propagated_at"
            }
        }
    }
    
    // MARK: - Deduplication Check
    
    /// Check if message ID already exists (for receiver-side dedup)
    func exists(clientMessageId: String) async throws -> Bool {
        let sql = "SELECT 1 FROM outbox WHERE client_message_id = ? LIMIT 1"
        return try await db.exists(sql, params: [clientMessageId])
    }
    
    // MARK: - Cleanup
    
    /// Delete delivered entries older than 24 hours
    func cleanupDelivered() async throws {
        let cutoff = SharedDateFormatters.formatISO8601(Date().addingTimeInterval(-86400))
        
        let sql = """
            DELETE FROM outbox 
            WHERE delivered_via IS NOT NULL AND delivered_at < ?
        """
        
        try await db.execute(sql, params: [cutoff])
    }
    
    // MARK: - Parse
    
    private func parseEntry(_ row: [String: Any]) -> OutboxEntry? {
        guard let clientMessageId = row["client_message_id"] as? String,
              let receiverId = row["receiver_id"] as? String,
              let payload = row["payload"] as? String,
              let createdAtStr = row["created_at"] as? String,
              let createdAt = SharedDateFormatters.parseISO8601(createdAtStr),
              let serverStateRaw = row["server_state"] as? Int64,
              let meshStateRaw = row["mesh_state"] as? Int64,
              let serverState = RouteState(rawValue: Int(serverStateRaw)),
              let meshState = RouteState(rawValue: Int(meshStateRaw))
        else { return nil }
        
        let deliveredVia = (row["delivered_via"] as? String).flatMap { DeliveryVia(rawValue: $0) }
        let deliveredAt = (row["delivered_at"] as? String).flatMap { SharedDateFormatters.parseISO8601($0) }
        
        return OutboxEntry(
            clientMessageId: clientMessageId,
            receiverId: receiverId,
            payloadCiphertext: payload,
            createdAt: createdAt,
            serverState: serverState,
            meshState: meshState,
            deliveredVia: deliveredVia,
            deliveredAt: deliveredAt,
            firstMeshSendAt: (row["first_mesh_send_at"] as? String).flatMap { SharedDateFormatters.parseISO8601($0) },
            firstServerUploadAt: (row["first_server_upload_at"] as? String).flatMap { SharedDateFormatters.parseISO8601($0) },
            serverAckAt: (row["server_ack_at"] as? String).flatMap { SharedDateFormatters.parseISO8601($0) },
            cancellationPropagatedAt: (row["cancellation_propagated_at"] as? String).flatMap { SharedDateFormatters.parseISO8601($0) }
        )
    }
}
