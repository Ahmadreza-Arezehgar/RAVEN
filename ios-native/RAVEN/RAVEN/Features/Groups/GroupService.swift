import Foundation

// MARK: - Group Service

/// Service layer for group chat API operations
@Observable
final class GroupService {
    static let shared = GroupService()

    private let network = NetworkService.shared
    private let groupRepo = GroupRepository(db: .shared)
    private let conversationRepo = ConversationRepository.shared

    private init() {
        // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — wire offline-
        // group reconcile to network reconnect.
        //
        // PROBLEM (user report 2026-05-24):
        //   "vaghty yek group dorst mishe faght mishe az tarigh mesh
        //    baham sohbat kard va vaghty swithch mishe be internet
        //    nemishe dige sohbat kard"
        //   ≈ when a group is created (offline), you can only chat
        //   via mesh; once internet returns, you can no longer chat.
        //
        // ROOT CAUSE:
        //   `createGroup` falls back to a local synthesized group
        //   with id="local_<UUID>" and syncStatus=.pending when the
        //   server is unreachable. `syncPendingGroups()` is the
        //   reconcile path that POSTs the queued create back to the
        //   server (with `client_id` so the server adopts our id),
        //   BUT pre-fix the only callers were:
        //     - fetchMyGroups() — runs lazily on screen-open,
        //     - RealtimeEngine.handleAddedToGroup,
        //     - NotificationsService.
        //   None of those fire on bare network reconnect. So if the
        //   user toggled airplane mode off and immediately tried to
        //   send into the group, the very next `POST
        //   /api/groups/local_xxxx/messages` (and the
        //   `GET /api/groups/local_xxxx/key` that precedes it) hit
        //   404, GroupKeyService.encrypt fail-closed (E2EE no-
        //   plaintext rule), and the send stayed in failed.
        //
        // FIX: subscribe to NetworkMonitor.networkStatusChanged here
        // so the moment the path flips to satisfied, we drain the
        // pending-group queue. Same pattern OutboxManager uses for
        // pending messages.
        //
        // 🛡️ SECURITY: this fix doesn't change the security model.
        // The server still enforces creator-only adoption of a
        // client_id, the group remains E2EE under the per-group AES-
        // GCM key, and the bridge path still requires a real server
        // group_id (no opportunistic create). The fix only makes the
        // reconcile fire ON RECONNECT instead of waiting for a
        // screen-driven trigger.
        setupNetworkObserver()
    }

    // MARK: - Network Observer

    private func setupNetworkObserver() {
        NotificationCenter.default.addObserver(
            forName: .networkStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Only react to ONLINE transitions — the offline edge is
            // irrelevant for sync. Reading on the main queue here is
            // safe (the notification is posted on main).
            guard NetworkMonitor.shared.isOnline else { return }
            #if DEBUG
            print("🌐 [GroupService] Network back online — draining pending-group queue")
            #endif
            Task { @MainActor in
                await self.syncPendingGroups()
            }
        }
    }
    
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

            // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — same as
            // makeLocalPendingGroup: resolve member usernames from
            // cached friends so the bubble's sender label has a
            // real name to fall back to until the next refetch.
            let friendDirectory: [String: GroupFriendInfo] = {
                guard let cached = getCachedFriends() else { return [:] }
                var dict: [String: GroupFriendInfo] = [:]
                for f in cached { dict[f.id] = f }
                return dict
            }()

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
                let f = friendDirectory[memberId]
                fallback.append(GroupMember(
                    userId: memberId,
                    username: f?.username ?? "",
                    avatarUrl: f?.avatarUrl,
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

        // 🟦 ROUND 46 (2026-05-17) — broadcast a `group_create` envelope
        // over mesh so neighbouring devices (especially mesh-only ones)
        // can materialize the new group locally without ever hitting
        // the server. Otherwise the very common "A creates group with
        // BLE-only C" scenario silently drops on C (messages land in
        // `PendingGroupMessageRepository` limbo forever because C never
        // learns the group_id exists).
        await MeshGroupBroadcaster.broadcastCreate(group)

        // 🟢 ROUND 74 (2026-05-24) — also fetch + broadcast the
        // group's AES-GCM key so BLE-only members can decrypt
        // subsequent messages. Without this, the group_create reaches
        // C but C still can't read anything. The fetch lazily mints
        // v1 server-side on first hit and the broadcast travels with
        // the same mesh spray as group_create.
        await MainActor.run {
            Task { await GroupKeyService.shared.prefetchAndBroadcast(groupId: group.id) }
        }

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

        // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — resolve member
        // usernames from the cached friends directory.
        //
        // Pre-fix every offline-created member entry had
        // username="" and avatarUrl=nil. The user-reported symptom
        // ("esm afrad zaher nemishe faghat neveshte mishe (user)")
        // came partly from this: until the server refetch landed,
        // the group's member list (used by ChatView's sender-name
        // fallback path) only had hex userIds and no usernames.
        //
        // The user already selected these friends from the member
        // picker, so they were just iterated through `GroupService.
        // fetchFriends()` (or its cache). Use the same cache to
        // resolve username + avatarUrl for the offline synthesis —
        // no extra network round-trip.
        let friendDirectory: [String: GroupFriendInfo] = {
            guard let cached = GroupService.shared.getCachedFriends() else { return [:] }
            var dict: [String: GroupFriendInfo] = [:]
            for f in cached { dict[f.id] = f }
            return dict
        }()

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
            let f = friendDirectory[memberId]
            members.append(GroupMember(
                userId: memberId,
                username: f?.username ?? "",
                avatarUrl: f?.avatarUrl,
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
                // 🟦 ROUND 46: re-broadcast under the (potentially new)
                // server-assigned ID so mesh-only neighbours converge
                // on the canonical group_id instead of the local "
                // local_xxxx" UUID we synthesized while offline.
                await MeshGroupBroadcaster.broadcastCreate(serverGroup)
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

        // 🟦 ROUND 46 (2026-05-17) — for groups we DIDN'T already know
        // about locally (i.e. we just learned about them via server
        // push / first inbox sync), rebroadcast a `group_create`
        // mesh envelope. This is the bridge path that gets the group
        // metadata across to mesh-only peers when the original creator
        // is too far away on BLE — the online device (this one) acts
        // as a relay for the lifecycle event itself, not just for
        // chat messages. We snapshot the "known IDs" BEFORE upserts.
        let existingLocal = (try? await groupRepo.getAll()) ?? []
        let knownIdsBefore: Set<String> = Set(existingLocal.map { $0.id })

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

            // Round 46: if this is a NEW group, broadcast group_create
            // for any mesh-only neighbour that hasn't synced it yet.
            // (Skip groups we already had locally — they were either
            // broadcast at create time or are already known cluster-
            // wide.)
            if !knownIdsBefore.contains(group.id), group.members?.isEmpty == false {
                #if DEBUG
                print("🟦 [GroupService] Newly-fetched group \(group.id.prefix(8)) — broadcasting group_create for mesh-only neighbours")
                #endif
                await MeshGroupBroadcaster.broadcastCreate(group)
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

        // 🟦 ROUND 46 (2026-05-17) — re-broadcast the (now-updated)
        // group metadata so the newly-added members can materialize
        // the group locally even if they're mesh-only. Existing
        // members re-upsert harmlessly (SQL UPSERT). We piggyback on
        // the "create" event for now; a finer-grained "member_add"
        // event is reserved for a future round.
        await MeshGroupBroadcaster.broadcastCreate(group)

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
        let decoded = try? JSONDecoder().decode([GroupFriendInfo].self, from: data)
        // 🔴 ROUND 71 phase 3 — populate MeshIdentityResolver so the
        // mesh-strict-strip receive path can resolve hashed peer
        // tokens back to userIds even on cold launch / offline boot.
        // Pre-fix: `registerAll` had ZERO callers anywhere — the
        // resolver's map stayed empty and every strict-strip
        // envelope failed identity resolution.
        if let friends = decoded {
            Task.detached(priority: .utility) {
                await MeshIdentityResolver.shared.registerAll(friends.map { $0.id })
            }
        }
        return decoded
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
            // 🔴 ROUND 71 phase 3 — see getCachedFriends() for context.
            // Wire the bulk-register call after every successful
            // network fetch so newly-accepted friends become
            // resolvable without waiting for a process restart.
            await MeshIdentityResolver.shared.registerAll(friends.map { $0.id })
            #if DEBUG
            print("👫 [GroupService] Fetched \(friends.count) friends for member picker "
                  + "(+registered \(friends.count) in MeshIdentityResolver)")
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

// MARK: - Mesh Group Broadcaster (Round 46)
//
// 🟦 ROUND 46 (2026-05-17) — group lifecycle propagation over mesh.
//
// User-reported bug: a group created on device A (online + BLE) was
// visible on B (online + BLE — via WS push) but NOT on C (BLE only).
// C received the GROUP MESSAGES via mesh but had no `groups` row for
// the group_id, so:
//   • the messages landed in `PendingGroupMessageRepository` limbo
//     instead of the chat surface;
//   • when C did eventually open the chat by tapping the sender's
//     name, the message rendered as a 1:1 direct chat instead of as
//     part of the group conversation;
//   • the user reported "the group never appears on C".
//
// Fix: on every group create (and every member-add path), broadcast a
// `MeshEnvelope` carrying a `GroupSyncPayload` so mesh-only peers can
// materialize the group locally via `GroupRepository`. The mesh DTN
// spray (Binary Spray & Wait + bloom dedup) handles multi-hop
// propagation, so a fully-disconnected C reachable only via B will
// still receive the create event.
//
// Receiver-side handler is in `RAVENApp.handleMeshMessage`; this
// helper just covers the build + broadcast.
enum MeshGroupBroadcaster {
    /// Build + broadcast a `group_create` mesh envelope so neighbouring
    /// devices (especially mesh-only ones) materialize the new group
    /// locally without ever hitting the server.
    ///
    /// Idempotent at the receiver: if the group already exists locally,
    /// the receiver's `GroupRepository.upsert` is a SQL upsert (INSERT
    /// OR CONFLICT). So broadcasting on every create / re-create is
    /// safe.
    ///
    /// SECURITY: the envelope is signed via the normal mesh sign path
    /// (`enqueueForBroadcast` calls `MeshCryptoService.signEnvelope`),
    /// so peers can verify authorship. The payload is NOT encrypted —
    /// it carries no message content, only group metadata which is
    /// also visible to the server. Trade-off accepted: simplicity +
    /// every recipient can materialize without a per-pair key
    /// exchange.
    static func broadcastCreate(_ group: ChatGroup) async {
        // Build the payload from the freshly-created group.
        let members = (group.members ?? []).prefix(GroupSyncPayload.maxMembers).map {
            GroupSyncPayload.Member(
                userId: $0.userId,
                username: $0.username,
                avatarUrl: $0.avatarUrl,
                role: $0.role,
                joinedAt: $0.joinedAt.timeIntervalSince1970
            )
        }
        let payload = GroupSyncPayload(
            version: GroupSyncPayload.currentVersion,
            event: "create",
            groupId: group.id,
            groupName: group.name,
            avatarUrl: group.avatarUrl,
            description: group.description,
            createdBy: group.createdBy,
            creatorUsername: group.creatorUsername,
            createdAt: group.createdAt.timeIntervalSince1970,
            memberCount: group.memberCount,
            members: Array(members)
        )
        guard let payloadJSON = payload.encode() else {
            #if DEBUG
            print("🟦 [GroupBroadcaster] ABORT — could not encode GroupSyncPayload for group \(group.id.prefix(8))")
            #endif
            return
        }

        // Snapshot identity we need for the envelope.
        let myId = await KeychainService.shared.getUserId() ?? ""
        let myName = await MainActor.run { AuthService.shared.currentUser?.username ?? "" }
        let deviceId = DeviceIdentityService.shared.fingerprint ?? ""

        // The envelope's recipientId is the group_id — recipients
        // self-validate by checking whether their userId is in the
        // payload's members list. We mark `isGroup = true` so the
        // existing group-aware relay logic in BLEMeshEngine
        // (membership-based "is this for me" check) treats the
        // envelope as a group event during spray decisions.
        var envelope = MeshEnvelope(
            clientMessageId: "groupSync-\(group.id)-\(UUID().uuidString.prefix(8))",
            roomId: group.id,
            senderId: myId,
            senderName: myName,
            recipientId: group.id,
            type: 6,                           // MessageType.system index
            text: payloadJSON,
            timestamp: Date().timeIntervalSince1970,
            sprayCounter: PremiumLimits.meshSprayBudget,
            hopCount: 0,
            hopLimit: PremiumLimits.meshHopLimit,
            routePath: [deviceId],
            originDeviceId: deviceId,
            needsForwarding: true
        )
        envelope.ttlSeconds = PremiumLimits.meshTTLSeconds
        envelope.isGroup = true
        envelope.payloadKind = "group_create"

        #if DEBUG
        print("🟦 [GroupBroadcaster] BROADCAST group_create gid=\(group.id.prefix(8)) name=\(group.name) members=\(members.count) payloadJSON.bytes=\(payloadJSON.utf8.count) mid=\(envelope.clientMessageId.prefix(12))")
        #endif

        await BLEMeshEngine.shared.enqueueForBroadcast(envelope)
    }

    /// 🟢 ROUND 74 (2026-05-24) — broadcast a group's AES-GCM key over
    /// mesh so BLE-only members can decrypt subsequent group ciphertext.
    ///
    /// 🔐 ROUND 75 (2026-05-24) — TWO-PRONGED DELIVERY:
    ///   1. For each non-self group member we have an ATSAM root for,
    ///      broadcast a `payloadKind="group_key_atsam"` envelope with
    ///      `recipientId = member` and the key payload sealed via
    ///      `ATSAMMessageSealer.seal`. Only that member can decrypt.
    ///      Non-member BLE relays in range see opaque ChaCha20-Poly1305
    ///      ciphertext.
    ///   2. For members we DON'T have an ATSAM root for (i.e. never
    ///      did a 1:1 with us — the BLE-only-stranger scenario), fall
    ///      back to one legacy `payloadKind="group_key"` plaintext
    ///      broadcast so they can still get the key. Document the
    ///      trade-off; in practice this fallback only fires for first-
    ///      time-stranger groups and disappears as members establish
    ///      ATSAM roots through normal 1:1 chats.
    ///
    /// 🛡️ SECURITY guarantees:
    ///   - When every member has an ATSAM root with the broadcaster,
    ///     NO plaintext key material leaves the device. Non-members
    ///     in BLE range see only opaque ATSAM ciphertext + envelope
    ///     metadata (group_id, recipient userId hash, no key bytes).
    ///   - The legacy plaintext envelope is only emitted when at
    ///     least one member lacks ATSAM pairing. This is logged so
    ///     ops can see the leak window.
    ///   - Receiver gates: `recipientId == myId` (per-recipient envelope
    ///     is dropped by other members), `broadcastedBy == resolved
    ///     signer` (anti-replay-with-poisoned-broadcastedBy), broadcaster
    ///     and receiver both in local GroupMember list (anti-spoof
    ///     by kicked / never-member peer), 24h freshness window.
    static func broadcastKey(groupId: String, version: Int, keyB64: String) async {
        // Snapshot identity.
        let myId = await KeychainService.shared.getUserId() ?? ""
        let myName = await MainActor.run { AuthService.shared.currentUser?.username ?? "" }
        let deviceId = DeviceIdentityService.shared.fingerprint ?? ""

        guard !myId.isEmpty else {
            #if DEBUG
            print("🟦 [GroupBroadcaster] ABORT broadcastKey — myId empty (not signed in)")
            #endif
            return
        }

        // Resolve members from local group state.
        let groupRepo = GroupRepository()
        let localGroup = try? await groupRepo.get(groupId: groupId)
        let allMembers = (localGroup?.members ?? []).map { $0.userId }.filter { $0 != myId && !$0.isEmpty }

        // Build the shared payload (same for every recipient — what
        // varies is the per-recipient AEAD wrap).
        let payload = GroupKeyMeshPayload(
            version: GroupKeyMeshPayload.currentVersion,
            event: "key",
            groupId: groupId,
            keyVersion: version,
            keyB64: keyB64,
            broadcastedBy: myId,
            issuedAt: Date().timeIntervalSince1970
        )
        guard let payloadJSON = payload.encode() else {
            #if DEBUG
            print("🟦 [GroupBroadcaster] ABORT — could not encode GroupKeyMeshPayload for gid=\(groupId.prefix(8))")
            #endif
            return
        }

        var unrootedMembers: [String] = []
        var atsamEnvelopesEmitted: Int = 0

        // 🔐 ROUND 75 Phase 1 — per-recipient ATSAM wrap.
        for memberId in allMembers {
            // Try to seal under the existing ATSAM root for this peer.
            // ATSAMMessageSealer.seal already looks up
            // ATSAMRootStorage.shared.root(for: recipientUserId) and
            // returns nil if missing.
            let msgId = "groupKey-\(groupId)-v\(version)-for-\(memberId.prefix(8))-\(UUID().uuidString.prefix(8))"
            if let sealed = await ATSAMMessageSealer.seal(
                plaintext: payloadJSON,
                senderUserId: myId,
                recipientUserId: memberId,
                msgId: msgId
            ), sealed.didSeal {
                // ATSAM seal succeeded. Emit a targeted envelope: only
                // this `memberId` can decrypt the wrapped key bytes.
                var perEnv = MeshEnvelope(
                    clientMessageId: msgId,
                    roomId: groupId,
                    senderId: myId,
                    senderName: myName,
                    recipientId: memberId,
                    type: 6,                       // system
                    text: sealed.base64,
                    timestamp: Date().timeIntervalSince1970,
                    sprayCounter: PremiumLimits.meshSprayBudget,
                    hopCount: 0,
                    hopLimit: PremiumLimits.meshHopLimit,
                    routePath: [deviceId],
                    originDeviceId: deviceId,
                    needsForwarding: true
                )
                perEnv.ttlSeconds = PremiumLimits.meshTTLSeconds
                perEnv.isGroup = false  // routed per-recipient, NOT group fan-out
                perEnv.payloadKind = "group_key_atsam"
                #if DEBUG
                print("🔐 [GroupBroadcaster] ATSAM-wrapped group_key for member=\(memberId.prefix(8)) gid=\(groupId.prefix(8)) v=\(version) mid=\(msgId.prefix(12))")
                #endif
                await BLEMeshEngine.shared.enqueueForBroadcast(perEnv)
                atsamEnvelopesEmitted += 1
            } else {
                // No ATSAM root for this peer. Defer to the legacy
                // fallback envelope (single broadcast at the end).
                unrootedMembers.append(memberId)
            }
        }

        // 🔐 ROUND 75 Phase 2 — legacy plaintext fallback ONLY when at
        // least one member has no ATSAM pairing. When every member is
        // covered by ATSAM, the plaintext key is never on the wire.
        //
        // 🔴 AUDIT 2026-05-29 (#97 / H8.F5) — this fallback puts the RAW AES
        // group key into MeshEnvelope.text in cleartext over BLE, so any
        // passive listener in range captures it and can decrypt the group.
        // It is now gated behind a default-OFF feature flag. When disabled
        // (the default), unrooted members receive the key via the targeted
        // ATSAM path once a post-quantum pair is established — never cleartext.
        if !unrootedMembers.isEmpty && FeatureFlag.legacyPlaintextGroupKey.isEnabled {
            var envelope = MeshEnvelope(
                clientMessageId: "groupKey-\(groupId)-v\(version)-\(UUID().uuidString.prefix(8))",
                roomId: groupId,
                senderId: myId,
                senderName: myName,
                recipientId: groupId,
                type: 6,                           // MessageType.system index
                text: payloadJSON,
                timestamp: Date().timeIntervalSince1970,
                sprayCounter: PremiumLimits.meshSprayBudget,
                hopCount: 0,
                hopLimit: PremiumLimits.meshHopLimit,
                routePath: [deviceId],
                originDeviceId: deviceId,
                needsForwarding: true
            )
            envelope.ttlSeconds = PremiumLimits.meshTTLSeconds
            envelope.isGroup = true
            envelope.payloadKind = "group_key"

            #if DEBUG
            print("⚠️ [GroupBroadcaster] LEGACY PLAINTEXT group_key broadcast (no ATSAM root for \(unrootedMembers.count) member(s): \(unrootedMembers.map { $0.prefix(8) }.joined(separator: ","))) gid=\(groupId.prefix(8)) v=\(version)")
            #endif

            await BLEMeshEngine.shared.enqueueForBroadcast(envelope)
        }

        #if DEBUG
        print("🟦 [GroupBroadcaster] broadcastKey DONE gid=\(groupId.prefix(8)) v=\(version) atsam_envelopes=\(atsamEnvelopesEmitted) unrooted=\(unrootedMembers.count) total_members=\(allMembers.count)")
        #endif
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
