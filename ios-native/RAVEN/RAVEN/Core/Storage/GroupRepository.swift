import Foundation

// MARK: - Group Repository

/// Actor for local group persistence with thread-safe SQLite operations
actor GroupRepository {
    private let db: DatabaseService
    
    init(db: DatabaseService = .shared) {
        self.db = db
    }
    
    // MARK: - Upsert
    
    /// Insert or update a group in the local database
    func upsert(_ group: ChatGroup) async throws {
        let membersJson: String?
        if let members = group.members {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(members) {
                membersJson = String(data: data, encoding: .utf8)
            } else {
                membersJson = nil
            }
        } else {
            membersJson = nil
        }
        
        let sql = """
            INSERT INTO groups (
                id, name, avatar_url, description, created_by,
                creator_username, created_at, member_count, members_json,
                sync_status, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                avatar_url = COALESCE(excluded.avatar_url, groups.avatar_url),
                description = COALESCE(excluded.description, groups.description),
                member_count = excluded.member_count,
                members_json = COALESCE(excluded.members_json, groups.members_json),
                sync_status = excluded.sync_status,
                updated_at = MAX(excluded.updated_at, groups.updated_at)
        """
        
        let fmt = PerformanceConstants.iso8601Fractional
        
        try await db.execute(sql, params: [
            group.id,
            group.name,
            group.avatarUrl ?? NSNull(),
            group.description ?? NSNull(),
            group.createdBy,
            group.creatorUsername ?? NSNull(),
            fmt.string(from: group.createdAt),
            group.memberCount,
            membersJson ?? NSNull(),
            group.syncStatus?.rawValue ?? "synced",
            fmt.string(from: Date())
        ])
        
        #if DEBUG
        print("👥 [GroupRepository] Upserted group: \(group.name)")
        #endif
    }
    
    // MARK: - Get All
    
    /// Get all groups for the current user
    func getAll() async throws -> [ChatGroup] {
        let sql = """
            SELECT * FROM groups
            ORDER BY updated_at DESC
        """
        
        let rows = try await db.query(sql)
        return rows.compactMap { parseGroup($0) }
    }
    
    // MARK: - Get Single
    
    /// Get a single group by ID
    func get(groupId: String) async throws -> ChatGroup? {
        let sql = "SELECT * FROM groups WHERE id = ?"
        let rows = try await db.query(sql, params: [groupId])
        return rows.first.flatMap { parseGroup($0) }
    }
    
    // MARK: - Delete
    
    /// Delete a group from local database
    func delete(groupId: String) async throws {
        let sql = "DELETE FROM groups WHERE id = ?"
        try await db.execute(sql, params: [groupId])
        #if DEBUG
        print("🗑️ [GroupRepository] Deleted group: \(groupId)")
        #endif
    }
    
    // MARK: - Update Sync Status
    
    /// Update sync status for a group (for offline-first patterns)
    func updateSyncStatus(groupId: String, status: ChatGroup.SyncStatus) async throws {
        let sql = "UPDATE groups SET sync_status = ? WHERE id = ?"
        try await db.execute(sql, params: [status.rawValue, groupId])
    }

    /// All groups that were created locally and haven't been confirmed by the
    /// server yet (offline-first creation path). Used by `syncPendingGroups()`
    /// on reconnect to retry the create call.
    func allPending() async throws -> [ChatGroup] {
        let sql = "SELECT * FROM groups WHERE sync_status = 'pending'"
        let rows = try await db.query(sql, params: [])
        return rows.compactMap { parseGroup($0) }
    }

    /// Re-key a locally-created group to its server-assigned ID after the
    /// pending create succeeds. Replaces the row at the new ID, deletes the
    /// old one, and applies the up-to-date server fields (memberCount,
    /// members, etc.). Caller is also responsible for re-keying messages
    /// and conversation rows referencing the old ID.
    func remapId(from oldId: String, to newId: String, applying server: ChatGroup) async throws {
        // Insert/Update with the new server identity, then drop the local row.
        try await upsert(server)
        if oldId != newId {
            try await db.execute("DELETE FROM groups WHERE id = ?", params: [oldId])
        }
    }
    
    // MARK: - Helpers
    
    private func parseGroup(_ row: [String: Any]) -> ChatGroup? {
        guard
            let id = row["id"] as? String,
            let name = row["name"] as? String,
            let createdBy = row["created_by"] as? String,
            let createdAtString = row["created_at"] as? String
        else {
            return nil
        }
        
        let createdAt = PerformanceConstants.iso8601Fractional.date(from: createdAtString) ?? Date()
        
        // Parse members JSON
        var members: [GroupMember]?
        if let membersString = row["members_json"] as? String,
           let data = membersString.data(using: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            members = try? decoder.decode([GroupMember].self, from: data)
        }
        
        // Parse sync status
        let syncStatus: ChatGroup.SyncStatus?
        if let statusString = row["sync_status"] as? String {
            syncStatus = ChatGroup.SyncStatus(rawValue: statusString)
        } else {
            syncStatus = nil
        }
        
        return ChatGroup(
            id: id,
            name: name,
            avatarUrl: row["avatar_url"] as? String,
            description: row["description"] as? String,
            createdBy: createdBy,
            creatorUsername: row["creator_username"] as? String,
            createdAt: createdAt,
            memberCount: (row["member_count"] as? Int64).map { Int($0) } ?? 0,
            members: members,
            syncStatus: syncStatus
        )
    }
    
    // MARK: - Membership Check (Bug 1 fix)
    
    /// Check if a user is a member of a group by inspecting members_json
    func isMember(userId: String, groupId: String) async -> Bool {
        // Fast path: check if group exists at all
        let sql = "SELECT members_json FROM groups WHERE id = ?"
        guard let rows = try? await db.query(sql, params: [groupId]),
              let row = rows.first else {
            return false
        }
        
        // Parse members JSON and check for userId
        if let membersString = row["members_json"] as? String,
           let data = membersString.data(using: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let members = try? decoder.decode([GroupMember].self, from: data) {
                return members.contains { $0.userId == userId }
            }
        }
        
        // Fallback: if no members_json, the group exists so assume membership
        // (conservative — better to deliver than drop)
        return true
    }
}
