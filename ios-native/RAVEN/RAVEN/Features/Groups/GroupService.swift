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

        let request = CreateGroupRequest(
            name: name.trimmingCharacters(in: .whitespaces),
            memberIds: memberIds,
            avatarUrl: avatarUrl,
            description: description
        )

        // ⚡ AUDIT FIX (#6): Offline-first group creation.
        //
        // Previously the path here was `try await network.post(...)` which
        // throws immediately when offline → no local group, no conversation,
        // user can't even see the group exists. Now we attempt the server
        // call first, and on a CONNECTION error fall back to a locally-created
        // group with `syncStatus: .pending`. The conversation is created so
        // the user can open the chat and queue messages immediately. The
        // group is reconciled with the server on the next successful
        // `fetchMyGroups()` call.
        var group: ChatGroup
        do {
            group = try await network.post(
                path: "/api/groups",
                body: request
            )
        } catch let error as APIError {
            switch error {
            case .networkError:
                // Offline / cloud unreachable → synthesize a local group.
                group = await Self.makeLocalPendingGroup(request: request, memberIds: memberIds)
                #if DEBUG
                print("📵 [GroupService] Server unreachable — created local pending group \(group.id.prefix(8))")
                #endif
            default:
                throw error
            }
        } catch {
            // Treat any unrecognized error as transient → fall back to local
            group = await Self.makeLocalPendingGroup(request: request, memberIds: memberIds)
            #if DEBUG
            print("📵 [GroupService] Group create failed (\(error)) — created local pending group \(group.id.prefix(8))")
            #endif
        }
        
        // Fetch full group details to get members array (one quick retry, then
        // synthesize a fallback rather than persisting an empty member list).
        // ⚡ BUG FIX 3: Previously this swallowed errors and persisted with
        // members=nil, which made later add/kick ops silently fail.
        var refetchSucceeded = false
        for attempt in 0..<2 {
            do {
                let fullGroup: ChatGroup = try await network.get(path: "/api/groups/\(group.id)")
                group = fullGroup
                refetchSucceeded = true
                #if DEBUG
                print("👥 [GroupService] Fetched \(group.members?.count ?? 0) members for new group (attempt \(attempt + 1))")
                #endif
                break
            } catch {
                #if DEBUG
                print("⚠️ [GroupService] Refetch attempt \(attempt + 1)/2 failed: \(error)")
                #endif
            }
        }

        if !refetchSucceeded && (group.members?.isEmpty ?? true) {
            // Synthesize a minimal member list from the create request so that
            // member operations and conversation rendering work until the next
            // successful refetch (fetchMyGroups / fetchGroup) repairs it.
            let now = Date()
            let creatorId = await KeychainService.shared.getUserId() ?? ""
            // AuthService is now @MainActor-isolated (2026-05-10 fix);
            // hop to main once and snapshot the user so the synthesized
            // member list doesn't double-await each access.
            let creator = await MainActor.run { AuthService.shared.currentUser }
            let creatorUsername = creator?.username ?? ""
            var fallback: [GroupMember] = []
            if !creatorId.isEmpty {
                fallback.append(GroupMember(
                    userId: creatorId,
                    username: creatorUsername,
                    avatarUrl: creator?.avatarPath,
                    role: "admin",
                    joinedAt: now
                ))
            }
            for memberId in memberIds {
                fallback.append(GroupMember(
                    userId: memberId,
                    username: "",
                    avatarUrl: nil,
                    role: "member",
                    joinedAt: now
                ))
            }
            group.members = fallback
            group.syncStatus = .pending
            #if DEBUG
            print("⚠️ [GroupService] Refetch failed — using synthesized members (\(fallback.count)); marked syncStatus=pending for later repair")
            #endif
        }

        // Persist locally
        try await groupRepo.upsert(group)

        // Create conversation entry for the group
        try await conversationRepo.createGroupConversation(group: group)

        #if DEBUG
        let syncTag = (group.syncStatus == .pending) ? " [PENDING — will retry on reconnect]" : ""
        print("✅ [GroupService] Created group: \(group.name) (\(group.id.prefix(8)))\(syncTag)")
        #endif

        return group
    }

    /// Synthesize an offline-first ChatGroup so the user can keep working
    /// when the server can't be reached. The locally-created group has a
    /// fresh client-side UUID, the creator + invited members in `members`,
    /// and `syncStatus = .pending` to mark it for later server reconciliation
    /// (`syncPendingGroups()`).
    private static func makeLocalPendingGroup(
        request: CreateGroupRequest,
        memberIds: [String]
    ) async -> ChatGroup {
        let now = Date()
        let creatorId = await KeychainService.shared.getUserId() ?? ""
        let creatorUsername = await MainActor.run { AuthService.shared.currentUser?.username ?? "" }
        let creatorAvatar = await MainActor.run { AuthService.shared.currentUser?.avatarPath }

        var members: [GroupMember] = []
        if !creatorId.isEmpty {
            members.append(GroupMember(
                userId: creatorId,
                username: creatorUsername,
                avatarUrl: creatorAvatar,
                role: "admin",
                joinedAt: now
            ))
        }
        for memberId in memberIds {
            members.append(GroupMember(
                userId: memberId,
                username: "",
                avatarUrl: nil,
                role: "member",
                joinedAt: now
            ))
        }

        return ChatGroup(
            id: "local_" + UUID().uuidString,
            name: request.name,
            avatarUrl: request.avatarUrl,
            description: request.description,
            createdBy: creatorId,
            creatorUsername: creatorUsername,
            createdAt: now,
            memberCount: members.count,
            members: members,
            visibility: "private",
            linkJoinEnabled: false,
            syncStatus: .pending
        )
    }

    /// Retry server creation for any locally-created groups marked .pending.
    /// Call this on reconnect (NetworkMonitor → online) and after sign-in.
    /// Successful retries replace the local UUID with the server's group ID
    /// in messages, conversation, and group rows.
    func syncPendingGroups() async {
        let pending: [ChatGroup]
        do {
            pending = try await groupRepo.allPending()
        } catch {
            #if DEBUG
            print("❌ [GroupService] syncPendingGroups: failed to load pending — \(error)")
            #endif
            return
        }
        guard !pending.isEmpty else { return }

        for local in pending {
            let memberIds = (local.members ?? [])
                .filter { $0.userId != local.createdBy }
                .map { $0.userId }
            // ⚡ Send the local ID as `client_id` so the server adopts it.
            // Result: serverGroup.id == local.id and we never need to remap
            // message / conversation rows.
            let request = CreateGroupRequest(
                name: local.name,
                memberIds: memberIds,
                avatarUrl: local.avatarUrl,
                description: local.description,
                clientId: local.id
            )

            do {
                var serverGroup: ChatGroup = try await network.post(path: "/api/groups", body: request)
                serverGroup.syncStatus = .synced
                // Refetch full membership
                if let full: ChatGroup = try? await network.get(path: "/api/groups/\(serverGroup.id)") {
                    serverGroup = full
                    serverGroup.syncStatus = .synced
                }

                if serverGroup.id == local.id {
                    // ✅ Server adopted our ID — just upsert in place. No remap.
                    try? await groupRepo.upsert(serverGroup)
                    #if DEBUG
                    print("✅ [GroupService] Synced pending group \(local.id.prefix(8)) — server adopted client_id")
                    #endif
                } else {
                    // Server insisted on its own ID (legacy fallback) — remap.
                    try? await groupRepo.remapId(from: local.id, to: serverGroup.id, applying: serverGroup)
                    try? await conversationRepo.remapRoomId(from: local.id, to: serverGroup.id)
                    try? await MessageRepository.shared.remapRoomId(from: local.id, to: serverGroup.id)
                    #if DEBUG
                    print("🔁 [GroupService] Synced pending group \(local.id.prefix(8)) → \(serverGroup.id.prefix(8)) (server-assigned)")
                    #endif
                }
            } catch {
                // Stay pending — try again next reconnect.
                #if DEBUG
                print("📵 [GroupService] Pending group sync deferred: \(error)")
                #endif
            }
        }
    }

    // MARK: - Fetch Groups

    /// Fetch all groups the current user is a member of
    func fetchMyGroups() async throws -> [ChatGroup] {
        // 🔁 First, retry any locally-created pending groups so server IDs land
        // before we read /api/groups/mine. This avoids transient duplicates.
        await syncPendingGroups()

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

        // 🔐 Forward-secrecy: drop our cached group key. We're no longer a
        // member; we should not be holding the key around. (Server has also
        // rotated, so other members will encrypt with the new version.)
        await GroupKeyService.shared.reset(for: groupId)

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
        struct KickResponse: Decodable {
            let success: Bool?
            let message: String?
            let newKeyVersion: Int?
            enum CodingKeys: String, CodingKey {
                case success, message
                case newKeyVersion = "new_key_version"
            }
        }
        let resp: KickResponse = try await network.post(
            path: "/api/groups/\(groupId)/members/\(userId)/kick",
            body: Empty()
        )
        #if DEBUG
        print("🦶 [GroupService] Kicked \(userId.prefix(8)) from \(groupId.prefix(8)) → key v\(resp.newKeyVersion ?? -1)")
        #endif

        // 🔐 FORWARD SECRECY:
        // Server has rotated the per-group AES key. Evict our cached key for
        // this group so the very next mesh-broadcast encryption fetches the
        // fresh version. Without this, the kicked member (who still holds
        // v(N-1)) could decrypt every future message because every remaining
        // member kept encrypting with the SAME v(N-1) they had cached.
        await GroupKeyService.shared.reset(for: groupId)

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
