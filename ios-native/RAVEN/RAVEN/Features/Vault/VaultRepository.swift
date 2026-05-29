//
//  VaultRepository.swift
//  RAVEN
//
//  SQLite persistence for Vault content.
//

import Foundation

// MARK: - Vault Repository

actor VaultRepository {
    static let shared = VaultRepository()
    private init() {}
    
    func insertContent(_ content: VaultedContent) async throws {
        let sql = """
            INSERT OR IGNORE INTO vaulted_content 
            (content_id, creator_id, creator_pseudonym, title, encrypted_payload,
             nonce, tag, target_cells, resolution, created_at, expires_at,
             is_unlocked, unlock_distance, received_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        let cellsJson = (try? JSONEncoder().encode(content.targetH3Cells)) ?? Data()
        
        try await DatabaseService.shared.execute(sql, params: [
            content.id,
            content.creatorId,
            content.creatorPseudonym,
            content.title,
            content.encryptedPayload.base64EncodedString(),
            content.nonce.base64EncodedString(),
            content.tag.base64EncodedString(),
            String(data: cellsJson, encoding: .utf8) ?? "[]",
            content.resolution,
            Int64(content.createdAt.timeIntervalSince1970 * 1000),
            Int64(content.expiresAt.timeIntervalSince1970 * 1000),
            content.isUnlocked ? 1 : 0,
            content.unlockDistance,
            Int64(content.receivedAt.timeIntervalSince1970 * 1000)
        ])
    }
    
    func getActiveContent() async throws -> [VaultedContent] {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let sql = "SELECT * FROM vaulted_content WHERE expires_at > ? ORDER BY created_at DESC LIMIT 50"
        let rows = try await DatabaseService.shared.query(sql, params: [nowMs])
        return rows.compactMap { parseContent($0) }
    }
    
    func exists(contentId: String) async throws -> Bool {
        let sql = "SELECT 1 FROM vaulted_content WHERE content_id = ? LIMIT 1"
        let rows = try await DatabaseService.shared.query(sql, params: [contentId])
        return !rows.isEmpty
    }
    
    func markUnlocked(contentId: String) async throws {
        let sql = "UPDATE vaulted_content SET is_unlocked = 1 WHERE content_id = ?"
        try await DatabaseService.shared.execute(sql, params: [contentId])
    }
    
    func cleanupExpired() async throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try await DatabaseService.shared.execute(
            "DELETE FROM vaulted_content WHERE expires_at <= ?",
            params: [nowMs]
        )
    }
    
    private func parseContent(_ row: [String: Any]) -> VaultedContent? {
        guard let id = row["content_id"] as? String,
              let creatorId = row["creator_id"] as? String,
              let pseudonym = row["creator_pseudonym"] as? String,
              let title = row["title"] as? String,
              let payloadB64 = row["encrypted_payload"] as? String,
              let nonceB64 = row["nonce"] as? String,
              let tagB64 = row["tag"] as? String,
              let cellsJson = row["target_cells"] as? String,
              let createdAtMs = row["created_at"] as? Int64,
              let expiresAtMs = row["expires_at"] as? Int64,
              let receivedAtMs = row["received_at"] as? Int64,
              let payload = Data(base64Encoded: payloadB64),
              let nonce = Data(base64Encoded: nonceB64),
              let tag = Data(base64Encoded: tagB64) else {
            return nil
        }
        
        let cells = (try? JSONDecoder().decode([String].self, from: Data(cellsJson.utf8))) ?? []
        let resolution = Int(row["resolution"] as? Int64 ?? 7)
        let isUnlocked = (row["is_unlocked"] as? Int64 ?? 0) == 1
        let unlockDistance = Int(row["unlock_distance"] as? Int64 ?? 1200)
        
        return VaultedContent(
            id: id,
            creatorId: creatorId,
            creatorPseudonym: pseudonym,
            title: title,
            encryptedPayload: payload,
            nonce: nonce,
            tag: tag,
            targetH3Cells: cells,
            resolution: resolution,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1000.0),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAtMs) / 1000.0),
            isUnlocked: isUnlocked,
            unlockDistance: unlockDistance,
            receivedAt: Date(timeIntervalSince1970: TimeInterval(receivedAtMs) / 1000.0)
        )
    }
}
