//
//  RelayQueueRepository.swift
//  RAVEN
//
//  Persistent store-and-forward relay queue. Messages survive BLE restarts
//  and app backgrounding. Uses SQLite (via DatabaseService) for persistence.
//

import Foundation
import SQLCipher

/// Persistent relay queue for mesh store-and-forward
actor RelayQueueRepository {
    static let shared = RelayQueueRepository()
    
    private let db = DatabaseService.shared
    
    // MARK: - Public API
    
    /// Add a relay envelope to the persistent queue
    func enqueue(_ envelope: MeshEnvelope) async {
        let encoder = JSONEncoder()
        guard let json = try? encoder.encode(envelope),
              let jsonStr = String(data: json, encoding: .utf8) else { return }
        
        let now = PerformanceConstants.iso8601.string(from: Date())
        try? await db.execute(
            """
            INSERT OR IGNORE INTO relay_queue (message_id, envelope_json, created_at, ttl_seconds)
            VALUES (?, ?, ?, ?)
            """,
            params: [envelope.clientMessageId, jsonStr, now, envelope.ttlSeconds]
        )
    }
    
    /// Get non-expired envelopes that haven't routed through the given peer, with a cap.
    /// Bug 5 fix: LIMIT prevents loading thousands of entries into RAM at once (OOM crash).
    func getEligible(excludingPeer peerDeviceId: String, limit: Int = 50) async -> [MeshEnvelope] {
        let rows = try? await db.query(
            "SELECT envelope_json FROM relay_queue ORDER BY created_at ASC LIMIT ?",
            params: [limit]
        )
        
        let decoder = JSONDecoder()
        var results = [MeshEnvelope]()
        var expiredIds = [String]()
        
        for row in (rows ?? []) {
            guard let jsonStr = row["envelope_json"] as? String,
                  let data = jsonStr.data(using: .utf8),
                  let env = try? decoder.decode(MeshEnvelope.self, from: data) else { continue }
            
            if env.isExpired {
                expiredIds.append(env.clientMessageId)
                continue
            }
            
            if !env.hasPassedThrough(deviceId: peerDeviceId) {
                results.append(env)
            }
        }
        
        // Cleanup expired
        for id in expiredIds {
            try? await db.execute("DELETE FROM relay_queue WHERE message_id = ?", params: [id])
        }
        
        return results
    }
    
    /// Remove a specific message from the queue (after successful relay)
    func remove(messageId: String) async {
        try? await db.execute("DELETE FROM relay_queue WHERE message_id = ?", params: [messageId])
    }
    
    /// Remove multiple messages
    func removeAll(messageIds: [String]) async {
        for id in messageIds {
            try? await db.execute("DELETE FROM relay_queue WHERE message_id = ?", params: [id])
        }
    }
    
    /// Count of messages in queue.
    /// BUG FIX (2026-05-10): SQLite returns INTEGER columns as `Int64`
    /// via DatabaseService.query (DatabaseService.swift:1099). The
    /// previous `as? Int` cast silently failed and `count()` always
    /// returned 0 — every back-pressure signal, badge, or metric built
    /// on this read "queue empty" while the queue was full. Mirrors the
    /// correct pattern in `MeshSeenPostsRepository.count()`.
    func count() async -> Int {
        let rows = try? await db.query("SELECT COUNT(*) as cnt FROM relay_queue")
        if let i64 = rows?.first?["cnt"] as? Int64 { return Int(i64) }
        if let i = rows?.first?["cnt"] as? Int { return i }
        return 0
    }
    
    /// Cleanup expired entries
    func cleanupExpired() async {
        let rows = try? await db.query("SELECT message_id, envelope_json FROM relay_queue")
        let decoder = JSONDecoder()
        var expiredIds = [String]()
        
        for row in (rows ?? []) {
            guard let jsonStr = row["envelope_json"] as? String,
                  let data = jsonStr.data(using: .utf8),
                  let env = try? decoder.decode(MeshEnvelope.self, from: data) else { continue }
            
            if env.isExpired {
                expiredIds.append(env.clientMessageId)
            }
        }
        
        for id in expiredIds {
            try? await db.execute("DELETE FROM relay_queue WHERE message_id = ?", params: [id])
        }
        
        if !expiredIds.isEmpty {
            #if DEBUG
            print("📦 [RELAY-Q] Cleaned up \(expiredIds.count) expired entries")
            #endif
        }
    }
    
    /// Clear entire queue
    func clearAll() async {
        try? await db.execute("DELETE FROM relay_queue")
    }
    
    // MARK: - Spray Counter Update (Bug 3 fix)
    
    /// Update the spray counter for a relay queue entry (after binary spray halving)
    func updateSprayCounter(messageId: String, newCounter: Int) async {
        // Read, update, write-back the JSON envelope
        guard let rows = try? await db.query(
            "SELECT envelope_json FROM relay_queue WHERE message_id = ?",
            params: [messageId]
        ),
              let jsonStr = rows.first?["envelope_json"] as? String,
              let data = jsonStr.data(using: .utf8),
              var env = try? JSONDecoder().decode(MeshEnvelope.self, from: data)
        else { return }
        
        env.sprayCounter = newCounter
        
        guard let updatedJson = try? JSONEncoder().encode(env),
              let updatedStr = String(data: updatedJson, encoding: .utf8)
        else { return }
        
        try? await db.execute(
            "UPDATE relay_queue SET envelope_json = ? WHERE message_id = ?",
            params: [updatedStr, messageId]
        )
    }
    
    // MARK: - DDL
    
    static func tableCreationSQL() -> [String] {
        [
            """
            CREATE TABLE IF NOT EXISTS relay_queue (
                message_id TEXT PRIMARY KEY,
                envelope_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                ttl_seconds INTEGER NOT NULL DEFAULT 86400
            )
            """
        ]
    }
}
