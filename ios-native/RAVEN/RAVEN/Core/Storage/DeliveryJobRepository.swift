//
//  DeliveryJobRepository.swift
//  RAVEN
//
//  Persistent job tracking for reliable message delivery
//  Separate from messages to handle retry logic independently
//

import Foundation

// MARK: - Job Channel

enum JobChannel: String, Codable {
    case server = "server"
    case mesh = "mesh"
}

// MARK: - Job State

enum JobState: String, Codable {
    case pending = "pending"
    case inProgress = "in_progress"
    case delivered = "delivered"
    case failed = "failed"
    case stopped = "stopped"
}

// MARK: - Delivery Job Model

struct DeliveryJob: Identifiable {
    let jobId: String
    let messageId: String
    let channel: JobChannel
    var state: JobState
    var attempts: Int
    var nextRetryAt: Date?
    var lastError: String?
    var stopped: Bool
    let createdAt: Date
    var updatedAt: Date
    
    var id: String { jobId }
    
    /// Check if job is ready to be processed
    var isReady: Bool {
        guard state == .pending && !stopped else { return false }
        if let nextRetry = nextRetryAt {
            return Date() >= nextRetry
        }
        return true
    }
}

// MARK: - Repository

actor DeliveryJobRepository {
    static let shared = DeliveryJobRepository()
    
    private let db = DatabaseService.shared
    
    private init() {}
    
    // MARK: - Create Job
    
    /// Create delivery jobs for a message (one per channel)
    func createJobs(messageId: String, channels: [JobChannel] = [.server, .mesh]) async throws {
        let now = Date().timeIntervalSince1970
        
        for channel in channels {
            let jobId = "\(messageId)_\(channel.rawValue)"
            
            // FIX 10: Re-activate delivery job for live location updates
            // INSERT OR IGNORE would silently drop new coordinates
            let sql = """
                INSERT INTO delivery_jobs 
                (job_id, message_id, channel, state, attempts, stopped, created_at, updated_at)
                VALUES (?, ?, ?, 'pending', 0, 0, ?, ?)
                ON CONFLICT(job_id) DO UPDATE SET
                    state = 'pending',
                    attempts = 0,
                    stopped = 0,
                    updated_at = excluded.updated_at
            """
            
            try await db.execute(sql, params: [jobId, messageId, channel.rawValue, now, now])
        }
        
        #if DEBUG
        print("📋 [Job] Created jobs for message \(messageId.prefix(8))")
        #endif
    }
    
    /// Create a single job for one channel
    func createJob(messageId: String, channel: JobChannel) async throws {
        try await createJobs(messageId: messageId, channels: [channel])
    }
    
    // MARK: - Get Jobs
    
    /// Get all ready jobs for a channel (pending and not stopped)
    func getReadyJobs(channel: JobChannel, ignoreBackoff: Bool = false) async throws -> [DeliveryJob] {
        let now = Date().timeIntervalSince1970
        
        let sql: String
        let params: [Any]
        
        if ignoreBackoff {
            sql = """
                SELECT * FROM delivery_jobs 
                WHERE channel = ? 
                AND state = 'pending'
                AND stopped = 0
                ORDER BY created_at ASC
                LIMIT 50
            """
            params = [channel.rawValue]
        } else {
            sql = """
                SELECT * FROM delivery_jobs 
                WHERE channel = ? 
                AND state = 'pending'
                AND stopped = 0
                AND (next_retry_at IS NULL OR next_retry_at <= ?)
                ORDER BY created_at ASC
                LIMIT 50
            """
            params = [channel.rawValue, now]
        }
        
        let rows = try await db.query(sql, params: params)
        return rows.compactMap { parseJob($0) }
    }
    
    /// Get job by message ID and channel
    func getJob(messageId: String, channel: JobChannel) async throws -> DeliveryJob? {
        let sql = "SELECT * FROM delivery_jobs WHERE message_id = ? AND channel = ? LIMIT 1"
        let rows = try await db.query(sql, params: [messageId, channel.rawValue])
        return rows.first.flatMap { parseJob($0) }
    }
    
    // MARK: - Update State
    
    /// Mark job as delivered
    func markDelivered(messageId: String, channel: JobChannel) async throws {
        let now = Date().timeIntervalSince1970
        let sql = """
            UPDATE delivery_jobs 
            SET state = 'delivered', updated_at = ?
            WHERE message_id = ? AND channel = ?
        """
        try await db.execute(sql, params: [now, messageId, channel.rawValue])
        #if DEBUG
        print("✅ [Job] Marked \(channel.rawValue) job delivered for \(messageId.prefix(8))")
        #endif
    }
    
    /// Mark all jobs for a message as stopped
    func markStopped(messageId: String) async throws {
        let now = Date().timeIntervalSince1970
        let sql = """
            UPDATE delivery_jobs 
            SET stopped = 1, state = 'stopped', updated_at = ?
            WHERE message_id = ?
        """
        try await db.execute(sql, params: [now, messageId])
        #if DEBUG
        print("🛑 [Job] Stopped all jobs for \(messageId.prefix(8))")
        #endif
    }
    
    /// Mark specific job as in progress
    func markInProgress(messageId: String, channel: JobChannel) async throws {
        let now = Date().timeIntervalSince1970
        let sql = """
            UPDATE delivery_jobs 
            SET state = 'in_progress', updated_at = ?
            WHERE message_id = ? AND channel = ?
        """
        try await db.execute(sql, params: [now, messageId, channel.rawValue])
    }
    
    /// Increment attempt count and schedule retry
    func incrementAttempt(messageId: String, channel: JobChannel, error: String?, retryAfter: TimeInterval = 30) async throws {
        let now = Date().timeIntervalSince1970
        let nextRetry = now + retryAfter
        
        let sql = """
            UPDATE delivery_jobs 
            SET attempts = attempts + 1, 
                last_error = ?, 
                next_retry_at = ?,
                state = 'pending',
                updated_at = ?
            WHERE message_id = ? AND channel = ?
        """
        try await db.execute(sql, params: [error ?? NSNull(), nextRetry, now, messageId, channel.rawValue])
    }
    
    // MARK: - Check Stopped
    
    /// Check if a message is stopped
    func isStopped(messageId: String) async throws -> Bool {
        let sql = "SELECT stopped FROM delivery_jobs WHERE message_id = ? AND stopped = 1 LIMIT 1"
        return try await db.exists(sql, params: [messageId])
    }
    
    // MARK: - Cleanup
    
    /// Delete old completed jobs (older than 24 hours)
    func cleanupOldJobs() async throws {
        let cutoff = Date().timeIntervalSince1970 - 86400 // 24 hours ago
        let sql = """
            DELETE FROM delivery_jobs 
            WHERE (state = 'delivered' OR state = 'stopped')
            AND updated_at < ?
        """
        try await db.execute(sql, params: [cutoff])
    }
    
    // MARK: - Parse
    
    private func parseJob(_ row: [String: Any]) -> DeliveryJob? {
        guard let jobId = row["job_id"] as? String,
              let messageId = row["message_id"] as? String,
              let channelStr = row["channel"] as? String,
              let channel = JobChannel(rawValue: channelStr),
              let stateStr = row["state"] as? String,
              let state = JobState(rawValue: stateStr),
              let createdAt = (row["created_at"] as? Double).map({ Date(timeIntervalSince1970: $0) }),
              let updatedAt = (row["updated_at"] as? Double).map({ Date(timeIntervalSince1970: $0) })
        else { return nil }
        
        let attempts = (row["attempts"] as? Int64).map { Int($0) } ?? 0
        let stopped = (row["stopped"] as? Int64) == 1
        let nextRetryAt = (row["next_retry_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let lastError = row["last_error"] as? String
        
        return DeliveryJob(
            jobId: jobId,
            messageId: messageId,
            channel: channel,
            state: state,
            attempts: attempts,
            nextRetryAt: nextRetryAt,
            lastError: lastError,
            stopped: stopped,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

// MARK: - Stop Cache Repository

actor StopCacheRepository {
    static let shared = StopCacheRepository()
    
    private let db = DatabaseService.shared
    private let defaultTTL: TimeInterval = 7 * 86400 // 7 days
    
    private init() {}
    
    /// Persist a stop command with TTL
    func persist(_ messageId: String, ttl: TimeInterval? = nil) async throws {
        let now = Date().timeIntervalSince1970
        let expiresAt = now + (ttl ?? defaultTTL)
        
        let sql = """
            INSERT OR REPLACE INTO stop_cache (message_id, stopped_at, expires_at)
            VALUES (?, ?, ?)
        """
        try await db.execute(sql, params: [messageId, now, expiresAt])
    }
    
    /// Check if a message is in stop cache
    func isStopped(_ messageId: String) async throws -> Bool {
        let now = Date().timeIntervalSince1970
        let sql = "SELECT 1 FROM stop_cache WHERE message_id = ? AND expires_at > ? LIMIT 1"
        return try await db.exists(sql, params: [messageId, now])
    }
    
    /// Get all active stops
    func getAllActiveStops() async throws -> Set<String> {
        let now = Date().timeIntervalSince1970
        let sql = "SELECT message_id FROM stop_cache WHERE expires_at > ?"
        let rows = try await db.query(sql, params: [now])
        return Set(rows.compactMap { $0["message_id"] as? String })
    }
    
    /// Remove a stop entry (for live location re-sends)
    func remove(messageId: String) async throws {
        let sql = "DELETE FROM stop_cache WHERE message_id = ?"
        try await db.execute(sql, params: [messageId])
    }
    
    /// Cleanup expired entries
    func cleanupExpired() async throws {
        let now = Date().timeIntervalSince1970
        let sql = "DELETE FROM stop_cache WHERE expires_at <= ?"
        try await db.execute(sql, params: [now])
    }
}
