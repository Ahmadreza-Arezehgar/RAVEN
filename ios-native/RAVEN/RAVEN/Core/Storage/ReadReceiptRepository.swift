import Foundation

// MARK: - Read Receipt Repository (SQLite persistence for group message reads)

actor ReadReceiptRepository {
    static let shared = ReadReceiptRepository()
    
    private let db = DatabaseService.shared
    
    private init() {}
    
    // MARK: - Table Creation
    
    /// DDL statements for the message_reads table
    static func tableCreationSQL() -> [String] {
        return [
            """
            CREATE TABLE IF NOT EXISTS message_reads (
                message_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                username TEXT NOT NULL,
                avatar_url TEXT,
                seen_at TEXT NOT NULL,
                PRIMARY KEY (message_id, user_id)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_message_reads_msg ON message_reads(message_id)"
        ]
    }
    
    // MARK: - Mark Seen (Idempotent)
    
    /// Record that a user has seen a message. Uses INSERT OR IGNORE for idempotency.
    func markSeen(
        messageId: String,
        userId: String,
        username: String,
        avatarUrl: String?,
        seenAt: Date
    ) async throws {
        let sql = """
            INSERT OR IGNORE INTO message_reads (message_id, user_id, username, avatar_url, seen_at)
            VALUES (?, ?, ?, ?, ?)
        """
        try await db.execute(sql, params: [
            messageId,
            userId,
            username,
            avatarUrl ?? NSNull(),
            SharedDateFormatters.formatISO8601(seenAt)
        ])
    }
    
    // MARK: - Get Seen By (Single Message)
    
    /// Returns all users who have seen a specific message, sorted by most recent first.
    func getSeenBy(messageId: String) async throws -> [SeenByUser] {
        let rows = try await db.query(
            "SELECT user_id, username, avatar_url, seen_at FROM message_reads WHERE message_id = ? ORDER BY seen_at DESC",
            params: [messageId]
        )
        return rows.compactMap { parseSeenByUser(from: $0) }
    }
    
    // MARK: - Get Seen By (Batch — for visible messages)
    
    /// Efficiently loads seen-by data for multiple messages at once.
    /// Returns a dictionary keyed by message_id.
    func getSeenByBatch(messageIds: [String]) async throws -> [String: [SeenByUser]] {
        guard !messageIds.isEmpty else { return [:] }
        
        // Build placeholders: ?, ?, ?
        let placeholders = messageIds.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT message_id, user_id, username, avatar_url, seen_at
            FROM message_reads
            WHERE message_id IN (\(placeholders))
            ORDER BY seen_at DESC
        """
        
        let rows = try await db.query(sql, params: messageIds.map { $0 as Any })
        
        var result: [String: [SeenByUser]] = [:]
        for row in rows {
            guard let msgId = row["message_id"] as? String,
                  let user = parseSeenByUser(from: row) else { continue }
            result[msgId, default: []].append(user)
        }
        return result
    }
    
    // MARK: - Delete (for message deletion cleanup)
    
    /// Remove all read receipts for a specific message
    func deleteForMessage(messageId: String) async throws {
        try await db.execute(
            "DELETE FROM message_reads WHERE message_id = ?",
            params: [messageId]
        )
    }
    
    // MARK: - Parse
    
    private func parseSeenByUser(from row: [String: Any]) -> SeenByUser? {
        guard let userId = row["user_id"] as? String,
              let username = row["username"] as? String,
              let seenAtStr = row["seen_at"] as? String else { return nil }
        
        let seenAt = PerformanceConstants.iso8601Fractional.date(from: seenAtStr)
            ?? PerformanceConstants.iso8601.date(from: seenAtStr)
            ?? Date()
        
        let avatarUrl = row["avatar_url"] as? String
        
        return SeenByUser(
            userId: userId,
            username: username,
            avatarUrl: avatarUrl,
            seenAt: seenAt
        )
    }
}
