import Foundation

// MARK: - Display State (Enum for DB compatibility)
enum DisplayState: Int, Codable {
    case hidden = 0
    case uploading = 1
    case ready = 2
    case failed = 3
    
    var stringValue: String {
        switch self {
        case .hidden: return "hidden"
        case .uploading: return "uploading"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }
    
    init?(stringValue: String) {
        switch stringValue {
        case "hidden": self = .hidden
        case "uploading": self = .uploading
        case "ready": self = .ready
        case "failed": self = .failed
        default: return nil
        }
    }
}

// MARK: - Message Repository
actor MessageRepository {
    static let shared = MessageRepository()
    
    private let db = DatabaseService.shared
    
    private init() {}
    
    // MARK: - Upsert (True Pattern: Insert-or-Ignore + Update)
    
    func upsert(_ message: ChatMessage) async throws {
        // CRITICAL: Ensure roomId is never nil
        let safeRoomId = message.roomId ?? message.senderId
        if message.roomId == nil {
            #if DEBUG
            print("⚠️ [MessageRepo] roomId was NIL! Using senderId as fallback: \(safeRoomId.prefix(8))")
            #endif
        }
        
        // Encode mention entities to JSON for persistence
        var entitiesJson: String? = nil
        if let entities = message.entities, !entities.isEmpty {
            if let data = try? JSONEncoder().encode(entities) {
                entitiesJson = String(data: data, encoding: .utf8)
            }
        }
        
        // Step 1: Insert-or-Ignore (idempotent)
        //
        // 🔴 ROUND 26 — Telegram-style media albums: three new
        // columns (media_group_key / _index / _total) bound to the
        // tail of the INSERT so existing param ordering is
        // unchanged for the older fields. Nil for single-media
        // messages; the chat surface treats nil-key rows as
        // standalone bubbles (the existing render path).
        let insertSQL = """
            INSERT OR IGNORE INTO messages (
                client_message_id, server_id, room_id, sender_id, sender_name, recipient_id,
                text, timestamp, type, status, delivery_authority, display_state,
                created_at, local_path, remote_url, thumbnail_url, file_name, mime_type,
                file_size, audio_duration_seconds, upload_progress, last_error,
                reply_to_message_id, reply_to_text_preview, reply_to_sender_name, reply_to_type,
                entities_json, forwarded_from_channel, forwarded_from_channel_name,
                media_group_key, media_group_index, media_group_total, expires_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        try await db.execute(insertSQL, params: [
            message.id,
            message.serverId ?? NSNull(),
            safeRoomId,  // Use safe roomId
            message.senderId,
            message.senderName,
            message.recipientId,
            message.text ?? NSNull(),
            SharedDateFormatters.formatISO8601(message.timestamp),
            message.type.rawValue,
            message.status.rawValue,
            message.deliveryAuthority.rawValue,
            message.currentDisplayState.rawValue,
            message.createdAt.map { SharedDateFormatters.formatISO8601($0) } ?? NSNull(),
            message.localPath ?? NSNull(),
            message.attachmentUrl ?? NSNull(),
            message.thumbnailUrl ?? NSNull(),
            message.fileName ?? NSNull(),
            message.mimeType ?? NSNull(),
            message.fileSize ?? NSNull(),
            message.audioDurationSeconds ?? NSNull(),
            message.uploadProgress ?? 0,
            message.lastError ?? NSNull(),
            message.replyToMessageId ?? NSNull(),
            message.replyToTextPreview ?? NSNull(),
            message.replyToSenderName ?? NSNull(),
            message.replyToType?.rawValue ?? NSNull(),
            entitiesJson ?? NSNull(),
            message.forwardedFromChannelId ?? NSNull(),
            message.forwardedFromChannelName ?? NSNull(),
            message.albumGroupKey ?? NSNull(),
            message.albumIndex ?? NSNull(),
            message.albumTotal ?? NSNull(),
            message.expiresAt.map { SharedDateFormatters.formatISO8601($0) } ?? NSNull()
        ])
        
        // Step 2: Update columns that might have new data
        let updateSQL = """
            UPDATE messages SET
                text = COALESCE(?, text),
                server_id = COALESCE(?, server_id),
                remote_url = COALESCE(?, remote_url),
                thumbnail_url = COALESCE(?, thumbnail_url),
                display_state = ?,
                status = ?,
                mime_type = COALESCE(?, mime_type),
                file_size = COALESCE(?, file_size),
                audio_duration_seconds = COALESCE(?, audio_duration_seconds),
                entities_json = COALESCE(?, entities_json),
                forwarded_from_channel = COALESCE(?, forwarded_from_channel),
                forwarded_from_channel_name = COALESCE(?, forwarded_from_channel_name),
                expires_at = COALESCE(?, expires_at),
                updated_at = CURRENT_TIMESTAMP
            WHERE client_message_id = ?
        """
        
        try await db.execute(updateSQL, params: [
            message.text ?? NSNull(),
            message.serverId ?? NSNull(),
            message.attachmentUrl ?? NSNull(),
            message.thumbnailUrl ?? NSNull(),
            message.currentDisplayState.rawValue,
            message.status.rawValue,
            message.mimeType ?? NSNull(),
            message.fileSize ?? NSNull(),
            message.audioDurationSeconds ?? NSNull(),
            entitiesJson ?? NSNull(),
            message.forwardedFromChannelId ?? NSNull(),
            message.forwardedFromChannelName ?? NSNull(),
            message.expiresAt.map { SharedDateFormatters.formatISO8601($0) } ?? NSNull(),
            message.id
        ])
    }
    
    // MARK: - Exists (Idempotency Check)
    
    func exists(clientMessageId: String) async -> Bool {
        do {
            return try await db.exists(
                "SELECT 1 FROM messages WHERE client_message_id = ? LIMIT 1",
                params: [clientMessageId]
            )
        } catch {
            return false
        }
    }
    
    /// Check if a message with this server_id already exists
    /// Used to prevent duplicate inserts when polling returns our own sent messages
    func existsByServerId(_ serverId: String) async -> Bool {
        do {
            return try await db.exists(
                "SELECT 1 FROM messages WHERE server_id = ? LIMIT 1",
                params: [serverId]
            )
        } catch {
            return false
        }
    }
    
    // MARK: - Batch Exists Check (Performance: 1 query instead of N)
    
    /// Check which server_ids already exist in a single SQL query.
    /// Returns the set of server_ids that are already stored.
    func batchExistsByServerIds(_ ids: [String]) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        let sql = "SELECT server_id FROM messages WHERE server_id IN (\(placeholders))"
        do {
            let rows = try await db.query(sql, params: ids)
            return Set(rows.compactMap { $0["server_id"] as? String })
        } catch {
            return []
        }
    }
    
    // MARK: - Batch Upsert (Performance: 1 transaction instead of N)
    
    /// Upsert multiple messages inside a single BEGIN/COMMIT transaction.
    /// Reduces disk I/O from N disk syncs down to 1, eliminating micro-stutters.
    func upsertBatch(_ messages: [ChatMessage]) async throws {
        guard !messages.isEmpty else { return }
        try await db.executeInTransaction { db in
            for message in messages {
                let safeRoomId = message.roomId ?? message.senderId
                
                // Encode mention entities to JSON for persistence
                var entitiesJson: String? = nil
                if let entities = message.entities, !entities.isEmpty {
                    if let data = try? JSONEncoder().encode(entities) {
                        entitiesJson = String(data: data, encoding: .utf8)
                    }
                }
                
                // Insert-or-Ignore
                let insertSQL = """
                    INSERT OR IGNORE INTO messages (
                        client_message_id, server_id, room_id, sender_id, sender_name, recipient_id,
                        text, timestamp, type, status, delivery_authority, display_state,
                        created_at, local_path, remote_url, thumbnail_url, file_name, mime_type,
                        file_size, audio_duration_seconds, upload_progress, last_error,
                        reply_to_message_id, reply_to_text_preview, reply_to_sender_name, reply_to_type,
                        entities_json, forwarded_from_channel, forwarded_from_channel_name,
                        media_group_key, media_group_index, media_group_total, expires_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
                
                try db.execute(insertSQL, params: [
                    message.id,
                    message.serverId ?? NSNull(),
                    safeRoomId,
                    message.senderId,
                    message.senderName,
                    message.recipientId,
                    message.text ?? NSNull(),
                    SharedDateFormatters.formatISO8601(message.timestamp),
                    message.type.rawValue,
                    message.status.rawValue,
                    message.deliveryAuthority.rawValue,
                    message.currentDisplayState.rawValue,
                    message.createdAt.map { SharedDateFormatters.formatISO8601($0) } ?? NSNull(),
                    message.localPath ?? NSNull(),
                    message.attachmentUrl ?? NSNull(),
                    message.thumbnailUrl ?? NSNull(),
                    message.fileName ?? NSNull(),
                    message.mimeType ?? NSNull(),
                    message.fileSize ?? NSNull(),
                    message.audioDurationSeconds ?? NSNull(),
                    message.uploadProgress ?? 0,
                    message.lastError ?? NSNull(),
                    message.replyToMessageId ?? NSNull(),
                    message.replyToTextPreview ?? NSNull(),
                    message.replyToSenderName ?? NSNull(),
                    message.replyToType?.rawValue ?? NSNull(),
                    entitiesJson ?? NSNull(),
                    message.forwardedFromChannelId ?? NSNull(),
                    message.forwardedFromChannelName ?? NSNull(),
                    message.albumGroupKey ?? NSNull(),
                    message.albumIndex ?? NSNull(),
                    message.albumTotal ?? NSNull(),
                    message.expiresAt.map { SharedDateFormatters.formatISO8601($0) } ?? NSNull()
                ])

                // Update columns that might have new data
                let updateSQL = """
                    UPDATE messages SET
                        text = COALESCE(?, text),
                        server_id = COALESCE(?, server_id),
                        remote_url = COALESCE(?, remote_url),
                        thumbnail_url = COALESCE(?, thumbnail_url),
                        display_state = ?,
                        status = ?,
                        mime_type = COALESCE(?, mime_type),
                        file_size = COALESCE(?, file_size),
                        audio_duration_seconds = COALESCE(?, audio_duration_seconds),
                        entities_json = COALESCE(?, entities_json),
                        forwarded_from_channel = COALESCE(?, forwarded_from_channel),
                        forwarded_from_channel_name = COALESCE(?, forwarded_from_channel_name),
                        expires_at = COALESCE(?, expires_at),
                        updated_at = CURRENT_TIMESTAMP
                    WHERE client_message_id = ?
                """
                
                try db.execute(updateSQL, params: [
                    message.text ?? NSNull(),
                    message.serverId ?? NSNull(),
                    message.attachmentUrl ?? NSNull(),
                    message.thumbnailUrl ?? NSNull(),
                    message.currentDisplayState.rawValue,
                    message.status.rawValue,
                    message.mimeType ?? NSNull(),
                    message.fileSize ?? NSNull(),
                    message.audioDurationSeconds ?? NSNull(),
                    entitiesJson ?? NSNull(),
                    message.forwardedFromChannelId ?? NSNull(),
                    message.forwardedFromChannelName ?? NSNull(),
                    message.expiresAt.map { SharedDateFormatters.formatISO8601($0) } ?? NSNull(),
                    message.id
                ])
            }
        }
        #if DEBUG
        print("✅ [MessageRepo] Batch upserted \(messages.count) messages in single transaction")
        #endif
    }
    
    // MARK: - Backfill Remote URL
    
    /// Backfill remote_url for an existing message that was stored without one.
    /// Handles the race where WebSocket/inbox delivers a message without audio URL,
    /// and the conversation poll later has the URL but skips the duplicate.
    func backfillRemoteUrl(serverId: String, remoteUrl: String, audioDuration: Int? = nil) async throws {
        var sql = """
            UPDATE messages SET
                remote_url = ?,
                updated_at = CURRENT_TIMESTAMP
        """
        var params: [Any] = [remoteUrl]
        
        if let dur = audioDuration {
            sql += ", audio_duration_seconds = COALESCE(audio_duration_seconds, ?)"
            params.append(dur)
        }
        
        sql += """
         WHERE (server_id = ? OR client_message_id = ?)
            AND (remote_url IS NULL OR remote_url = '')
        """
        params.append(serverId)
        params.append(serverId)
        
        try await db.execute(sql, params: params)
    }
    
    // MARK: - Update Display State (Atomic Attachment Pipeline)
    
    func updateDisplayState(
        clientMessageId: String,
        state: DisplayState,
        remoteUrl: String? = nil,
        thumbnailUrl: String? = nil,
        progress: Double? = nil,
        error: String? = nil
    ) async throws {
        var sql = "UPDATE messages SET display_state = ?, updated_at = CURRENT_TIMESTAMP"
        var params: [Any] = [state.rawValue]
        
        if let url = remoteUrl {
            sql += ", remote_url = ?"
            params.append(url)
        }
        if let thumb = thumbnailUrl {
            sql += ", thumbnail_url = ?"
            params.append(thumb)
        }
        if let progress = progress {
            sql += ", upload_progress = ?"
            params.append(progress)
        }
        if let error = error {
            sql += ", last_error = ?"
            params.append(error)
        }
        if state == .failed {
            sql += ", status = 'failed'"
        }
        
        sql += " WHERE client_message_id = ?"
        params.append(clientMessageId)
        
        try await db.execute(sql, params: params)
    }
    
    // MARK: - Update Attachment Size
    //
    // (2026-05-16 — round 9) Patch the file_size column after a video
    // has been compressed in place. Lets the chat bubble's "Video ·
    // 12.4 MB" caption read the post-compression value instead of
    // the original camera-roll size.
    func updateAttachmentSize(clientMessageId: String, fileSize: Int) async throws {
        try await db.execute(
            "UPDATE messages SET file_size = ?, updated_at = CURRENT_TIMESTAMP WHERE client_message_id = ?",
            params: [fileSize, clientMessageId]
        )
    }

    // MARK: - Update Server ID

    func updateServerId(clientMessageId: String, serverId: String) async throws {
        try await db.execute(
            "UPDATE messages SET server_id = ?, status = 'sent', sent_via_server = 1, updated_at = CURRENT_TIMESTAMP WHERE client_message_id = ?",
            params: [serverId, clientMessageId]
        )
    }
    
    // MARK: - Transport Path Markers
    
    /// Mark that message send was attempted via server path.
    func markSentViaServer(clientMessageId: String) async throws {
        try await db.execute(
            "UPDATE messages SET sent_via_server = 1, updated_at = CURRENT_TIMESTAMP WHERE client_message_id = ?",
            params: [clientMessageId]
        )
    }
    
    /// Mark that message send was attempted via mesh path.
    func markSentViaMesh(clientMessageId: String) async throws {
        try await db.execute(
            "UPDATE messages SET sent_via_mesh = 1, updated_at = CURRENT_TIMESTAMP WHERE client_message_id = ?",
            params: [clientMessageId]
        )
    }
    
    // MARK: - Re-key (offline group reconciliation)

    /// Move all messages from one room_id to another. Used when a locally-
    /// created group's server-assigned ID is finally received and the old
    /// `local_<UUID>` rows must be re-pointed at the canonical server ID.
    func remapRoomId(from oldRoomId: String, to newRoomId: String) async throws {
        guard oldRoomId != newRoomId else { return }
        try await db.execute(
            "UPDATE messages SET room_id = ? WHERE room_id = ?",
            params: [newRoomId, oldRoomId]
        )
    }

    // MARK: - Update Status

    func updateStatus(clientMessageId: String, status: MessageStatus) async throws {
        try await db.execute(
            "UPDATE messages SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE client_message_id = ?",
            params: [status.rawValue, clientMessageId]
        )
    }
    
    // MARK: - Update Text (Edit Message)
    
    /// Update message text and mark as edited (local-only for now).
    func updateText(clientMessageId: String, newText: String) async throws {
        try await db.execute(
            "UPDATE messages SET text = ?, edited_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE client_message_id = ?",
            params: [newText, clientMessageId]
        )
    }
    
    // MARK: - Mark Delivered/Read
    
    func markDelivered(clientMessageId: String, at: Date) async throws {
        try await db.execute(
            "UPDATE messages SET delivered_at = ?, status = 'delivered', updated_at = CURRENT_TIMESTAMP WHERE client_message_id = ?",
            params: [SharedDateFormatters.formatISO8601(at), clientMessageId]
        )
    }
    
    func markRead(clientMessageId: String, at: Date) async throws {
        try await db.execute(
            "UPDATE messages SET read_at = ?, status = 'read', updated_at = CURRENT_TIMESTAMP WHERE client_message_id = ?",
            params: [SharedDateFormatters.formatISO8601(at), clientMessageId]
        )
    }
    
    // MARK: - Get Messages for Room
    
    func getMessages(roomId: String, limit: Int = 50, before: Date? = nil) async throws -> [[String: Any]] {
        // Get current user ID for proper filtering
        let myId = await KeychainService.shared.getUserId() ?? ""
        
        // Query: Find messages where:
        // 1. room_id matches roomId (normalized case)
        // 2. OR sender/recipient pair matches this conversation (legacy/nil roomId case)
        // 3. NOT deleted for current user
        // 4. NOT deleted for everyone (global tombstone). deleteForEveryone /
        //    handleGlobalDeletion null the text and set is_deleted_globally = 1;
        //    without this predicate the text-less row would re-hydrate and render
        //    as an empty/blank bubble. Hiding it matches the nulled-text intent.
        //    The IS NULL branch keeps legacy / pre-migration rows visible.
        var sql = """
            SELECT * FROM messages WHERE
            (room_id = ? OR
             (sender_id = ? AND recipient_id = ?) OR
             (sender_id = ? AND recipient_id = ?))
            AND (is_deleted_for_me IS NULL OR is_deleted_for_me = 0)
            AND (is_deleted_globally IS NULL OR is_deleted_globally = 0)
        """
        var params: [Any] = [roomId, roomId, myId, myId, roomId]
        
        if let before = before {
            sql += " AND timestamp < ?"
            params.append(SharedDateFormatters.formatISO8601(before))
        }
        
        sql += " ORDER BY timestamp DESC LIMIT ?"
        params.append(limit)
        

        
        let results = try await db.query(sql, params: params)
        

        
        return results
    }
    
    // MARK: - Get Pending Messages (for OutboxManager sync)
    
    func getPendingMessages() async throws -> [[String: Any]] {
        return try await db.query(
            "SELECT * FROM messages WHERE status = 'pending' OR status = 'forwarding' ORDER BY timestamp ASC",
            params: []
        )
    }
    
    // MARK: - Get Pending Messages for Mesh (triggered on peer connection)
    
    /// Query pending messages that should be sent via mesh when a peer connects
    /// Optionally filter by recipient if we know who connected
    func getPendingForMesh(recipientId: String? = nil) async throws -> [[String: Any]] {
        let myId = await KeychainService.shared.getUserId() ?? ""
        
        // Query messages that are pending and were sent by us
        // If recipientId is provided, filter to messages for that specific peer
        let sql: String
        let params: [Any]
        
        if let recipientId = recipientId {
            sql = """
                SELECT * FROM messages 
                WHERE status IN ('pending', 'retry', 'forwarding')
                AND type IN ('text', 'location', 'system')
                AND sender_id = ?
                AND recipient_id = ?
                ORDER BY timestamp ASC
                LIMIT 50
            """
            params = [myId, recipientId]
        } else {
            // Get all pending outgoing messages
            sql = """
                SELECT * FROM messages 
                WHERE status IN ('pending', 'retry', 'forwarding')
                AND type IN ('text', 'location', 'system')
                AND sender_id = ?
                ORDER BY timestamp ASC
                LIMIT 50
            """
            params = [myId]
        }
        
        let results = try await db.query(sql, params: params)
        #if DEBUG
        print("📦 [MessageRepo] Found \(results.count) pending messages for mesh drain")
        #endif
        return results
    }
    
    /// Get a single message by client_message_id (for inventory resend)
    func getMessageByClientId(_ clientMessageId: String) async throws -> [[String: Any]] {
        return try await db.query(
            "SELECT * FROM messages WHERE client_message_id = ? LIMIT 1",
            params: [clientMessageId]
        )
    }
    
    // MARK: - Batch Update After Server Send (Performance Optimization)
    
    /// Combined update for server_id + status + delivery_authority in a single DB round-trip.
    /// Replaces 3 sequential calls: updateServerId + updateStatus + updateDeliveryAuthority.
    func updateAfterServerSend(
        clientMessageId: String,
        serverId: String,
        status: MessageStatus = .sent,
        authority: DeliveryAuthority = .server
    ) async throws {
        try await db.execute(
            """
            UPDATE messages SET
                server_id = ?,
                status = ?,
                delivery_authority = ?,
                sent_via_server = 1,
                updated_at = CURRENT_TIMESTAMP
            WHERE client_message_id = ?
            """,
            params: [serverId, status.rawValue, authority.rawValue, clientMessageId]
        )
    }
    
    // MARK: - Update Delivery Authority
    
    func updateDeliveryAuthority(clientMessageId: String, authority: DeliveryAuthority) async throws {
        try await db.execute(
            "UPDATE messages SET delivery_authority = ?, updated_at = CURRENT_TIMESTAMP WHERE client_message_id = ?",
            params: [authority.rawValue, clientMessageId]
        )
    }
    
    // MARK: - Get Mesh Delivered (for sync to server)
    
    /// Get messages that were delivered via mesh but not yet reported to server
    func getMeshDelivered() async throws -> [[String: Any]] {
        let myId = await KeychainService.shared.getUserId() ?? ""
        
        // Messages where:
        // - We are the recipient (we received via mesh)
        // - Status is delivered or read
        // - Delivery authority is mesh
        // - Not yet synced to server (we track this with a flag or just report all)
        let sql = """
            SELECT * FROM messages 
            WHERE recipient_id = ?
            AND status IN ('delivered', 'read')
            AND delivery_authority = 'mesh'
            ORDER BY timestamp DESC
            LIMIT 50
        """
        
        return try await db.query(sql, params: [myId])
    }
    
    // MARK: - Delete Methods
    
    /// Mark messages as deleted for current user only (soft delete)
    func deleteForMe(messageIds: [String]) async throws {
        guard !messageIds.isEmpty else { return }
        
        let placeholders = messageIds.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            UPDATE messages 
            SET is_deleted_for_me = 1, updated_at = CURRENT_TIMESTAMP
            WHERE client_message_id IN (\(placeholders))
        """
        
        try await db.execute(sql, params: messageIds)
        #if DEBUG
        print("🗑️ [MessageRepo] Deleted \(messageIds.count) messages for current user")
        #endif
    }
    
    /// Mark messages as deleted globally (for everyone)
    func deleteForEveryone(messageIds: [String]) async throws {
        guard !messageIds.isEmpty else { return }
        
        let placeholders = messageIds.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            UPDATE messages 
            SET is_deleted_globally = 1, text = NULL, updated_at = CURRENT_TIMESTAMP
            WHERE client_message_id IN (\(placeholders))
        """
        
        try await db.execute(sql, params: messageIds)
        #if DEBUG
        print("🗑️ [MessageRepo] Deleted \(messageIds.count) messages globally")
        #endif
    }
    
    /// Handle incoming global deletion event from WebSocket
    func handleGlobalDeletion(messageId: String) async throws {
        try await db.execute(
            "UPDATE messages SET is_deleted_globally = 1, text = NULL, updated_at = CURRENT_TIMESTAMP WHERE client_message_id = ? OR server_id = ?",
            params: [messageId, messageId]
        )
    }

    /// 🔴 v1.8 — hard-delete every locally-cached message whose
    /// disappearing-messages timer has elapsed. The server enforces
    /// the same expiry server-side; this sweep keeps the on-device
    /// SQLCipher cache consistent so an expired message is gone here
    /// too. Best-effort — callers ignore failures.
    ///
    /// 🔴 ROUND 70 (2026-05-23) — hacker-audit EPHEMERAL-CRIT-1
    /// (CRITICAL: ephemeral photo bytes survived "delete" forever).
    ///
    /// PREVIOUSLY this only ran `DELETE FROM messages …`. The cached
    /// media file at `Documents/attachments/<msgId>.<ext>` (written
    /// by MediaCacheService for every received image / video / voice
    /// / vault attachment) was NEVER unlinked. So a "disappearing"
    /// or "deleteAfterRead" or "ephemeralPhoto" message vanished
    /// from the chat UI but its plaintext bytes (or decryptable
    /// vault bytes) lived on disk indefinitely — recoverable via
    /// jailbreak, forensic tools, or a backup snapshot.
    ///
    /// FIX: SELECT local_path + attachment_url for soon-to-be-deleted
    /// rows BEFORE the DELETE, then unlink each file from disk after
    /// the row is gone. Failure to unlink is logged but does not
    /// roll back the DELETE — the row going away is the primary
    /// privacy guarantee; the file unlink is the secondary defense.
    func purgeExpiredMessages() async throws {
        let nowISO = SharedDateFormatters.formatISO8601(Date())
        // Snapshot the local file paths we need to unlink AFTER the
        // DB row goes away.
        let pathRows = (try? await db.query(
            """
            SELECT local_path, file_name, client_message_id, type, mime_type
              FROM messages
             WHERE expires_at IS NOT NULL AND expires_at <= ?
            """,
            params: [nowISO]
        )) ?? []

        // Build the list of files to nuke. Cover three patterns:
        //   1. `local_path` set explicitly (sender-side post-upload
        //      copies + receiver cached files written by
        //      MediaCacheService).
        //   2. The MediaCacheService synthesised name
        //      `<msgId>.<ext>` under attachments/ — for receive-only
        //      messages where the row may have lost its local_path
        //      after a reload but the cached file still lives in
        //      attachments/.
        var pathsToUnlink: [URL] = []
        let attachmentsDir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("attachments")
        for row in pathRows {
            if let local = row["local_path"] as? String, !local.isEmpty {
                pathsToUnlink.append(URL(fileURLWithPath: local))
                // Rebased path: MediaCacheService persists files with
                // last-path-component-only relative resolution.
                let basename = URL(fileURLWithPath: local).lastPathComponent
                pathsToUnlink.append(attachmentsDir.appendingPathComponent(basename))
            }
            // Synthesised MediaCacheService name `<msgId>.<ext>`.
            if let msgId = row["client_message_id"] as? String, !msgId.isEmpty {
                // Try every common ext we might have written.
                for ext in ["jpg", "jpeg", "png", "gif", "webp", "heic",
                            "m4a", "mp3", "wav", "aac", "mp4", "mov",
                            "pdf", "vlt", "bin"] {
                    pathsToUnlink.append(attachmentsDir.appendingPathComponent("\(msgId).\(ext)"))
                }
            }
        }

        // Now run the DELETE.
        try await db.execute(
            "DELETE FROM messages WHERE expires_at IS NOT NULL AND expires_at <= ?",
            params: [nowISO]
        )

        // Unlink files best-effort. Path may not exist — that's fine.
        let fm = FileManager.default
        for url in pathsToUnlink {
            if fm.fileExists(atPath: url.path) {
                do {
                    try fm.removeItem(at: url)
                    #if DEBUG
                    print("🧹 [MessageRepository] purged expired cached file at \(url.lastPathComponent)")
                    #endif
                } catch {
                    #if DEBUG
                    print("⚠️ [MessageRepository] failed to unlink expired cached file \(url.lastPathComponent): \(error.localizedDescription)")
                    #endif
                }
            }
        }
    }

    // MARK: - Pending Attachment Helpers (Duplicate Prevention)
    
    /// Check if there's a pending/sending attachment message of given type in this room
    /// Used to prevent duplicates when polling returns our message before we've stored server_id
    /// Find the client_message_id of a pending/sending attachment message of given type in this room
    /// Returns the clientMessageId if found, nil otherwise
    func findPendingAttachmentClientId(type: String, roomId: String, senderId: String) async -> String? {
        do {
            let rows = try await db.query(
                """
                SELECT client_message_id FROM messages 
                WHERE type = ? 
                AND room_id = ? 
                AND sender_id = ?
                AND server_id IS NULL
                AND status IN ('pending', 'sending', 'sent')
                ORDER BY timestamp DESC
                LIMIT 1
                """,
                params: [type, roomId, senderId]
            )
            return rows.first?["client_message_id"] as? String
        } catch {
            return nil
        }
    }
    
    /// Update a pending attachment message with server_id (links local message to server message)
    func updatePendingAttachmentServerId(
        clientMessageId: String,
        serverId: String,
        remoteUrl: String?
    ) async throws {
        var sql = """
            UPDATE messages SET 
                server_id = ?,
                status = 'sent',
                updated_at = CURRENT_TIMESTAMP
        """
        var params: [Any] = [serverId]
        
        if let url = remoteUrl {
            sql += ", remote_url = COALESCE(remote_url, ?)"
            params.append(url)
        }
        
        sql += """
            WHERE client_message_id = ?
            AND server_id IS NULL
        """
        params.append(clientMessageId)
        
        try await db.execute(sql, params: params)
        #if DEBUG
        print("✅ [MessageRepo] Linked pending message \\(clientMessageId.prefix(8)) to server_id: \\(serverId.prefix(8))")
        #endif
    }
    
    // MARK: - Pending Text Duplicate Prevention (Bug 6 fix)
    
    /// Find a pending text message by content, room, and sender.
    /// Used to prevent duplicate text messages when server response arrives after a disconnect.
    func findPendingTextClientId(content: String, roomId: String, senderId: String) async -> String? {
        do {
            let rows = try await db.query(
                """
                SELECT client_message_id FROM messages 
                WHERE type = 'text' AND text = ? AND room_id = ? AND sender_id = ?
                AND server_id IS NULL AND status IN ('pending', 'sending', 'sent')
                ORDER BY timestamp DESC LIMIT 1
                """,
                params: [content, roomId, senderId]
            )
            return rows.first?["client_message_id"] as? String
        } catch {
            return nil
        }
    }
    
    // MARK: - Update Local Path (Media Cache)
    
    /// Set local_path after background media download completes.
    /// Used by MediaCacheService to persist the cached file path.
    func updateLocalPath(clientMessageId: String, localPath: String) async throws {
        try await db.execute(
            "UPDATE messages SET local_path = ?, updated_at = CURRENT_TIMESTAMP WHERE client_message_id = ?",
            params: [localPath, clientMessageId]
        )
    }

    /// Mark a message's media download as failed so the chat row can
    /// surface a "tap to retry" affordance instead of an infinite
    /// loading spinner. Stores the failure reason in `last_error`
    /// for diagnostic visibility. 🟠 (2026-05-10).
    func markMediaDownloadFailed(clientMessageId: String, reason: String) async throws {
        try await db.execute(
            """
            UPDATE messages
            SET sync_state = 'failed_download',
                last_error = ?,
                updated_at = CURRENT_TIMESTAMP
            WHERE client_message_id = ?
            """,
            params: [reason, clientMessageId]
        )
    }
    
    // MARK: - Mark All Read In Room
    func markAllReadInRoom(roomId: String, myUserId: String) async throws {
        let sql = """
            UPDATE messages 
            SET status = 'read', read_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP 
            WHERE room_id = ? AND sender_id != ? AND status != 'read' AND type != 'ephemeral_photo'
        """
        try await db.execute(sql, params: [roomId, myUserId])
    }
}
