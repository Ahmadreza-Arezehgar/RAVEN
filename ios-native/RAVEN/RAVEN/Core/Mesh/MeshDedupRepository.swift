//
//  MeshDedupRepository.swift
//  RAVEN
//
//  SECURITY: Persistent Deduplication Cache for Replay Attack Prevention (C4)
//  Stores message IDs and nonces in SQLite with 30-day retention.
//  Uses DatabaseService actor methods (execute/query) for thread-safe DB access.
//

import Foundation
import SQLCipher

/// Persistent repository for mesh message deduplication
/// Prevents replay attacks by tracking processed message IDs and nonces
actor MeshDedupRepository: DeduplicationProviding {
    static let shared = MeshDedupRepository()
    
    // MARK: - Constants
    
    /// Cache retention period (30 days)
    private static let retentionDays: Int = 30
    
    /// Cleanup interval (every 6 hours)
    private static let cleanupInterval: TimeInterval = 6 * 3600
    
    // MARK: - State
    
    private let db = DatabaseService.shared
    private var lastCleanup: Date = Date()
    private var memoryCache: Set<String> = []  // Fast in-memory lookup
    private var cacheInsertionOrder: [String] = []  // FIFO queue for ordered eviction
    private let maxMemoryCacheSize = 10000
    
    // MARK: - Public API
    
    /// Check if message has been processed before
    /// Returns true if message is NEW (should be processed)
    /// Returns false if message is DUPLICATE (should be rejected)
    func isNewMessage(id: String) async -> Bool {
        // Fast path: check memory cache first
        if memoryCache.contains(id) {
            return false  // Duplicate
        }
        
        // Bug 2 fix: Claim the ID in RAM BEFORE any await to prevent actor reentrancy
        // from letting a second task also see this message as "new".
        addToMemoryCache(id)
        
        // Check database
        let exists = await checkDatabase(messageId: id)
        if exists {
            return false  // Duplicate (was already in DB)
        }
        
        return true  // New message
    }
    
    /// Retract a claimed message ID (e.g. when signature verification fails).
    /// This allows the message to be re-processed if it arrives again with a valid signature.
    func unclaimMessage(id: String) {
        memoryCache.remove(id)
        cacheInsertionOrder.removeAll(where: { $0 == id })
    }
    
    /// Mark message as processed
    func markProcessed(id: String, nonce: String? = nil) async {
        // Add to memory cache
        addToMemoryCache(id)
        
        // Persist to database
        await insertToDatabase(messageId: id, nonce: nonce)
        
        // Periodic cleanup
        await periodicCleanup()
    }
    
    /// Check if nonce has been used (replay prevention).
    /// BUG FIX (2026-05-10): the previous version's `insertToDatabase`
    /// stored `nonce ?? ""` for messages without a nonce, which collided
    /// every empty-nonce caller against every other empty-nonce caller
    /// — a freshly-arrived no-nonce message looked "already used" and
    /// got silently dropped. Now `insertToDatabase` writes NULL for
    /// missing nonces (via NSNull binding), and this method short-
    /// circuits to `false` for empty input rather than asking the DB.
    func isNonceUsed(_ nonce: String) async -> Bool {
        guard !nonce.isEmpty else { return false }
        let rows = try? await db.query(
            "SELECT 1 FROM mesh_dedup_cache WHERE nonce = ? LIMIT 1",
            params: [nonce]
        )
        return !(rows?.isEmpty ?? true)
    }
    
    /// Clear all cached data (for testing/reset)
    func clearAll() async {
        memoryCache.removeAll()
        cacheInsertionOrder.removeAll()
        try? await db.execute("DELETE FROM mesh_dedup_cache")
        #if DEBUG
        print("🗑️ [MeshDedup] Cleared all dedup cache")
        #endif
    }
    
    /// Get recent message IDs for Bloom filter population (anti-entropy).
    /// Returns up to `limit` most recent IDs (default 1000).
    func getRecentMessageIds(limit: Int = 1000) async -> [String] {
        let rows = try? await db.query(
            "SELECT message_id FROM mesh_dedup_cache ORDER BY processed_at DESC LIMIT ?",
            params: [limit]
        )
        return rows?.compactMap { $0["message_id"] as? String } ?? []
    }
    
    // MARK: - Database Operations
    
    private func checkDatabase(messageId: String) async -> Bool {
        let rows = try? await db.query(
            "SELECT 1 FROM mesh_dedup_cache WHERE message_id = ? LIMIT 1",
            params: [messageId]
        )
        return !(rows?.isEmpty ?? true)
    }
    
    private func insertToDatabase(messageId: String, nonce: String?) async {
        let now = PerformanceConstants.iso8601.string(from: Date())
        // BUG FIX (2026-05-10): bind NSNull when nonce is nil so the
        // SQL column is genuinely NULL — preserves the column's
        // semantics for `IS NULL` filters AND prevents the
        // empty-string collision pathology described in `isNonceUsed`.
        let nonceParam: Any = (nonce?.isEmpty == false) ? nonce! : NSNull()
        try? await db.execute(
            "INSERT OR IGNORE INTO mesh_dedup_cache (message_id, nonce, processed_at) VALUES (?, ?, ?)",
            params: [messageId, nonceParam, now]
        )
    }
    
    private func periodicCleanup() async {
        let now = Date()
        guard now.timeIntervalSince(lastCleanup) > Self.cleanupInterval else { return }
        
        lastCleanup = now
        
        // Delete entries older than retention period
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: now)!
        let cutoffString = PerformanceConstants.iso8601.string(from: cutoffDate)
        
        try? await db.execute(
            "DELETE FROM mesh_dedup_cache WHERE processed_at < ?",
            params: [cutoffString]
        )
        
        // Trim memory cache if too large — evict OLDEST entries via FIFO queue
        if memoryCache.count > maxMemoryCacheSize {
            let removeCount = memoryCache.count / 2
            let toRemove = Array(cacheInsertionOrder.prefix(removeCount))
            for id in toRemove {
                memoryCache.remove(id)
            }
            cacheInsertionOrder.removeFirst(min(removeCount, cacheInsertionOrder.count))
            #if DEBUG
            print("🧹 [MeshDedup] Trimmed memory cache to \(memoryCache.count)")
            #endif
        }
    }
    
    // MARK: - Memory Cache
    
    private func addToMemoryCache(_ id: String) {
        guard !memoryCache.contains(id) else { return }  // Already cached
        if memoryCache.count >= maxMemoryCacheSize {
            // Evict oldest entry via FIFO queue
            if let oldest = cacheInsertionOrder.first {
                memoryCache.remove(oldest)
                cacheInsertionOrder.removeFirst()
            }
        }
        memoryCache.insert(id)
        cacheInsertionOrder.append(id)
    }
}

// MARK: - Database Migration

extension MeshDedupRepository {
    /// Returns DDL statements for dedup cache table creation.
    /// Called via `DatabaseService.executeDDL()` during migrations.
    static func tableCreationSQL() -> [String] {
        [
            """
            CREATE TABLE IF NOT EXISTS mesh_dedup_cache (
                message_id TEXT PRIMARY KEY,
                nonce TEXT,
                processed_at TEXT NOT NULL,
                UNIQUE(message_id)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_dedup_nonce ON mesh_dedup_cache(nonce)",
            "CREATE INDEX IF NOT EXISTS idx_dedup_date ON mesh_dedup_cache(processed_at)"
        ]
    }
}
