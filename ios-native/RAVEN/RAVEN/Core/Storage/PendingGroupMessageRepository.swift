//
//  PendingGroupMessageRepository.swift
//  RAVEN
//
//  Bug 2 fix: Limbo storage for mesh messages targeting groups
//  that don't yet exist in the local database. Once the group
//  syncs from the server, these messages are promoted to the
//  main messages table and displayed in the chat.
//

import Foundation

/// Stores mesh messages for groups we don't recognise yet (offline group invite scenario)
actor PendingGroupMessageRepository {
    static let shared = PendingGroupMessageRepository()
    
    private let db = DatabaseService.shared

    /// Hard cap on limbo rows — bounds storage if a peer sprays envelopes for
    /// non-existent groups (DoS guard). Newest rows are kept on overflow.
    private static let maxPendingRows = 2000

    // MARK: - Table DDL
    
    static func tableCreationSQL() -> [String] {
        [
            """
            CREATE TABLE IF NOT EXISTS pending_group_messages (
                client_message_id TEXT PRIMARY KEY,
                group_id TEXT NOT NULL,
                envelope_json TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_pgm_group ON pending_group_messages(group_id)"
        ]
    }
    
    // MARK: - Store
    
    /// Save a mesh message for an unknown group
    func store(_ envelope: MeshEnvelope) async {
        guard let json = try? JSONEncoder().encode(envelope),
              let jsonStr = String(data: json, encoding: .utf8) else { return }
        
        let now = PerformanceConstants.iso8601.string(from: Date())
        try? await db.execute(
            """
            INSERT OR IGNORE INTO pending_group_messages
            (client_message_id, group_id, envelope_json, created_at)
            VALUES (?, ?, ?, ?)
            """,
            params: [envelope.clientMessageId, envelope.recipientId, jsonStr, now]
        )

        // 🔴 AUDIT 2026-05-29 (#101) — bound the limbo table under a flood;
        // keep the newest maxPendingRows (the just-inserted row is retained).
        try? await db.execute(
            """
            DELETE FROM pending_group_messages WHERE client_message_id NOT IN (
                SELECT client_message_id FROM pending_group_messages ORDER BY created_at DESC LIMIT ?
            )
            """,
            params: [Self.maxPendingRows]
        )

        #if DEBUG
        print("📦 [PendingGroup] Stored message \(envelope.clientMessageId.prefix(8)) for unknown group \(envelope.recipientId.prefix(8))")
        #endif
    }
    
    // MARK: - Promote
    
    /// Get and remove all pending messages for a group that was just synced
    func promoteMessages(forGroup groupId: String) async -> [MeshEnvelope] {
        guard let rows = try? await db.query(
            "SELECT envelope_json FROM pending_group_messages WHERE group_id = ?",
            params: [groupId]
        ) else { return [] }
        
        let decoder = JSONDecoder()
        var envelopes = [MeshEnvelope]()
        
        for row in rows {
            if let jsonStr = row["envelope_json"] as? String,
               let data = jsonStr.data(using: .utf8),
               let env = try? decoder.decode(MeshEnvelope.self, from: data) {
                envelopes.append(env)
            }
        }
        
        // Remove promoted messages
        if !envelopes.isEmpty {
            try? await db.execute(
                "DELETE FROM pending_group_messages WHERE group_id = ?",
                params: [groupId]
            )
            #if DEBUG
            print("📦 [PendingGroup] Promoted \(envelopes.count) messages for group \(groupId.prefix(8))")
            #endif
        }
        
        return envelopes
    }
    
    // MARK: - Cleanup
    
    /// Remove entries older than 7 days
    func cleanupExpired() async {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let cutoffStr = PerformanceConstants.iso8601.string(from: cutoff)
        try? await db.execute(
            "DELETE FROM pending_group_messages WHERE created_at < ?",
            params: [cutoffStr]
        )
    }
}
