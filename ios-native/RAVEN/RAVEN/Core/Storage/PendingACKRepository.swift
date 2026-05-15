//
//  PendingACKRepository.swift
//  RAVEN
//
//  Persists mesh delivery ACKs to sync when internet returns.
//  Part of "First Delivery Wins" pattern.
//

import Foundation

struct PendingACKRecord {
    let clientMessageId: String
    let deliveredVia: String
    let pathUsed: String?
    let idempotencyKey: String?
    let attempts: Int
    let nextRetryAt: TimeInterval
}

struct PendingACKDeadLetterRecord {
    let clientMessageId: String
    let createdAt: String
    let deliveredVia: String
    let pathUsed: String?
    let idempotencyKey: String?
    let attempts: Int
    let failedAt: TimeInterval
    let lastError: String?
}

/// Repository for pending ACKs that need to be synced to server
/// When mesh delivers first but we're offline, queue the ACK here
actor PendingACKRepository {
    static let shared = PendingACKRepository()
    
    private let db = DatabaseService.shared
    private let baseRetrySeconds: TimeInterval = 5
    private let maxRetrySeconds: TimeInterval = 15 * 60
    private let retryJitterRatio: Double = 0.2
    private let maxAttempts: Int = 12
    private let exhaustedRetryDelay: TimeInterval = 30 * 24 * 60 * 60
    
    private init() {}
    
    // MARK: - Public API
    
    /// Add a pending ACK to sync later
    func add(
        clientMessageId: String,
        deliveredVia: String = "mesh",
        pathUsed: String? = "mesh",
        idempotencyKey: String? = nil
    ) async throws {
        let createdAt = SharedDateFormatters.formatISO8601(Date())
        
        let sql = """
            INSERT INTO pending_acks
            (client_message_id, created_at, delivered_via, path_used, idempotency_key, attempts, next_retry_at, last_attempt_at, last_error)
            VALUES (?, ?, ?, ?, ?, 0, 0, NULL, NULL)
            ON CONFLICT(client_message_id) DO UPDATE SET
                delivered_via = excluded.delivered_via,
                path_used = COALESCE(excluded.path_used, pending_acks.path_used),
                idempotency_key = COALESCE(excluded.idempotency_key, pending_acks.idempotency_key),
                attempts = 0,
                next_retry_at = 0,
                last_attempt_at = NULL,
                last_error = NULL
        """
        
        try await db.execute(sql, params: [
            clientMessageId,
            createdAt,
            deliveredVia,
            pathUsed ?? NSNull(),
            idempotencyKey ?? NSNull()
        ])
        #if DEBUG
        print("📥 [PendingACK] Queued: \(clientMessageId.prefix(8))")
        #endif
    }
    
    /// Get all pending ACK IDs (legacy helper).
    func getAll() async throws -> [String] {
        let sql = "SELECT client_message_id FROM pending_acks ORDER BY created_at ASC"
        let rows = try await db.query(sql)
        return rows.compactMap { $0["client_message_id"] as? String }
    }
    
    /// Get pending ACKs ready to be retried now.
    func getDue(limit: Int = 100) async throws -> [PendingACKRecord] {
        let now = Date().timeIntervalSince1970
        let sql = """
            SELECT client_message_id, delivered_via, path_used, idempotency_key, attempts, next_retry_at
            FROM pending_acks
            WHERE COALESCE(next_retry_at, 0) <= ?
              AND COALESCE(attempts, 0) < ?
            ORDER BY COALESCE(next_retry_at, 0) ASC, created_at ASC
            LIMIT ?
        """
        
        let rows = try await db.query(sql, params: [now, maxAttempts, limit])
        return rows.compactMap { row in
            guard let clientMessageId = row["client_message_id"] as? String else {
                return nil
            }
            return PendingACKRecord(
                clientMessageId: clientMessageId,
                deliveredVia: (row["delivered_via"] as? String) ?? "mesh",
                pathUsed: row["path_used"] as? String,
                idempotencyKey: row["idempotency_key"] as? String,
                attempts: intValue(row["attempts"]),
                nextRetryAt: doubleValue(row["next_retry_at"])
            )
        }
    }
    
    /// Remove a pending ACK after successful sync
    func remove(clientMessageId: String) async throws {
        let sql = "DELETE FROM pending_acks WHERE client_message_id = ?"
        try await db.execute(sql, params: [clientMessageId])
        #if DEBUG
        print("✅ [PendingACK] Synced and removed: \(clientMessageId.prefix(8))")
        #endif
    }
    
    /// Record failed retry and schedule next attempt with exponential backoff.
    /// Returns true if another retry is scheduled, false if retries are exhausted.
    func markAttemptFailure(clientMessageId: String, error: String) async throws -> Bool {
        let query = """
            SELECT attempts, created_at, delivered_via, path_used, idempotency_key
            FROM pending_acks
            WHERE client_message_id = ?
            LIMIT 1
        """
        let rows = try await db.query(query, params: [clientMessageId])
        guard let row = rows.first else { return false }
        
        let currentAttempts = intValue(row["attempts"])
        let nextAttempts = currentAttempts + 1
        let now = Date().timeIntervalSince1970
        let safeError = String(error.prefix(240))
        let createdAt = (row["created_at"] as? String) ?? SharedDateFormatters.formatISO8601(Date())
        let deliveredVia = (row["delivered_via"] as? String) ?? "mesh"
        let pathUsed = row["path_used"] as? String
        let idempotencyKey = row["idempotency_key"] as? String
        
        if nextAttempts >= maxAttempts {
            do {
                try await moveToDeadLetter(
                    clientMessageId: clientMessageId,
                    createdAt: createdAt,
                    deliveredVia: deliveredVia,
                    pathUsed: pathUsed,
                    idempotencyKey: idempotencyKey,
                    attempts: nextAttempts,
                    failedAt: now,
                    lastError: safeError
                )
                try await db.execute(
                    "DELETE FROM pending_acks WHERE client_message_id = ?",
                    params: [clientMessageId]
                )
                #if DEBUG
                print("🧯 [PendingACK] Moved to dead-letter: \(clientMessageId.prefix(8))")
                #endif
            } catch {
                // Fail-safe: keep the row with exhausted state for manual inspection.
                let update = """
                    UPDATE pending_acks
                    SET attempts = ?, last_attempt_at = ?, next_retry_at = ?, last_error = ?
                    WHERE client_message_id = ?
                """
                try await db.execute(
                    update,
                    params: [
                        nextAttempts,
                        now,
                        now + exhaustedRetryDelay,
                        "dead_letter_failed: \(String(error.localizedDescription.prefix(200)))",
                        clientMessageId
                    ]
                )
            }
            return false
        }
        
        let nextRetryAt = now + retryDelay(forAttempt: nextAttempts, clientMessageId: clientMessageId)
        
        let update = """
            UPDATE pending_acks
            SET attempts = ?, last_attempt_at = ?, next_retry_at = ?, last_error = ?
            WHERE client_message_id = ?
        """
        try await db.execute(update, params: [nextAttempts, now, nextRetryAt, safeError, clientMessageId])
        return true
    }
    
    /// Count pending ACKs
    func count() async throws -> Int {
        let sql = "SELECT COUNT(*) as count FROM pending_acks"
        let rows = try await db.query(sql)
        return (rows.first?["count"] as? Int64).map { Int($0) } ?? 0
    }
    
    /// Count dead-letter ACKs for diagnostics.
    func deadLetterCount() async throws -> Int {
        let sql = "SELECT COUNT(*) as count FROM pending_ack_dead_letters"
        let rows = try await db.query(sql)
        return (rows.first?["count"] as? Int64).map { Int($0) } ?? 0
    }
    
    /// Recent dead letters for support/inspection tools.
    func getRecentDeadLetters(limit: Int = 50) async throws -> [PendingACKDeadLetterRecord] {
        let sql = """
            SELECT client_message_id, created_at, delivered_via, path_used, idempotency_key, attempts, failed_at, last_error
            FROM pending_ack_dead_letters
            ORDER BY failed_at DESC
            LIMIT ?
        """
        
        let rows = try await db.query(sql, params: [limit])
        return rows.compactMap { row in
            guard
                let clientMessageId = row["client_message_id"] as? String,
                let createdAt = row["created_at"] as? String
            else {
                return nil
            }
            return PendingACKDeadLetterRecord(
                clientMessageId: clientMessageId,
                createdAt: createdAt,
                deliveredVia: (row["delivered_via"] as? String) ?? "mesh",
                pathUsed: row["path_used"] as? String,
                idempotencyKey: row["idempotency_key"] as? String,
                attempts: intValue(row["attempts"]),
                failedAt: doubleValue(row["failed_at"]),
                lastError: row["last_error"] as? String
            )
        }
    }
    
    /// Clear old pending ACKs (older than 7 days).
    /// BUG FIX (2026-05-10): the previous version did an unconditional
    /// `DELETE … WHERE created_at < ?` over the 7-day window. An ACK
    /// that had been actively retrying (server unreachable on a long
    /// offline trip) was silently dropped — the recipient never learned
    /// the message was delivered AND no dead-letter entry survived for
    /// post-mortem. New behaviour: only delete entries that have
    /// EITHER (a) exhausted their `attempts` budget OR (b) are old AND
    /// not actively retrying (next_retry_at IS NULL or in the past).
    /// Anything else is kept so the retry loop has a chance to catch up.
    func cleanup() async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let cutoffStr = SharedDateFormatters.formatISO8601(cutoff)
        let nowStr = SharedDateFormatters.formatISO8601(Date())

        // Hard-delete only the entries that are genuinely lost causes.
        // An entry that's >7 days old AND has used >=maxAttempts is
        // unrecoverable; one that's old but still has retry budget left
        // is preserved.
        let sql = """
            DELETE FROM pending_acks
            WHERE created_at < ?
              AND (
                  attempts >= ?
                  OR next_retry_at IS NULL
                  OR next_retry_at <= ?
              )
        """
        try await db.execute(sql, params: [cutoffStr, maxAttempts, nowStr])

        // Dead-letter table pruned at 30 days unchanged.
        let deadLetterCutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let deadLetterCutoffTs = deadLetterCutoff.timeIntervalSince1970
        try await db.execute(
            "DELETE FROM pending_ack_dead_letters WHERE failed_at < ?",
            params: [deadLetterCutoffTs]
        )
    }
    
    // MARK: - Helpers
    
    private func retryDelay(forAttempt attempt: Int, clientMessageId: String) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let raw = baseRetrySeconds * pow(2, Double(exponent))
        let clamped = min(raw, maxRetrySeconds)
        let jitter = stableJitter(messageId: clientMessageId, attempt: attempt)
        let jittered = clamped * (1 + (retryJitterRatio * jitter))
        return max(baseRetrySeconds, min(jittered, maxRetrySeconds))
    }
    
    /// Stable jitter in [-1, 1] based on message id + attempt.
    /// This avoids synchronized retries while staying deterministic across restarts.
    private func stableJitter(messageId: String, attempt: Int) -> Double {
        let bytes = Array("\(messageId)#\(attempt)".utf8)
        var hash: UInt64 = 1469598103934665603
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        let normalized = Double(hash % 10_000) / 9_999.0
        return (normalized * 2) - 1
    }
    
    private func moveToDeadLetter(
        clientMessageId: String,
        createdAt: String,
        deliveredVia: String,
        pathUsed: String?,
        idempotencyKey: String?,
        attempts: Int,
        failedAt: TimeInterval,
        lastError: String
    ) async throws {
        let sql = """
            INSERT INTO pending_ack_dead_letters
            (client_message_id, created_at, delivered_via, path_used, idempotency_key, attempts, failed_at, last_error)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(client_message_id) DO UPDATE SET
                delivered_via = excluded.delivered_via,
                path_used = excluded.path_used,
                idempotency_key = excluded.idempotency_key,
                attempts = excluded.attempts,
                failed_at = excluded.failed_at,
                last_error = excluded.last_error
        """
        try await db.execute(
            sql,
            params: [
                clientMessageId,
                createdAt,
                deliveredVia,
                pathUsed ?? NSNull(),
                idempotencyKey ?? NSNull(),
                attempts,
                failedAt,
                "max_attempts_exceeded: \(lastError)"
            ]
        )
    }
    
    private func intValue(_ value: Any?) -> Int {
        if let v = value as? Int { return v }
        if let v = value as? Int64 { return Int(v) }
        if let v = value as? Double { return Int(v) }
        return 0
    }
    
    private func doubleValue(_ value: Any?) -> Double {
        if let v = value as? Double { return v }
        if let v = value as? Int64 { return Double(v) }
        if let v = value as? Int { return Double(v) }
        return 0
    }
}
