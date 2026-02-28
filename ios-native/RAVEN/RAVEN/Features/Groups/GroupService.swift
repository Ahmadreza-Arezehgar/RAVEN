import Foundation

// MARK: - Group Service

/// Service layer for group chat API operations
@Observable
final class GroupService {
    static let shared = GroupService()
    
    private let network = NetworkService.shared
    private let groupRepo = GroupRepository(db: .shared)
    private let conversationRepo = ConversationRepository.shared
    
    private init() {}
    
    // MARK: - Create Group
    
    /// Create a new group on the server and locally
    /// - Parameters:
    ///   - name: ChatGroup name (2-40 characters)
    ///   - memberIds: User IDs to add (excluding creator)
    ///   - avatarUrl: Optional group avatar URL
    ///   - description: Optional group description
    /// - Returns: The created Group
    func createGroup(
        name: String,
        memberIds: [String],
        avatarUrl: String? = nil,
        description: String? = nil
    ) async throws -> ChatGroup {
        // Validate
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw GroupError.emptyName
        }
        guard memberIds.count >= 2 else {
            throw GroupError.insufficientMembers
        }
        
        // Create on server
        let request = CreateGroupRequest(
            name: name.trimmingCharacters(in: .whitespaces),
            memberIds: memberIds,
            avatarUrl: avatarUrl,
            description: description
        )
        
        var group: ChatGroup = try await network.post(
            path: "/api/groups",
            body: request
        )
        
        // Fetch full group details to get members array
        do {
            let fullGroup: ChatGroup = try await network.get(path: "/api/groups/\(group.id)")
            group = fullGroup
            #if DEBUG
            print("👥 [GroupService] Fetched \(group.members?.count ?? 0) members for new group")
            #endif
        } catch {
            #if DEBUG
            print("⚠️ [GroupService] Could not fetch group details: \(error)")
            #endif
        }
        
        // Persist locally
        try await groupRepo.upsert(group)
        
        // Create conversation entry for the group
        try await conversationRepo.createGroupConversation(group: group)
        
        #if DEBUG
        print("✅ [GroupService] Created group: \(group.name) (\(group.id.prefix(8)))")
        #endif
        
        return group
    }
    
    // MARK: - Fetch Groups
    
    /// Fetch all groups the current user is a member of
    func fetchMyGroups() async throws -> [ChatGroup] {
        let groups: [ChatGroup] = try await network.get(path: "/api/groups/mine")
        
        // Update local cache
        for group in groups {
            try await groupRepo.upsert(group)
            
            // Bug 2 fix: Promote limbo messages for groups that were unknown when
            // received via mesh (offline group invite scenario)
            let pendingMessages = await PendingGroupMessageRepository.shared.promoteMessages(forGroup: group.id)
            for envelope in pendingMessages {
                #if DEBUG
                print("📦 [GroupService] Promoting limbo message \(envelope.clientMessageId.prefix(8)) for group \(group.name)")
                #endif
                await AppDelegate.handleMeshMessage(envelope)
            }
        }
        
        #if DEBUG
        print("👥 [GroupService] Fetched \(groups.count) groups")
        #endif
        return groups
    }
    
    /// Get groups from local cache
    func getLocalGroups() async throws -> [ChatGroup] {
        return try await groupRepo.getAll()
    }
    
    // MARK: - Group Details
    
    /// Fetch full group details including members
    func fetchGroupDetails(groupId: String) async throws -> ChatGroup {
        let group: ChatGroup = try await network.get(path: "/api/groups/\(groupId)")
        try await groupRepo.upsert(group)
        return group
    }
    
    // MARK: - Member Management
    
    /// Add members to a group (admin only)
    func addMembers(groupId: String, memberIds: [String]) async throws -> ChatGroup {
        let request = AddMembersRequest(memberIds: memberIds)
        
        let group: ChatGroup = try await network.post(
            path: "/api/groups/\(groupId)/members",
            body: request
        )
        
        try await groupRepo.upsert(group)
        #if DEBUG
        print("👥 [GroupService] Added \(memberIds.count) members to \(group.name)")
        #endif
        
        return group
    }
    
    /// Leave a group
    func leaveGroup(groupId: String) async throws {
        do {
            let _: Empty = try await network.post(
                path: "/api/groups/\(groupId)/leave",
                body: Empty()
            )
        } catch APIError.notFound {
            // User already removed (e.g. kicked by admin) — treat as success
            #if DEBUG
            print("⚠️ [GroupService] Already not a member of \(groupId.prefix(8)), treating as success")
            #endif
        }
        
        // Remove from local cache
        try await groupRepo.delete(groupId: groupId)
        
        // Remove conversation from inbox so group disappears from chat list
        try await conversationRepo.delete(roomId: groupId)
        
        #if DEBUG
        print("👋 [GroupService] Left group: \(groupId.prefix(8))")
        #endif
    }
    
    // MARK: - Admin Actions
    
    /// Kick a member from the group (admin only)
    func kickMember(groupId: String, userId: String) async throws -> ChatGroup {
        let _: Empty = try await network.post(
            path: "/api/groups/\(groupId)/members/\(userId)/kick",
            body: Empty()
        )
        #if DEBUG
        print("🦶 [GroupService] Kicked \(userId.prefix(8)) from \(groupId.prefix(8))")
        #endif
        
        // Refetch group to get updated member list
        let updated: ChatGroup = try await network.get(path: "/api/groups/\(groupId)")
        try await groupRepo.upsert(updated)
        return updated
    }
    
    /// Promote a member to admin (admin only)
    func promoteMember(groupId: String, userId: String) async throws {
        let _: Empty = try await network.post(
            path: "/api/groups/\(groupId)/members/\(userId)/promote",
            body: Empty()
        )
        #if DEBUG
        print("⬆️ [GroupService] Promoted \(userId.prefix(8)) to admin")
        #endif
    }
    
    /// Demote an admin to member (admin only)
    func demoteMember(groupId: String, userId: String) async throws {
        let _: Empty = try await network.post(
            path: "/api/groups/\(groupId)/members/\(userId)/demote",
            body: Empty()
        )
        #if DEBUG
        print("⬇️ [GroupService] Demoted \(userId.prefix(8)) to member")
        #endif
    }
    
    /// Update group settings (admin only)
    @discardableResult
    func updateGroup(groupId: String, request: UpdateGroupRequest) async throws -> ChatGroup {
        let group: ChatGroup = try await network.patch(
            path: "/api/groups/\(groupId)",
            body: request
        )
        // Persist locally
        try await groupRepo.upsert(group)
        try await conversationRepo.updateGroupInfo(
            roomId: groupId,
            name: request.name,
            avatarUrl: request.avatarUrl
        )
        #if DEBUG
        print("✏️ [GroupService] Updated group \(groupId.prefix(8))")
        #endif
        return group
    }
    
    // MARK: - Invite Links
    
    /// Get or create invite link (admin only)
    func getOrCreateInviteLink(groupId: String) async throws -> InviteLinkResponse {
        let link: InviteLinkResponse = try await network.post(
            path: "/api/groups/\(groupId)/invite-link",
            body: Empty()
        )
        #if DEBUG
        print("🔗 [GroupService] Invite link: \(link.inviteCode)")
        #endif
        return link
    }
    
    /// Reset invite link (admin only)
    func resetInviteLink(groupId: String) async throws -> InviteLinkResponse {
        let link: InviteLinkResponse = try await network.post(
            path: "/api/groups/\(groupId)/invite-link/reset",
            body: Empty()
        )
        #if DEBUG
        print("🔄 [GroupService] Reset invite link: \(link.inviteCode)")
        #endif
        return link
    }
    
    // MARK: - Mute Settings (local per-user)
    
    func getMuteSettings(groupId: String) async -> MuteSettings {
        do {
            let db = DatabaseService.shared
            
            // Ensure table exists (may be called before any setMuteSettings)
            try await db.execute("""
                CREATE TABLE IF NOT EXISTS group_mute_settings (
                    group_id TEXT PRIMARY KEY,
                    mute_until TEXT,
                    mentions_only INTEGER DEFAULT 0,
                    updated_at TEXT DEFAULT (datetime('now'))
                )
            """, params: [])
            
            let sql = "SELECT mute_until, mentions_only FROM group_mute_settings WHERE group_id = ?"
            let rows = try await db.query(sql, params: [groupId])
            
            if let row = rows.first {
                let muteUntil: Date?
                if let ts = row["mute_until"] as? String {
                    muteUntil = PerformanceConstants.iso8601.date(from: ts)
                } else {
                    muteUntil = nil
                }
                let mentionsOnly = (row["mentions_only"] as? Int ?? 0) == 1
                return MuteSettings(muteUntil: muteUntil, mentionsOnly: mentionsOnly)
            }
        } catch {
            #if DEBUG
            print("❌ [GroupService] Failed to load mute settings: \(error)")
            #endif
        }
        return .unmuted
    }
    
    func setMuteSettings(groupId: String, settings: MuteSettings) async {
        do {
            let db = DatabaseService.shared
            
            // Ensure table exists
            try await db.execute("""
                CREATE TABLE IF NOT EXISTS group_mute_settings (
                    group_id TEXT PRIMARY KEY,
                    mute_until TEXT,
                    mentions_only INTEGER DEFAULT 0,
                    updated_at TEXT DEFAULT (datetime('now'))
                )
            """, params: [])
            
            let muteStr: String?
            if let until = settings.muteUntil {
                muteStr = PerformanceConstants.iso8601.string(from: until)
            } else {
                muteStr = nil
            }
            
            let sql = """
                INSERT INTO group_mute_settings (group_id, mute_until, mentions_only, updated_at)
                VALUES (?, ?, ?, datetime('now'))
                ON CONFLICT(group_id) DO UPDATE SET
                    mute_until = excluded.mute_until,
                    mentions_only = excluded.mentions_only,
                    updated_at = excluded.updated_at
            """
            try await db.execute(sql, params: [groupId, muteStr as Any, settings.mentionsOnly ? 1 : 0])
            #if DEBUG
            print("🔇 [GroupService] Updated mute settings for \(groupId.prefix(8))")
            #endif
        } catch {
            #if DEBUG
            print("❌ [GroupService] Failed to save mute settings: \(error)")
            #endif
        }
    }
    
    // MARK: - Friends (for member picker)
    
    /// Get cached friends list
    func getCachedFriends() -> [GroupFriendInfo]? {
        guard let data = UserDefaults.standard.data(forKey: "raven_friends_cache") else { return nil }
        return try? JSONDecoder().decode([GroupFriendInfo].self, from: data)
    }

    /// Fetch friends list for group member selection
    func fetchFriends() async throws -> [GroupFriendInfo] {
        if !NetworkMonitor.shared.isOnline {
            if let cached = getCachedFriends(), !cached.isEmpty {
                #if DEBUG
                print("👫 [GroupService] Loaded \(cached.count) friends from offline cache")
                #endif
                return cached
            }
            throw URLError(.notConnectedToInternet)
        }
        
        do {
            let friends: [GroupFriendInfo] = try await network.get(path: "/api/users/friends")
            if let data = try? JSONEncoder().encode(friends) {
                UserDefaults.standard.set(data, forKey: "raven_friends_cache")
            }
            #if DEBUG
            print("👫 [GroupService] Fetched \(friends.count) friends for member picker")
            #endif
            return friends
        } catch {
            if let cached = getCachedFriends(), !cached.isEmpty {
                #if DEBUG
                print("👫 [GroupService] API failed, loaded \(cached.count) friends from offline cache")
                #endif
                return cached
            }
            throw error
        }
    }
}

// MARK: - Errors

enum GroupError: LocalizedError {
    case emptyName
    case insufficientMembers
    case notAdmin
    case groupNotFound
    
    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Group name cannot be empty"
        case .insufficientMembers:
            return "Select at least 2 members"
        case .notAdmin:
            return "Only admins can perform this action"
        case .groupNotFound:
            return "Group not found"
        }
    }
}
