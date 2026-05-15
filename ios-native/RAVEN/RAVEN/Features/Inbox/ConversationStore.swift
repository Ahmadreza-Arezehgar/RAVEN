import Foundation
import SwiftUI
import Combine

// MARK: - Conversation Store (Source of Truth = DB)
@MainActor
@Observable
class ConversationStore {
    nonisolated(unsafe) static let shared = ConversationStore()
    
    var conversations: [Conversation] = []
    var isLoading = false
    var error: Error?
    var lastSyncTime: Date?
    
    /// Search query for filtering conversations
    var searchQuery: String = ""
    
    /// Filtered conversations based on search query
    var filteredConversations: [Conversation] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return conversations }
        
        return conversations.filter { c in
            c.peer.displayName.lowercased().contains(q)
            || (c.lastMessage?.content?.lowercased().contains(q) ?? false)
        }
    }
    
    private let conversationRepo = ConversationRepository.shared
    private let messageRepo = MessageRepository.shared
    private var lastFetchedTimestamp: String?
    
    nonisolated private init() {}
    
    // MARK: - Fetch from API (with since parameter)
    
    func fetchConversations(forceFull: Bool = false) async {
        // Offline-first: Skip server if no network
        guard NetworkMonitor.shared.isOnline || forceFull else {
            #if DEBUG
            print("📦 [ConversationStore] Offline - loading from DB only")
            #endif
            await loadFromDB()
            return
        }
        
        isLoading = true
        error = nil
        
        do {
            // Use since parameter for incremental updates
            var queryItems = [URLQueryItem(name: "limit", value: "50")]
            
            if !forceFull, let since = lastFetchedTimestamp {
                queryItems.append(URLQueryItem(name: "since", value: since))
            }
            
            let fetched: [Conversation] = try await NetworkService.shared.get(
                path: "/api/messages/conversations",
                queryItems: queryItems
            )
            
            // DEBUG: Show groups fetched
            let groups = fetched.filter { $0.isGroup }
            #if DEBUG
            print("👥 [ConversationStore] Fetched \(fetched.count) conversations, \(groups.count) groups")
            #endif
            for g in groups {
                #if DEBUG
                print("   GROUP: \(g.groupName ?? "unnamed") roomId:\(g.roomId.prefix(8))")
                #endif
            }
            
            // Update last fetch timestamp
            if let latest = fetched.first?.updatedAt {
                lastFetchedTimestamp = PerformanceConstants.iso8601.string(from: latest)
            }
            
            // Write-through to DB
            for conversation in fetched {
                try? await conversationRepo.upsert(conversation)
            }
            
            // Merge any duplicate conversations at DB level
            try? await conversationRepo.deduplicateByPeerId()
            
            // Hydrate any conversations with missing peer names (shows "User UUID")
            await conversationRepo.hydrateMissingPeerInfo()
            
            // Reload from DB (source of truth)
            await loadFromDB()
            
            lastSyncTime = Date()
            isLoading = false
            
        } catch {
            #if DEBUG
            print("❌ [ConversationStore] fetchConversations failed: \(error)")
            #endif
            if let apiError = error as? APIError {
                #if DEBUG
                print("❌ [ConversationStore] APIError type: \(apiError)")
                #endif
            }
            self.error = error
            isLoading = false
            
            // Still try to load from DB (offline-first)
            await loadFromDB()
        }
    }
    
    // MARK: - Load from DB (Primary data source)
    
    func loadFromDB() async {
        do {
            let rows = try await conversationRepo.getAllSorted()
            
            // DEBUG: Show all conversations in DB
            #if DEBUG
            print("🟡 [ConversationStore] ════ ALL CONVERSATIONS IN DB ════")
            #endif
            for (index, conv) in rows.enumerated() {
                let groupInfo = conv.isGroup ? " [GROUP: \(conv.groupName ?? "unnamed")]" : ""
                #if DEBUG
                print("🟡 [\(index)] roomId:\(conv.roomId.prefix(8)) peerId:\(conv.peer.userId.prefix(8)) name:\(conv.peer.displayName)\(groupInfo)")
                #endif
            }
            #if DEBUG
            print("🟡 [ConversationStore] ════════════════════════════════")
            #endif
            
            // Filter out empty/invalid conversations first
            let validRows = rows.filter { !$0.roomId.isEmpty }
            
            // For groups: dedupe by roomId (group ID)
            // For 1:1: dedupe by peer.userId
            var seenKeys: Set<String> = []
            var dedupedConversations: [Conversation] = []
            
            for conversation in validRows {
                // Groups use roomId as unique key, 1:1 use peerId
                let uniqueKey = conversation.isGroup ? "group:\(conversation.roomId)" : "peer:\(conversation.peer.userId)"
                
                if !seenKeys.contains(uniqueKey) {
                    seenKeys.insert(uniqueKey)
                    
                    // For GROUPS: Keep the original roomId (group ID from server)
                    if conversation.isGroup {
                        dedupedConversations.append(conversation)
                    } else {
                        // For 1:1: Normalize roomId to peer.userId for consistency
                        let peerId = conversation.peer.userId
                        var normalizedConversation = conversation
                        if conversation.roomId != peerId {
                            #if DEBUG
                            print("🔧 [ConversationStore] Normalizing roomId \(conversation.roomId.prefix(8)) -> \(peerId.prefix(8))")
                            #endif
                            normalizedConversation = Conversation(
                                roomId: peerId,  // ← Use peer.userId for 1:1
                                peer: conversation.peer,
                                lastMessage: conversation.lastMessage,
                                unreadCount: conversation.unreadCount,
                                isPinned: conversation.isPinned,
                                isMuted: conversation.isMuted,
                                updatedAt: conversation.updatedAt,
                                isGroup: false,
                                groupName: nil,
                                groupAvatarUrl: nil
                            )
                        }
                        dedupedConversations.append(normalizedConversation)
                    }
                } else {
                    #if DEBUG
                    print("⚠️ Duplicate conversation filtered: \(uniqueKey)")
                    #endif
                }
            }
            
            // CRITICAL: Update conversations on MainActor with animation for smooth transitions
            withAnimation(.default) {
                conversations = dedupedConversations
            }
        } catch {
            #if DEBUG
            print("Failed to load conversations from DB: \(error)")
            #endif
        }
    }
    
    // MARK: - Handle Incoming Message (from poll or push)
    
    func handleIncomingMessage(_ message: ChatMessage) async {
        // 1. CRITICAL: Normalize roomId to peerId before saving
        // This ensures all messages for a peer use consistent roomId
        let currentUserId = await KeychainService.shared.getUserId() ?? ""
        let isOutgoing = message.senderId == currentUserId
        let peerId = isOutgoing ? message.recipientId : message.senderId
        
        var normalizedMessage = message
        // Bug 3 fix: Multi-layer group detection — don't rely solely on in-memory array.
        // 1. Check in-memory conversations (fast path)
        // 2. Fallback: check groups DB table (covers groups not yet loaded into memory)
        // 3. Fallback: check conversations DB table (covers conversations not yet loaded)
        let actualRoomId = message.roomId ?? peerId
        var isGroupMessage = self.conversations.contains(where: { $0.roomId == actualRoomId && ($0.isGroup || $0.isChannel) })
        if !isGroupMessage {
            // DB fallback: check if actualRoomId is a known group or channel
            let groupExists = (try? await DatabaseService.shared.exists(
                "SELECT 1 FROM groups WHERE id = ? LIMIT 1", params: [actualRoomId]
            )) ?? false
            let convIsGroup = (try? await DatabaseService.shared.exists(
                "SELECT 1 FROM conversations WHERE room_id = ? AND (is_group = 1 OR is_channel = 1) LIMIT 1", params: [actualRoomId]
            )) ?? false
            isGroupMessage = groupExists || convIsGroup
        }
        if !isGroupMessage && message.roomId != peerId {
            #if DEBUG
            print("🔧 [ConversationStore] Normalizing message roomId \(message.roomId?.prefix(8) ?? "nil") -> \(peerId.prefix(8))")
            #endif
            normalizedMessage.roomId = peerId
        }
        
        // 2. Insert message to DB ONLY if not already present (idempotent)
        // Exception: location messages bypass duplicate check — live location
        // updates reuse the same clientMessageId with updated GPS coordinates.
        let exists = await messageRepo.exists(clientMessageId: message.id)
        if !exists || message.type == .location {
            try? await messageRepo.upsert(normalizedMessage)
        }
        
        // 3. ALWAYS update conversation in DB (even for own sent messages)
        // This ensures inbox lastMessage/sort order stays current
        try? await conversationRepo.applyMessage(normalizedMessage, currentUserId: currentUserId)
        
        // BRIDGE: If message needs forwarding and we have mesh peers, relay via mesh
        // This enables online devices to forward server messages to offline users
        #if !targetEnvironment(simulator)
        if normalizedMessage.needsForwarding && !BLEMeshEngine.shared.connectedPeers.isEmpty {
            await forwardServerMessageToMesh(normalizedMessage)
        }
        #endif
        
        // 5. P0 FIX: Use group roomId for group messages, peerId for 1:1
        // Previously always used peerId, which routed group messages to DM chats
        let effectiveRoomId = isGroupMessage ? actualRoomId : peerId
        await MainActor.run {
            NotificationCenter.default.post(
                name: MessageStore.meshMessageReceivedNotification,  // Reuse same notification
                object: nil,
                userInfo: ["roomId": effectiveRoomId]
            )
        }
        
        // 6. Reload from DB to update UI
        await loadFromDB()
        
        // 7. Background: cache media attachment for offline access
        let msgForCache = normalizedMessage
        Task.detached(priority: .utility) {
            await MediaCacheService.shared.cacheMedia(for: CacheableMessage(from: msgForCache))
        }
    }
    
    // MARK: - Server-to-Mesh Bridge
    
    /// Forward a server message to mesh peers
    /// Called when we receive a message destined for an offline user
    private func forwardServerMessageToMesh(_ message: ChatMessage) async {
        #if DEBUG
        print("🌉 [Bridge] Forwarding server message to mesh: \(message.id.prefix(8))")
        #endif
        
        // Create mesh envelope
        var envelope = message.toMeshEnvelope()
        
        // CRITICAL FIX: Mark this envelope as bridged so the receiving mesh node knows
        // to trust the bridge's signature, since server messages lack original Ed25519 signatures.
        envelope.isBridged = true
        envelope.hopCount = 1
        
        // Broadcast to mesh
        await BLEMeshEngine.shared.enqueueForBroadcast(envelope)
        
        #if DEBUG
        print("✅ [Bridge] Server message forwarded to \(BLEMeshEngine.shared.connectedPeers.count) mesh peers")
        #endif
    }
    
    // MARK: - Handle Batch Messages (from poll)
    
    func handleIncomingMessages(_ messages: [ChatMessage]) async {
        let currentUserId = await KeychainService.shared.getUserId() ?? ""
        var processedRoomIds: Set<String> = []
        var newMessages: [ChatMessage] = []  // Track actually NEW messages (not duplicates)
        
        #if DEBUG
        print("🔍 [handleIncomingMessages] Processing \(messages.count) messages, currentUserId=\(currentUserId.prefix(8))")
        #endif
        
        for (index, message) in messages.enumerated() {
            // DEBUG: Log message details
            #if DEBUG
            print("📦 [\(index)] Message id=\(message.id.prefix(8))")
            print("   senderId: '\(message.senderId)' (len=\(message.senderId.count))")
            print("   recipientId: '\(message.recipientId)' (len=\(message.recipientId.count))")
            #endif
            
            // Calculate peerId FIRST (needed for notifications regardless of duplicate status)
            let isOutgoing = message.senderId == currentUserId
            let peerId = isOutgoing ? message.recipientId : message.senderId
            
            // Bug 3 fix: Multi-layer group detection (same as handleIncomingMessage)
            let actualRoomId = message.roomId ?? peerId
            var isGroupMessage = self.conversations.contains(where: { $0.roomId == actualRoomId && ($0.isGroup || $0.isChannel) })
            if !isGroupMessage {
                let groupExists = (try? await DatabaseService.shared.exists(
                    "SELECT 1 FROM groups WHERE id = ? LIMIT 1", params: [actualRoomId]
                )) ?? false
                let convIsGroup = (try? await DatabaseService.shared.exists(
                    "SELECT 1 FROM conversations WHERE room_id = ? AND (is_group = 1 OR is_channel = 1) LIMIT 1", params: [actualRoomId]
                )) ?? false
                isGroupMessage = groupExists || convIsGroup
            }
            
            // P0 FIX: Use group roomId for groups, peerId for 1:1
            // Previously always used peerId, which routed group messages to DM chats
            let effectiveRoomId = isGroupMessage ? actualRoomId : peerId
            
            #if DEBUG
            print("   isOutgoing: \(isOutgoing), peerId: '\(peerId)', isGroup: \(isGroupMessage), effectiveRoomId: '\(effectiveRoomId.prefix(8))'")
            #endif
            
            // CRITICAL FIX: ALWAYS track this room for notification
            // Even if message is duplicate, UI may need refresh (fixes Dual Polling race)
            processedRoomIds.insert(effectiveRoomId)
            
            // Idempotent insert - skip DB work for existing messages
            // Exception: location messages always pass through so live location
            // coordinate updates are persisted (same clientMessageId, new text).
            let alreadyExists = await messageRepo.exists(clientMessageId: message.id)
            if alreadyExists {
                if message.type != .location { continue }
            }
            
            // This is a NEW message (not duplicate) - add to list for banner
            newMessages.append(message)
            
            // Normalize roomId to peerId — but only for 1:1 messages
            var normalizedMessage = message
            if !isGroupMessage && message.roomId != peerId {
                #if DEBUG
                print("🔧 [ConversationStore] NORMALIZING roomId: \(message.roomId?.prefix(8) ?? "nil") → \(peerId.prefix(8))")
                #endif
                normalizedMessage.roomId = peerId
            } else {
                #if DEBUG
                print("✅ [ConversationStore] roomId already correct (or group): \(message.roomId?.prefix(8) ?? "nil")")
                #endif
            }
            
            try? await messageRepo.upsert(normalizedMessage)
            try? await conversationRepo.applyMessage(normalizedMessage, currentUserId: currentUserId)
            
            // BRIDGE: If message needs forwarding and we have mesh peers, relay via mesh
            // This enables online devices to forward server messages to offline users
            #if !targetEnvironment(simulator)
            if normalizedMessage.needsForwarding && !BLEMeshEngine.shared.connectedPeers.isEmpty {
                await forwardServerMessageToMesh(normalizedMessage)
            }
            #endif
        }
        
        // Notify MessageStore for each room that had new messages
        #if DEBUG
        print("🔔 [ConversationStore] About to post notifications for \(processedRoomIds.count) rooms: \(processedRoomIds.map { $0.prefix(8) })")
        #endif
        
        for roomId in processedRoomIds {
            #if DEBUG
            print("📣 [ConversationStore] Posting notification for roomId: \(roomId.prefix(8))")
            #endif
            NotificationCenter.default.post(
                name: MessageStore.meshMessageReceivedNotification,
                object: nil,
                userInfo: ["roomId": roomId]
            )
        }
        
        // NOTE: In-app banners are NOT shown here to avoid duplicates.
        // PushNotificationService.handleForegroundPush already shows banners for push-triggered messages.
        // WebSocket messages also arrive via push, so showing banners here double notifications.
        
        if !newMessages.isEmpty {
            let cacheables = newMessages.map { CacheableMessage(from: $0) }
            Task.detached(priority: .utility) {
                await MediaCacheService.shared.cacheMediaBatch(messages: cacheables)
            }
        }
        
        // Single reload after batch
        await loadFromDB()
    }
    
    // MARK: - Actions
    
    func markAsRead(roomId: String) async {
        var lastMsgId: String? = nil
        var hadUnread = false
        
        // 1. Optimistic Update (instant UI)
        if let index = conversations.firstIndex(where: { $0.roomId == roomId }) {
            if conversations[index].unreadCount > 0 {
                hadUnread = true
            }
            conversations[index].unreadCount = 0
            lastMsgId = conversations[index].lastMessage?.id
        }
        
        // 2. Update DB locally ALWAYS to prevent stuck badges
        try? await conversationRepo.markAsRead(roomId: roomId)
        
        guard hadUnread else { return }
        
        // 3. Ghost Mode: suppress server read-receipt for RAVEN+ users
        guard !PremiumLimits.ghostModeEnabled else { return }
        
        // 4. Queue for Server Sync
        await PendingReadService.shared.enqueue(type: "message", targetId: roomId, lastItemId: lastMsgId, isAll: false)
    }
    
    func togglePin(roomId: String) async {
        if let index = conversations.firstIndex(where: { $0.roomId == roomId }) {
            conversations[index].isPinned.toggle()
            try? await conversationRepo.togglePin(roomId: roomId)
            withAnimation {
                sortConversations()
            }
        }
    }
    
    func toggleMute(roomId: String) async {
        guard let index = conversations.firstIndex(where: { $0.roomId == roomId }) else { return }
        
        let newMutedState = !conversations[index].isMuted
        let isGroup = conversations[index].isGroup
        let peerId = conversations[index].peer.userId
        
        conversations[index].isMuted = newMutedState
        try? await conversationRepo.toggleMute(roomId: roomId)
        
        if isGroup {
            // For groups: use group-specific mute settings API
            let settings = MuteSettings(muteUntil: newMutedState ? .distantFuture : nil, mentionsOnly: false)
            Task { await GroupService.shared.setMuteSettings(groupId: roomId, settings: settings) }
        } else {
            // For 1:1 chats: sync to server
            guard NetworkMonitor.shared.isOnline else { return }
            struct MuteRequest: Codable {
                let peer_id: String
                let muted: Bool
            }
            _ = try? await NetworkService.shared.post(
                path: "/api/messages/conversations/mute",
                body: MuteRequest(peer_id: peerId, muted: newMutedState)
            ) as EmptyResponse
        }
        #if DEBUG
        print("🔕 [ConversationStore] Mute synced: \(newMutedState) isGroup=\(isGroup)")
        #endif
    }
    
    func deleteConversation(roomId: String) async {
        let conversation = conversations.first { $0.roomId == roomId }
        let peerId = conversation?.peer.userId
        let isGroup = conversation?.isGroup ?? false
        
        // Remove from local list (optimistic)
        conversations.removeAll { $0.roomId == roomId }
        
        if isGroup {
            // For groups: leave on server FIRST, then clean up locally
            if NetworkMonitor.shared.isOnline {
                do {
                    try await GroupService.shared.leaveGroup(groupId: roomId)
                    // Server confirmed — safe to delete local DB entry
                    try? await conversationRepo.delete(roomId: roomId)
                } catch {
                    // Server rejected — rollback optimistic delete
                    #if DEBUG
                    print("❌ [ConversationStore] leaveGroup failed, rolling back: \(error)")
                    #endif
                    if let conversation = conversation {
                        conversations.append(conversation)
                        sortConversations()
                    } else {
                        // Conversation wasn't in memory — reload from DB
                        await loadFromDB()
                    }
                    return
                }
            } else {
                // Offline: just delete locally, will re-sync on next fetch
                try? await conversationRepo.delete(roomId: roomId)
            }
        } else {
            // For 1:1 chats: delete from DB first, then sync to server
            try? await conversationRepo.delete(roomId: roomId)
            if let peerId = peerId, NetworkMonitor.shared.isOnline {
                _ = try? await NetworkService.shared.post(
                    path: "/api/messages/conversations/delete",
                    body: ["peer_id": peerId]
                ) as EmptyResponse
            }
        }
        
        #if DEBUG
        print("🗑️ [ConversationStore] Deleted conversation: \(roomId.prefix(8)) isGroup=\(isGroup)")
        #endif
    }
    
    /// Mark all conversations as read
    func markAllAsRead() async {
        let unreadRoomIds = conversations.filter { $0.unreadCount > 0 }.map { $0.roomId }
        
        // 1. Optimistic Update (local copy → 1 UI refresh)
        var updated = conversations
        for index in updated.indices {
            updated[index].unreadCount = 0
        }
        conversations = updated
        
        // 2. Update Local DB
        for roomId in unreadRoomIds {
            try? await conversationRepo.markAsRead(roomId: roomId)
        }
        
        // 3. Queue for Server Sync
        if !PremiumLimits.ghostModeEnabled && !unreadRoomIds.isEmpty {
            await PendingReadService.shared.enqueue(type: "message", targetId: nil, isAll: true)
        }
    }
    
    // MARK: - Sorting
    
    private func sortConversations() {
        conversations.sort { a, b in
            // Pinned first
            if a.isPinned != b.isPinned {
                return a.isPinned
            }
            // Then by last message timestamp (newest first)
            let aTime = a.lastMessage?.timestamp ?? a.updatedAt
            let bTime = b.lastMessage?.timestamp ?? b.updatedAt
            return aTime > bTime
        }
    }
    
    // MARK: - Stats
    
    var totalUnreadCount: Int {
        conversations.filter { !$0.isMuted }.reduce(0) { $0 + $1.unreadCount }
    }
}

// MARK: - Empty Response
struct EmptyResponse: Decodable {}
