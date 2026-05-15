import Foundation

// MARK: - Conversation Repository
actor ConversationRepository {
    static let shared = ConversationRepository()
    
    private let db = DatabaseService.shared
    
    private init() {}
    
    // MARK: - Room ID Helper
    
    /// Returns normalized roomId based on conversation type
    /// - Group: uses actual roomId (preserves group identity)
    /// - 1:1: uses peer.userId (prevents duplicates from server roomId variations)
    private func roomIdFor(_ conversation: Conversation) -> String {
        if conversation.isGroup || conversation.isChannel {
            return conversation.roomId
        }
        return conversation.peer.userId
    }
    
    /// Returns normalized roomId for a message
    /// - Group/Channel message: uses message.roomId (confirmed via groups or conversations table)
    /// - 1:1 message: uses peerId (sender or recipient based on direction)
    private func roomIdForMessage(_ message: ChatMessage, peerId: String) async -> String {
        if let roomId = message.roomId, !roomId.isEmpty {
            let isGroup = (try? await db.exists(
                "SELECT 1 FROM groups WHERE id = ? LIMIT 1", params: [roomId]
            )) ?? false
            let isChannel = (try? await db.exists(
                "SELECT 1 FROM conversations WHERE room_id = ? AND is_channel = 1 LIMIT 1", params: [roomId]
            )) ?? false
            if isGroup || isChannel { return roomId }
        }
        return peerId  // 1:1 message
    }
    
    // MARK: - Upsert (Idempotent by room_id)
    
    func upsert(_ conversation: Conversation) async throws {
        let sql = """
            INSERT INTO conversations (
                room_id, peer_id, peer_username, peer_first_name, peer_last_name, peer_avatar_path,
                last_message_id, last_message_content, last_message_type, last_message_timestamp,
                last_message_sender_id, last_message_delivery_authority,
                unread_count, is_pinned, is_muted, updated_at,
                is_group, group_name, group_avatar_url, is_verified,
                is_channel, channel_username, channel_type,
                request_status, is_request_sender, pending_sent_count, request_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(room_id) DO UPDATE SET
                peer_username = COALESCE(excluded.peer_username, peer_username),
                peer_first_name = COALESCE(excluded.peer_first_name, peer_first_name),
                peer_last_name = COALESCE(excluded.peer_last_name, peer_last_name),
                peer_avatar_path = COALESCE(excluded.peer_avatar_path, peer_avatar_path),
                last_message_id = CASE 
                    WHEN excluded.last_message_timestamp > COALESCE(conversations.last_message_timestamp, '') 
                    THEN excluded.last_message_id ELSE conversations.last_message_id END,
                last_message_content = CASE 
                    WHEN excluded.last_message_timestamp > COALESCE(conversations.last_message_timestamp, '') 
                    THEN excluded.last_message_content ELSE conversations.last_message_content END,
                last_message_type = CASE 
                    WHEN excluded.last_message_timestamp > COALESCE(conversations.last_message_timestamp, '') 
                    THEN excluded.last_message_type ELSE conversations.last_message_type END,
                last_message_timestamp = CASE 
                    WHEN excluded.last_message_timestamp > COALESCE(conversations.last_message_timestamp, '') 
                    THEN excluded.last_message_timestamp ELSE conversations.last_message_timestamp END,
                last_message_sender_id = CASE 
                    WHEN excluded.last_message_timestamp > COALESCE(conversations.last_message_timestamp, '') 
                    THEN excluded.last_message_sender_id ELSE conversations.last_message_sender_id END,
                last_message_delivery_authority = CASE 
                    WHEN excluded.last_message_timestamp > COALESCE(conversations.last_message_timestamp, '') 
                    THEN excluded.last_message_delivery_authority ELSE conversations.last_message_delivery_authority END,
                unread_count = CASE 
                    WHEN excluded.unread_count = 0 THEN 0
                    WHEN excluded.last_message_timestamp > COALESCE(conversations.last_message_timestamp, '') THEN excluded.unread_count 
                    ELSE conversations.unread_count 
                END,
                updated_at = MAX(excluded.updated_at, conversations.updated_at),
                is_group = excluded.is_group,
                group_name = COALESCE(excluded.group_name, group_name),
                group_avatar_url = COALESCE(excluded.group_avatar_url, group_avatar_url),
                is_verified = excluded.is_verified,
                is_channel = excluded.is_channel,
                channel_username = COALESCE(excluded.channel_username, channel_username),
                channel_type = COALESCE(excluded.channel_type, channel_type),
                request_status = COALESCE(excluded.request_status, request_status),
                is_request_sender = COALESCE(excluded.is_request_sender, is_request_sender),
                pending_sent_count = COALESCE(excluded.pending_sent_count, pending_sent_count),
                request_id = COALESCE(excluded.request_id, request_id)
        """
        let dateFormatter = SharedDateFormatters.iso8601Standard
        
        // Break up complex expression for type checker
        let lastMessageTimestamp: Any
        if let ts = conversation.lastMessage?.timestamp {
            lastMessageTimestamp = dateFormatter.string(from: ts)
        } else {
            lastMessageTimestamp = NSNull()
        }
        
        let lastMessageDeliveryAuthority: Any = conversation.lastMessage?.deliveryAuthority?.rawValue as Any? ?? NSNull()
        
        // CRITICAL: roomId logic depends on conversation type
        // - Group: use actual roomId (keeps group identity)
        // - 1:1: use peer.userId (prevents duplicates from server roomId variations)
        let normalizedRoomId = roomIdFor(conversation)
        
        let params: [Any] = [
            normalizedRoomId,
            conversation.peer.userId,
            conversation.peer.username,
            conversation.peer.firstName as Any? ?? NSNull(),
            conversation.peer.lastName as Any? ?? NSNull(),
            conversation.peer.avatarPath as Any? ?? NSNull(),
            conversation.lastMessage?.id as Any? ?? NSNull(),
            conversation.lastMessage?.content as Any? ?? NSNull(),
            conversation.lastMessage?.messageType.rawValue as Any? ?? NSNull(),
            lastMessageTimestamp,
            conversation.lastMessage?.senderId as Any? ?? NSNull(),
            lastMessageDeliveryAuthority,
            conversation.unreadCount,
            conversation.isPinned ? 1 : 0,
            conversation.isMuted ? 1 : 0,
            dateFormatter.string(from: conversation.updatedAt),
            conversation.isGroup ? 1 : 0,
            conversation.groupName as Any? ?? NSNull(),
            conversation.groupAvatarUrl as Any? ?? NSNull(),
            conversation.peer.isVerified ? 1 : 0,
            conversation.isChannel ? 1 : 0,
            conversation.channelUsername as Any? ?? NSNull(),
            conversation.channelType as Any? ?? NSNull(),
            conversation.requestStatus as Any? ?? NSNull(),
            conversation.isRequestSender.map { $0 ? 1 : 0 } as Any? ?? NSNull(),
            conversation.pendingSentCount as Any? ?? NSNull(),
            conversation.requestId as Any? ?? NSNull()
        ]
        
        let groupInfo = conversation.isGroup ? " [GROUP: \(conversation.groupName ?? "unnamed")]" : ""
        #if DEBUG
        print("🔵 [UPSERT SERVER] room_id:\(normalizedRoomId.prefix(8)) peer_id:\(conversation.peer.userId.prefix(8)) name:\(conversation.peer.displayName)\(groupInfo)")
        #endif
        
        try await db.execute(sql, params: params)
    }
    
    // MARK: - Apply Message to Conversation
    
    func applyMessage(_ message: ChatMessage, currentUserId: String) async throws {
        // Generate preview text
        let preview = previewText(for: message)
        
        // Determine who the peer is based on message direction
        // If I'm the sender → peer is recipient
        // If I'm the receiver → peer is sender
        let isOutgoing = message.senderId == currentUserId
        let peerId = isOutgoing ? message.recipientId : message.senderId
        var peerName = isOutgoing ? "" : message.senderName  // We don't know recipient name from message
        
        let incrementUnread = (!isOutgoing && message.status != .read) ? 1 : 0
        var peerFirstName: String?
        var peerLastName: String?
        var peerAvatarPath: String?
        
        // SANITIZE: If senderName looks encrypted/encoded, treat as empty
        // so the COALESCE in SQL preserves any existing good name in the DB
        if peerName.hasPrefix("gAAAA") || peerName.hasPrefix("eyJ") || (!peerName.contains(" ") && peerName.count > 40) {
            #if DEBUG
            print("⚠️ [ConvRepo] Encrypted senderName detected, clearing: \(peerName.prefix(20))...")
            #endif
            peerName = ""
        }
        
        // CRITICAL: Skip if peerId is empty - prevents ghost conversations
        guard !peerId.isEmpty else {
            #if DEBUG
            print("⚠️ [ConvRepo] applyMessage SKIPPED - empty peerId! senderId:\(message.senderId.prefix(8)) recipientId:\(message.recipientId.prefix(8))")
            #endif
            return
        }
        
        // For outgoing messages, fetch peer info from API if we don't have it
        if isOutgoing && peerName.isEmpty {
            if let userInfo = try? await fetchUserInfo(userId: peerId) {
                peerName = userInfo.username
                peerFirstName = userInfo.firstName
                peerLastName = userInfo.lastName
                peerAvatarPath = userInfo.avatarPath
                #if DEBUG
                print("✅ [ConvRepo] Fetched peer info for OUTGOING: @\(peerName)")
                #endif
            }
        }
        
        // HYDRATION: For incoming messages, if we only have senderName (no firstName),
        // check local DB first to avoid N+1 network requests, then fall back to API
        if !isOutgoing && peerFirstName == nil {
            // ✅ Bug 3 fix: Query local DB first to avoid DDoSing server with fetchUserInfo
            if let localRow = try? await db.query(
                "SELECT peer_first_name, peer_last_name, peer_username, peer_avatar_path FROM conversations WHERE peer_id = ? LIMIT 1",
                params: [peerId]
            ).first,
               let localFirst = localRow["peer_first_name"] as? String, !localFirst.isEmpty {
                peerFirstName = localFirst
                peerLastName = localRow["peer_last_name"] as? String
                if let localUsername = localRow["peer_username"] as? String, !localUsername.isEmpty {
                    peerName = localUsername
                }
                peerAvatarPath = localRow["peer_avatar_path"] as? String
                #if DEBUG
                print("✅ [ConvRepo] Peer info found in LOCAL DB: @\(peerName) first:\(peerFirstName ?? "nil")")
                #endif
            } else if let userInfo = try? await fetchUserInfo(userId: peerId) {
                peerName = userInfo.username
                peerFirstName = userInfo.firstName
                peerLastName = userInfo.lastName
                peerAvatarPath = userInfo.avatarPath
                #if DEBUG
                print("✅ [ConvRepo] Fetched peer info from API for INCOMING: @\(peerName) first:\(peerFirstName ?? "nil")")
                #endif
            }
        }
        
        #if DEBUG
        print("🔍 [ConvRepo] applyMessage - myId:\(currentUserId.prefix(8)), senderId:\(message.senderId.prefix(8)), recipientId:\(message.recipientId.prefix(8))")
        print("🔍 [ConvRepo] applyMessage - isOutgoing:\(isOutgoing), peerId:\(peerId.prefix(8)), roomId:\(message.roomId?.prefix(8) ?? "nil")")
        #endif
        
        // For mesh messages, we need to include peer info in case conversation doesn't exist
        let sql = """
            INSERT INTO conversations (
                room_id, peer_id, peer_username, peer_first_name, peer_last_name, peer_avatar_path,
                last_message_id, last_message_content, last_message_type,
                last_message_timestamp, last_message_sender_id, last_message_delivery_authority,
                unread_count, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(room_id) DO UPDATE SET
                peer_id = COALESCE(excluded.peer_id, conversations.peer_id),
                peer_username = COALESCE(NULLIF(excluded.peer_username, ''), conversations.peer_username),
                peer_first_name = COALESCE(excluded.peer_first_name, conversations.peer_first_name),
                peer_last_name = COALESCE(excluded.peer_last_name, conversations.peer_last_name),
                peer_avatar_path = COALESCE(excluded.peer_avatar_path, conversations.peer_avatar_path),
                last_message_id = excluded.last_message_id,
                last_message_content = excluded.last_message_content,
                last_message_type = excluded.last_message_type,
                last_message_timestamp = excluded.last_message_timestamp,
                last_message_sender_id = excluded.last_message_sender_id,
                last_message_delivery_authority = excluded.last_message_delivery_authority,
                unread_count = conversations.unread_count + ?,
                updated_at = excluded.updated_at
        """
        
        // CRITICAL: roomId depends on message type
        // - Group: uses message.roomId (preserves group identity)
        // - 1:1: uses peerId (prevents duplicates)
        let roomId = await roomIdForMessage(message, peerId: peerId)
        let isGroupMessage = roomId != peerId
        
        #if DEBUG
        print("🟢 [APPLY MESSAGE] room_id:\(roomId.prefix(8)) peer_id:\(peerId.prefix(8)) isOutgoing:\(isOutgoing) isGroup:\(isGroupMessage)")
        #endif
        
        try await db.execute(sql, params: [
            roomId,
            peerId,
            peerName,
            peerFirstName ?? NSNull(),
            peerLastName ?? NSNull(),
            peerAvatarPath ?? NSNull(),
            message.id,
            preview,
            message.type.rawValue,
            SharedDateFormatters.formatISO8601(message.timestamp),
            message.senderId,
            message.deliveryAuthority.rawValue,
            incrementUnread,  // unread_count for insert
            SharedDateFormatters.formatISO8601(Date()),
            incrementUnread   // For unread_count + ? in ON CONFLICT
        ])
    }
    
    // MARK: - Fetch User Info (for peer details)
    
    private func fetchUserInfo(userId: String) async throws -> (username: String, firstName: String?, lastName: String?, avatarPath: String?) {
        struct UserResponse: Decodable {
            let id: String
            let username: String
            let firstName: String?
            let lastName: String?
            let avatarPath: String?
            
            enum CodingKeys: String, CodingKey {
                case id, username
                case firstName = "first_name"
                case lastName = "last_name"
                case avatarPath = "avatar_path"
            }
        }
        
        let user: UserResponse = try await NetworkService.shared.get(path: "/api/users/\(userId)")
        return (user.username, user.firstName, user.lastName, user.avatarPath)
    }
    
    // MARK: - Hydrate Missing Peer Info
    
    /// Updates existing conversations that have missing peer info (shows "User UUID" instead of real name)
    func hydrateMissingPeerInfo() async {
        #if DEBUG
        print("🔄 [ConvRepo] Starting peer info hydration...")
        #endif
        
        // Find conversations with missing first_name (these show "User UUID")
        let sql = """
            SELECT room_id, peer_id, peer_username, peer_first_name 
            FROM conversations 
            WHERE peer_first_name IS NULL OR peer_first_name = ''
        """
        
        guard let rows = try? await db.query(sql) else {
            #if DEBUG
            print("⚠️ [ConvRepo] Hydration query failed")
            #endif
            return
        }
        
        #if DEBUG
        print("🔍 [ConvRepo] Found \(rows.count) conversations needing hydration")
        #endif
        
        for row in rows {
            guard let peerId = row["peer_id"] as? String, !peerId.isEmpty else { continue }
            
            do {
                let (username, firstName, lastName, avatarPath) = try await fetchUserInfo(userId: peerId)
                let updateSQL = """
                    UPDATE conversations SET 
                        peer_username = COALESCE(?, peer_username),
                        peer_first_name = ?,
                        peer_last_name = ?,
                        peer_avatar_path = COALESCE(?, peer_avatar_path)
                    WHERE peer_id = ?
                """
                try await db.execute(updateSQL, params: [
                    username,
                    firstName ?? NSNull(),
                    lastName ?? NSNull(),
                    avatarPath ?? NSNull(),
                    peerId
                ])
                #if DEBUG
                print("✅ [ConvRepo] Hydrated peer: @\(username) -> \(firstName ?? "nil") \(lastName ?? "")")
                #endif
            } catch {
                #if DEBUG
                print("⚠️ [ConvRepo] Failed to hydrate peer \(peerId.prefix(8)): \(error)")
                #endif
            }
        }
        
        #if DEBUG
        print("✅ [ConvRepo] Peer info hydration completed")
        #endif
    }
    
    // MARK: - Get All Sorted
    
    func getAllSorted() async throws -> [Conversation] {
        let sql = """
            SELECT * FROM conversations 
            ORDER BY is_pinned DESC, last_message_timestamp DESC
        """
        
        let rows = try await db.query(sql)
        return rows.compactMap { row in
            parseConversation(from: row)
        }
    }
    
    // MARK: - Actions
    
    func markAsRead(roomId: String) async throws {
        try await db.execute(
            "UPDATE conversations SET unread_count = 0 WHERE room_id = ?",
            params: [roomId]
        )
    }
    
    func togglePin(roomId: String) async throws {
        try await db.execute(
            "UPDATE conversations SET is_pinned = CASE WHEN COALESCE(is_pinned, 0) = 1 THEN 0 ELSE 1 END WHERE room_id = ?",
            params: [roomId]
        )
    }
    
    func toggleMute(roomId: String) async throws {
        try await db.execute(
            "UPDATE conversations SET is_muted = CASE WHEN COALESCE(is_muted, 0) = 1 THEN 0 ELSE 1 END WHERE room_id = ?",
            params: [roomId]
        )
    }
    
    func delete(roomId: String) async throws {
        // Delete conversation
        try await db.execute(
            "DELETE FROM conversations WHERE room_id = ?",
            params: [roomId]
        )
        
        // Clean up delivery jobs BEFORE deleting messages (subquery needs messages table)
        try await db.execute(
            "DELETE FROM delivery_jobs WHERE message_id IN (SELECT client_message_id FROM messages WHERE room_id = ?)",
            params: [roomId]
        )
        
        // Clean up pending outbox entries to prevent zombie messages on reconnect
        // outbox uses client_message_id as PK, so join via messages table
        try await db.execute(
            "DELETE FROM outbox WHERE client_message_id IN (SELECT client_message_id FROM messages WHERE room_id = ?)",
            params: [roomId]
        )
        
        // Delete messages last (after dependent tables are cleaned up)
        try await db.execute(
            "DELETE FROM messages WHERE room_id = ?",
            params: [roomId]
        )
        
        #if DEBUG
        print("🗑️ [ConversationRepo] Deleted conversation, messages, outbox, and delivery_jobs for: \(roomId.prefix(8))")
        #endif
    }
    
    // MARK: - Deduplication
    
    /// Merge duplicate conversations that have the same peer_id
    /// Keeps the conversation with most messages (to avoid losing data)
    /// NOTE: Only applies to 1:1 chats (groups are excluded)
    func deduplicateByPeerId() async throws {
        // Find all peer_ids that have multiple 1:1 conversations (exclude groups)
        let duplicateSql = """
            SELECT peer_id, COUNT(*) as cnt 
            FROM conversations 
            WHERE (is_group IS NULL OR is_group = 0) AND (is_channel IS NULL OR is_channel = 0)
            GROUP BY peer_id 
            HAVING cnt > 1
        """
        
        let duplicates = try await db.query(duplicateSql)
        
        for row in duplicates {
            guard let peerId = row["peer_id"] as? String else { continue }
            
            #if DEBUG
            print("🔄 [ConversationRepo] Merging duplicates for peer: \(peerId.prefix(8))")
            #endif
            
            // Get all conversations for this peer with message count
            let conversationsSql = """
                SELECT c.room_id, c.peer_username, c.peer_first_name, 
                       c.last_message_timestamp,
                       (SELECT COUNT(*) FROM messages WHERE room_id = c.room_id) as msg_count
                FROM conversations c
                WHERE c.peer_id = ?
                ORDER BY 
                    msg_count DESC,
                    CASE WHEN c.peer_first_name IS NOT NULL THEN 1 ELSE 0 END DESC,
                    c.last_message_timestamp DESC
            """
            
            let convs = try await db.query(conversationsSql, params: [peerId])
            
            guard convs.count > 1, 
                  let bestRoomId = convs.first?["room_id"] as? String else { continue }
            
            let bestMsgCount = convs.first?["msg_count"] as? Int64 ?? 0
            #if DEBUG
            print("🔄 [ConversationRepo] Keeping room \(bestRoomId.prefix(8)) with \(bestMsgCount) messages")
            #endif
            
            // Keep the first one (most messages), merge others into it
            for (index, conv) in convs.enumerated() {
                if index == 0 { continue }  // Skip the one we're keeping
                
                guard let roomIdToDelete = conv["room_id"] as? String else { continue }
                let deleteMsgCount = conv["msg_count"] as? Int64 ?? 0
                
                #if DEBUG
                print("🔄 [ConversationRepo] Merging room \(roomIdToDelete.prefix(8)) (\(deleteMsgCount) msgs) into \(bestRoomId.prefix(8))")
                #endif
                
                // Move messages from old room to best room
                try await db.execute(
                    "UPDATE messages SET room_id = ? WHERE room_id = ?",
                    params: [bestRoomId, roomIdToDelete]
                )
                
                // Delete the duplicate conversation
                try await db.execute(
                    "DELETE FROM conversations WHERE room_id = ?",
                    params: [roomIdToDelete]
                )
                
                #if DEBUG
                print("✅ [ConversationRepo] Merged room \(roomIdToDelete.prefix(8)) into \(bestRoomId.prefix(8))")
                #endif
            }
        }
    }
    
    /// Normalize ALL existing room_ids to peer_id
    /// This fixes old data where room_id might differ from peer_id
    /// NOTE: Only applies to 1:1 chats (groups keep their original room_id)
    func normalizeRoomIdsToPeerId() async throws {
        #if DEBUG
        print("🔧 [ConversationRepo] Starting room_id normalization...")
        #endif
        
        // Find all 1:1 conversations where room_id != peer_id (exclude groups)
        let mismatchSql = """
            SELECT room_id, peer_id FROM conversations 
            WHERE room_id != peer_id
            AND (is_group IS NULL OR is_group = 0)
            AND (is_channel IS NULL OR is_channel = 0)
        """
        
        let mismatches = try await db.query(mismatchSql)
        
        guard !mismatches.isEmpty else {
            #if DEBUG
            print("✅ [ConversationRepo] All room_ids already normalized")
            #endif
            return
        }
        
        #if DEBUG
        print("🔧 [ConversationRepo] Found \(mismatches.count) conversations to normalize")
        #endif
        
        for row in mismatches {
            guard let oldRoomId = row["room_id"] as? String,
                  let peerId = row["peer_id"] as? String else { continue }
            
            #if DEBUG
            print("🔧 [ConversationRepo] Normalizing: \(oldRoomId.prefix(8)) -> \(peerId.prefix(8))")
            #endif
            
            // 1. Update messages to use peer_id as room_id
            try await db.execute(
                "UPDATE messages SET room_id = ? WHERE room_id = ?",
                params: [peerId, oldRoomId]
            )
            
            // 2. Check if target conversation (with peer_id as room_id) already exists
            let existsCheck = try await db.exists(
                "SELECT 1 FROM conversations WHERE room_id = ?",
                params: [peerId]
            )
            
            if existsCheck {
                // Target exists - just delete the old one (messages already moved)
                try await db.execute(
                    "DELETE FROM conversations WHERE room_id = ?",
                    params: [oldRoomId]
                )
                #if DEBUG
                print("  → Merged into existing conversation")
                #endif
            } else {
                // Update the conversation's room_id to peer_id
                try await db.execute(
                    "UPDATE conversations SET room_id = ? WHERE room_id = ?",
                    params: [peerId, oldRoomId]
                )
                #if DEBUG
                print("  → Updated room_id")
                #endif
            }
        }
        
        #if DEBUG
        print("✅ [ConversationRepo] Room_id normalization complete!")
        #endif
    }
    
    // MARK: - Group Conversations
    
    /// Create or update a group conversation
    /// For groups, room_id = group.id (NOT normalized to peer like 1:1 chats)
    func createGroupConversation(group: ChatGroup) async throws {
        let sql = """
            INSERT INTO conversations (
                room_id, peer_id, peer_username, peer_avatar_path,
                is_group, group_name, group_avatar_url,
                unread_count, is_pinned, is_muted, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(room_id) DO UPDATE SET
                group_name = excluded.group_name,
                group_avatar_url = COALESCE(excluded.group_avatar_url, conversations.group_avatar_url),
                updated_at = excluded.updated_at
        """
        
        let dateFormatter = SharedDateFormatters.iso8601Standard
        
        try await db.execute(sql, params: [
            group.id,                           // room_id = group.id
            group.createdBy,                   // peer_id = creator (for group info)
            group.creatorUsername ?? "",       // peer_username
            group.avatarUrl ?? NSNull(),       // peer_avatar_path
            1,                                 // is_group = true
            group.name,                        // group_name
            group.avatarUrl ?? NSNull(),       // group_avatar_url
            0,                                 // unread_count
            0,                                 // is_pinned
            0,                                 // is_muted
            dateFormatter.string(from: Date()) // updated_at
        ])
        
        #if DEBUG
        print("👥 [ConversationRepo] Created group conversation: \(group.name) (\(group.id.prefix(8)))")
        #endif
    }
    
    /// Update group name and/or avatar URL for an existing group conversation
    func updateGroupInfo(roomId: String, name: String?, avatarUrl: String?) async throws {
        var setClauses: [String] = []
        var params: [Any] = []
        
        if let name {
            setClauses.append("group_name = ?")
            params.append(name)
        }
        if let avatarUrl {
            setClauses.append("group_avatar_url = ?")
            params.append(avatarUrl)
        }
        
        guard !setClauses.isEmpty else { return }
        
        setClauses.append("updated_at = ?")
        params.append(SharedDateFormatters.formatISO8601(Date()))
        params.append(roomId)
        
        let sql = "UPDATE conversations SET \(setClauses.joined(separator: ", ")) WHERE room_id = ?"
        try await db.execute(sql, params: params)
        #if DEBUG
        print("✏️ [ConversationRepo] Updated group info for \(roomId.prefix(8)): name=\(name ?? "nil") avatar=\(avatarUrl != nil ? "set" : "nil")")
        #endif
    }
    
    // MARK: - Helpers
    
    private func previewText(for message: ChatMessage) -> String {
        switch message.type {
        case .text:
            if let t = message.text {
                if t.looksEncrypted { return "Message" }
                return t
            }
            return ""
        case .image:
            return "📷 Photo"
        case .video:
            return "🎬 Video"
        case .videoNote:
            return "🎥 Video note"
        case .ephemeralPhoto:
            return "📸 Snap Photo"
        case .voice:
            return "🎤 Voice message"
        case .file:
            return "📎 \(message.fileName ?? "File")"
        case .location:
            return "📍 Location"
        case .postShare:
            return "📬 Shared a post"
        case .system:
            return "📢 Notification"
        }
    }
    
    private func parseConversation(from row: [String: Any]) -> Conversation? {
        guard let roomId = row["room_id"] as? String,
              let peerId = row["peer_id"] as? String else {
            return nil
        }
        
        let peer = Conversation.Peer(
            userId: peerId,
            username: row["peer_username"] as? String ?? "",
            firstName: row["peer_first_name"] as? String,
            lastName: row["peer_last_name"] as? String,
            avatarPath: row["peer_avatar_path"] as? String,
            isVerified: (row["is_verified"] as? Int64 ?? 0) == 1
        )
        
        var lastMessage: Conversation.LastMessage?
        if let msgId = row["last_message_id"] as? String,
           let timestampStr = row["last_message_timestamp"] as? String,
           let timestamp = SharedDateFormatters.parseISO8601(timestampStr) {
            lastMessage = Conversation.LastMessage(
                id: msgId,
                content: row["last_message_content"] as? String,
                messageType: MessageType.from(name: row["last_message_type"] as? String ?? "text"),
                timestamp: timestamp,
                senderId: row["last_message_sender_id"] as? String ?? "",
                deliveryAuthority: DeliveryAuthority(rawValue: row["last_message_delivery_authority"] as? String ?? "server")
            )
        }
        
        let updatedAtStr = row["updated_at"] as? String ?? ""
        let updatedAt = SharedDateFormatters.parseISO8601(updatedAtStr) ?? Date()
        
        // Parse group fields
        let isGroup = (row["is_group"] as? Int64 ?? 0) == 1
        let isChannel = (row["is_channel"] as? Int64 ?? 0) == 1
        
        return Conversation(
            roomId: roomId,
            peer: peer,
            lastMessage: lastMessage,
            unreadCount: Int(row["unread_count"] as? Int64 ?? 0),
            isPinned: (row["is_pinned"] as? Int64 ?? 0) == 1,
            isMuted: (row["is_muted"] as? Int64 ?? 0) == 1,
            updatedAt: updatedAt,
            isGroup: isGroup,
            groupName: row["group_name"] as? String,
            groupAvatarUrl: row["group_avatar_url"] as? String,
            isChannel: isChannel,
            channelUsername: row["channel_username"] as? String,
            channelType: row["channel_type"] as? String,
            requestStatus: row["request_status"] as? String,
            isRequestSender: (row["is_request_sender"] as? Int64).map { $0 == 1 },
            pendingSentCount: (row["pending_sent_count"] as? Int64).map { Int($0) },
            requestId: row["request_id"] as? String
        )
    }
}

