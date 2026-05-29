//
//  EchoRepository.swift
//  RAVEN
//
//  SQLite persistence for Echo feature.
//  Handles CRUD, dedup via response nonce, and expired echo cleanup.
//

import Foundation

// MARK: - Echo Repository

actor EchoRepository {
    static let shared = EchoRepository()
    private init() {}
    
    // MARK: - Echoes CRUD
    
    /// Insert a new echo. Ignores duplicates (same echo_id).
    func insertEcho(_ echo: Echo) async throws {
        let sql = """
            INSERT OR IGNORE INTO echoes 
            (echo_id, author_pseudonym, content, h3_cell, created_at, expires_at, is_mine, received_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        try await DatabaseService.shared.execute(sql, params: [
            echo.id,
            echo.authorPseudonym,
            echo.content,
            echo.h3Cell as Any,
            Int64(echo.createdAt.timeIntervalSince1970 * 1000),
            Int64(echo.expiresAt.timeIntervalSince1970 * 1000),
            echo.isMine ? 1 : 0,
            Int64(echo.receivedAt.timeIntervalSince1970 * 1000)
        ])
    }
    
    /// Get all active (non-expired) echoes, sorted by recency.
    func getActiveEchoes() async throws -> [Echo] {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let sql = """
            SELECT * FROM echoes 
            WHERE expires_at > ?
            ORDER BY created_at DESC
            LIMIT 100
        """
        let rows = try await DatabaseService.shared.query(sql, params: [nowMs])
        return rows.compactMap { parseEcho($0) }
    }
    
    /// Get echoes authored by this user.
    func getMyEchoes() async throws -> [Echo] {
        let sql = """
            SELECT * FROM echoes 
            WHERE is_mine = 1
            ORDER BY created_at DESC
            LIMIT 50
        """
        let rows = try await DatabaseService.shared.query(sql, params: [])
        return rows.compactMap { parseEcho($0) }
    }
    
    /// Check if an echo already exists (for dedup on receive).
    func exists(echoId: String) async throws -> Bool {
        let sql = "SELECT 1 FROM echoes WHERE echo_id = ? LIMIT 1"
        let rows = try await DatabaseService.shared.query(sql, params: [echoId])
        return !rows.isEmpty
    }
    
    // MARK: - Echo Responses
    
    /// Insert a response. Uses INSERT OR IGNORE with (echo_id, response_nonce) PK
    /// to automatically deduplicate responses arriving from multiple mesh paths.
    func insertResponse(echoId: String, emoji: String, nonce: String) async throws {
        let sql = """
            INSERT OR IGNORE INTO echo_responses 
            (echo_id, response_emoji, response_nonce, received_at)
            VALUES (?, ?, ?, ?)
        """
        try await DatabaseService.shared.execute(sql, params: [
            echoId,
            emoji,
            nonce,
            Int64(Date().timeIntervalSince1970 * 1000)
        ])
    }
    
    /// Get aggregated response counts for an echo.
    func getResponseSummary(echoId: String) async throws -> EchoResponseSummary {
        let sql = """
            SELECT response_emoji, COUNT(*) as cnt 
            FROM echo_responses 
            WHERE echo_id = ?
            GROUP BY response_emoji
        """
        let rows = try await DatabaseService.shared.query(sql, params: [echoId])
        
        var counts: [EchoEmoji: Int] = [:]
        for row in rows {
            if let emojiStr = row["response_emoji"] as? String,
               let emoji = EchoEmoji(rawValue: emojiStr),
               let count = row["cnt"] as? Int64 {
                counts[emoji] = Int(count)
            }
        }
        
        return EchoResponseSummary(echoId: echoId, counts: counts)
    }
    
    /// Get response summaries for multiple echoes (batch).
    func getResponseSummaries(echoIds: [String]) async throws -> [String: EchoResponseSummary] {
        guard !echoIds.isEmpty else { return [:] }
        
        var result: [String: EchoResponseSummary] = [:]
        // Batch in groups of 20 to avoid SQL parameter limits
        for chunk in stride(from: 0, to: echoIds.count, by: 20) {
            let slice = Array(echoIds[chunk..<min(chunk + 20, echoIds.count)])
            let placeholders = slice.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT echo_id, response_emoji, COUNT(*) as cnt 
                FROM echo_responses 
                WHERE echo_id IN (\(placeholders))
                GROUP BY echo_id, response_emoji
            """
            let rows = try await DatabaseService.shared.query(sql, params: slice.map { $0 as Any })
            
            for row in rows {
                guard let echoId = row["echo_id"] as? String,
                      let emojiStr = row["response_emoji"] as? String,
                      let emoji = EchoEmoji(rawValue: emojiStr),
                      let count = row["cnt"] as? Int64 else { continue }
                
                if result[echoId] == nil {
                    result[echoId] = .empty(for: echoId)
                }
                result[echoId]?.counts[emoji] = Int(count)
            }
        }
        
        // Fill in empty summaries for echoes with no responses
        for id in echoIds where result[id] == nil {
            result[id] = .empty(for: id)
        }
        
        return result
    }
    
    /// Check if we already responded to an echo.
    func hasResponded(echoId: String, nonce: String) async throws -> Bool {
        let sql = "SELECT 1 FROM echo_responses WHERE echo_id = ? AND response_nonce = ? LIMIT 1"
        let rows = try await DatabaseService.shared.query(sql, params: [echoId, nonce])
        return !rows.isEmpty
    }
    
    // MARK: - Cleanup
    
    /// Delete expired echoes and their responses.
    func cleanupExpired() async throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        
        // Delete responses for expired echoes first (foreign key)
        let deleteResponses = """
            DELETE FROM echo_responses WHERE echo_id IN (
                SELECT echo_id FROM echoes WHERE expires_at <= ?
            )
        """
        try await DatabaseService.shared.execute(deleteResponses, params: [nowMs])
        
        // Then delete the echoes
        let deleteEchoes = "DELETE FROM echoes WHERE expires_at <= ?"
        try await DatabaseService.shared.execute(deleteEchoes, params: [nowMs])
    }
    
    // MARK: - Parse
    
    private func parseEcho(_ row: [String: Any]) -> Echo? {
        guard let id = row["echo_id"] as? String,
              let pseudonym = row["author_pseudonym"] as? String,
              let content = row["content"] as? String,
              let createdAtMs = row["created_at"] as? Int64,
              let expiresAtMs = row["expires_at"] as? Int64,
              let receivedAtMs = row["received_at"] as? Int64 else {
            return nil
        }
        
        let isMine = (row["is_mine"] as? Int64 ?? 0) == 1
        let h3Cell = row["h3_cell"] as? String
        
        return Echo(
            id: id,
            authorPseudonym: pseudonym,
            content: content,
            h3Cell: h3Cell,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1000.0),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAtMs) / 1000.0),
            isMine: isMine,
            receivedAt: Date(timeIntervalSince1970: TimeInterval(receivedAtMs) / 1000.0)
        )
    }
}
