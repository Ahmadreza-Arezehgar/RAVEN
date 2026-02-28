// RAVEN - Database Service
// Converted from Flutter database_helper.dart to Swift
// Fixed for Swift 6 concurrency

import Foundation
import SQLite3

/// SQLite database service for local persistence
/// Using class instead of actor for simpler SQLite integration
final class DatabaseService: @unchecked Sendable {
    static let shared = DatabaseService()
    
    private var db: OpaquePointer?
    private let dbPath: String
    private let queue = DispatchQueue(label: "im.raven.database", qos: .userInitiated)
    
    private init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dbPath = documentsPath.appendingPathComponent("raven.db").path
        
        queue.sync {
            self.openDatabase()
            self.createTables()
        }
    }
    
    deinit {
        sqlite3_close(db)
    }
    
    // MARK: - Database Setup
    
    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("❌ [DB] Failed to open database")
        } else {
            print("✅ [DB] Database opened at: \(dbPath)")
        }
    }
    
    private func createTables() {
        let tables = [
            """
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                roomId TEXT NOT NULL,
                senderId TEXT NOT NULL,
                senderName TEXT NOT NULL,
                recipientId TEXT NOT NULL,
                text TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                via TEXT,
                status INTEGER DEFAULT 0,
                type INTEGER DEFAULT 0,
                ttl INTEGER DEFAULT 10,
                routePath TEXT,
                needsForwarding INTEGER DEFAULT 1,
                deliveredAt TEXT,
                readAt TEXT,
                messageSignature TEXT,
                sprayCounter INTEGER DEFAULT 5,
                originDeviceId TEXT,
                hopCount INTEGER DEFAULT 0,
                hopLimit INTEGER DEFAULT 10,
                deliveryAuthority INTEGER DEFAULT 0,
                audioUrl TEXT,
                imageUrl TEXT,
                fileName TEXT,
                mimeType TEXT,
                fileSize INTEGER,
                thumbnailUrl TEXT,
                audioDuration REAL,
                transcriptText TEXT,
                transcriptLang TEXT,
                transcriptStatus INTEGER DEFAULT 0,
                serverId TEXT,
                syncState INTEGER DEFAULT 0,
                localPath TEXT,
                retryCount INTEGER DEFAULT 0,
                lastError TEXT,
                replyToMessageId TEXT,
                replyToText TEXT,
                replyToSenderName TEXT,
                replyToType INTEGER,
                isLiked INTEGER DEFAULT 0,
                sendMode TEXT DEFAULT 'instant',
                scheduledAtUtc TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY,
                recipientId TEXT NOT NULL,
                recipientName TEXT NOT NULL,
                recipientUsername TEXT NOT NULL,
                recipientAvatarUrl TEXT,
                lastMessage TEXT,
                lastMessageType INTEGER DEFAULT 0,
                lastMessageTime TEXT,
                unreadCount INTEGER DEFAULT 0,
                isOnline INTEGER DEFAULT 0,
                isMuted INTEGER DEFAULT 0,
                isPinned INTEGER DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS contacts (
                id TEXT PRIMARY KEY,
                userId TEXT NOT NULL UNIQUE,
                nickname TEXT,
                username TEXT NOT NULL,
                displayName TEXT NOT NULL,
                avatarUrl TEXT,
                publicKey TEXT,
                isBlocked INTEGER DEFAULT 0,
                isFavorite INTEGER DEFAULT 0,
                addedAt TEXT NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_messages_roomId ON messages(roomId)",
            "CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages(timestamp DESC)",
            "CREATE INDEX IF NOT EXISTS idx_conversations_lastMessageTime ON conversations(lastMessageTime DESC)"
        ]
        
        for sql in tables {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
        
        print("✅ [DB] Tables created")
    }
    
    // MARK: - Helper for binding text
    
    private func bindText(_ statement: OpaquePointer?, index: Int32, value: String?) {
        if let value = value {
            value.withCString { cString in
                sqlite3_bind_text(statement, index, cString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
    
    // MARK: - Messages
    
    func insertMessage(_ message: ChatMessage) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let sql = """
                INSERT OR REPLACE INTO messages (
                    id, roomId, senderId, senderName, recipientId, text, timestamp, via, status, type,
                    ttl, routePath, needsForwarding, deliveredAt, readAt, messageSignature, sprayCounter,
                    originDeviceId, hopCount, hopLimit, deliveryAuthority, audioUrl, imageUrl, fileName, mimeType,
                    fileSize, thumbnailUrl, audioDuration, transcriptText, transcriptLang,
                    transcriptStatus, serverId, syncState, localPath, retryCount, lastError,
                    replyToMessageId, replyToText, replyToSenderName, replyToType, isLiked,
                    sendMode, scheduledAtUtc
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
            
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            
            let formatter = ISO8601DateFormatter()
            
            self.bindText(statement, index: 1, value: message.id)
            self.bindText(statement, index: 2, value: message.roomId)
            self.bindText(statement, index: 3, value: message.senderId)
            self.bindText(statement, index: 4, value: message.senderName)
            self.bindText(statement, index: 5, value: message.recipientId)
            self.bindText(statement, index: 6, value: message.text)
            self.bindText(statement, index: 7, value: formatter.string(from: message.timestamp))
            self.bindText(statement, index: 8, value: message.via)
            sqlite3_bind_int(statement, 9, Int32(message.status.rawValue))
            sqlite3_bind_int(statement, 10, Int32(message.type.rawValue))
            sqlite3_bind_int(statement, 11, Int32(message.ttl))
            self.bindText(statement, index: 12, value: message.routePath.joined(separator: ","))
            sqlite3_bind_int(statement, 13, message.needsForwarding ? 1 : 0)
            self.bindText(statement, index: 14, value: message.deliveredAt.map { formatter.string(from: $0) })
            self.bindText(statement, index: 15, value: message.readAt.map { formatter.string(from: $0) })
            self.bindText(statement, index: 16, value: message.messageSignature)
            sqlite3_bind_int(statement, 17, Int32(message.sprayCounter))
            self.bindText(statement, index: 18, value: message.originDeviceId)
            sqlite3_bind_int(statement, 19, Int32(message.hopCount))
            sqlite3_bind_int(statement, 20, Int32(message.hopLimit))
            sqlite3_bind_int(statement, 21, Int32(message.deliveryAuthority.rawValue))
            self.bindText(statement, index: 22, value: message.audioUrl)
            self.bindText(statement, index: 23, value: message.imageUrl)
            self.bindText(statement, index: 24, value: message.fileName)
            self.bindText(statement, index: 25, value: message.mimeType)
            if let size = message.fileSize { sqlite3_bind_int(statement, 26, Int32(size)) } else { sqlite3_bind_null(statement, 26) }
            self.bindText(statement, index: 27, value: message.thumbnailUrl)
            if let duration = message.audioDuration { sqlite3_bind_double(statement, 28, duration) } else { sqlite3_bind_null(statement, 28) }
            self.bindText(statement, index: 29, value: message.transcriptText)
            self.bindText(statement, index: 30, value: message.transcriptLang)
            sqlite3_bind_int(statement, 31, Int32(message.transcriptStatus))
            self.bindText(statement, index: 32, value: message.serverId)
            sqlite3_bind_int(statement, 33, Int32(message.syncState.rawValue))
            self.bindText(statement, index: 34, value: message.localPath)
            sqlite3_bind_int(statement, 35, Int32(message.retryCount))
            self.bindText(statement, index: 36, value: message.lastError)
            self.bindText(statement, index: 37, value: message.replyToMessageId)
            self.bindText(statement, index: 38, value: message.replyToText)
            self.bindText(statement, index: 39, value: message.replyToSenderName)
            if let replyType = message.replyToType { sqlite3_bind_int(statement, 40, Int32(replyType.rawValue)) } else { sqlite3_bind_null(statement, 40) }
            sqlite3_bind_int(statement, 41, message.isLiked ? 1 : 0)
            self.bindText(statement, index: 42, value: message.sendMode)
            self.bindText(statement, index: 43, value: message.scheduledAtUtc.map { formatter.string(from: $0) })
            
            sqlite3_step(statement)
        }
    }
    
    // MARK: - Pending Queue Management
    
    func getPendingMessages() async -> [ChatMessage] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: [])
                    return
                }
                
                // Fetch messages with syncState = queued (1) or failed (4)
                let sql = "SELECT * FROM messages WHERE syncState IN (1, 4) ORDER BY timestamp ASC"
                var messages: [ChatMessage] = []
                
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK {
                    while sqlite3_step(statement) == SQLITE_ROW {
                        if let message = self.parseMessage(statement) {
                            messages.append(message)
                        }
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: messages)
            }
        }
    }
    
    func getMessages(roomId: String, limit: Int = 50) async -> [ChatMessage] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: [])
                    return
                }
                
                let sql = "SELECT * FROM messages WHERE roomId = ? ORDER BY timestamp DESC LIMIT ?"
                var messages: [ChatMessage] = []
                
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                    continuation.resume(returning: [])
                    return
                }
                defer { sqlite3_finalize(statement) }
                
                roomId.withCString { cString in
                    sqlite3_bind_text(statement, 1, cString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                sqlite3_bind_int(statement, 2, Int32(limit))
                
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let message = self.parseMessage(statement) {
                        messages.append(message)
                    }
                }
                
                continuation.resume(returning: messages.reversed())
            }
        }
    }
    
    private func parseMessage(_ statement: OpaquePointer?) -> ChatMessage? {
        guard let statement = statement else { return nil }
        let formatter = ISO8601DateFormatter()
        
        func getString(_ col: Int32) -> String {
            if let cStr = sqlite3_column_text(statement, col) {
                return String(cString: cStr)
            }
            return ""
        }
        
        func getOptString(_ col: Int32) -> String? {
            if sqlite3_column_type(statement, col) == SQLITE_NULL { return nil }
            if let cStr = sqlite3_column_text(statement, col) {
                return String(cString: cStr)
            }
            return nil
        }
        
        func getInt(_ col: Int32) -> Int {
            Int(sqlite3_column_int(statement, col))
        }
        
        func getOptInt(_ col: Int32) -> Int? {
            sqlite3_column_type(statement, col) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, col))
        }
        
        func getOptDouble(_ col: Int32) -> Double? {
            sqlite3_column_type(statement, col) == SQLITE_NULL ? nil : sqlite3_column_double(statement, col)
        }
        
        return ChatMessage(
            id: getString(0),
            roomId: getString(1),
            senderId: getString(2),
            senderName: getString(3),
            recipientId: getString(4),
            text: getString(5),
            timestamp: formatter.date(from: getString(6)) ?? Date(),
            via: getOptString(7) ?? "server",
            status: MessageStatus(rawValue: getInt(8)) ?? .pending,
            type: MessageType(rawValue: getInt(9)) ?? .text,
            ttl: getInt(10),
            routePath: getString(11).components(separatedBy: ",").filter { !$0.isEmpty },
            needsForwarding: getInt(12) == 1,
            deliveredAt: getOptString(13).flatMap { formatter.date(from: $0) },
            readAt: getOptString(14).flatMap { formatter.date(from: $0) },
            messageSignature: getOptString(15),
            sprayCounter: getInt(16),
            originDeviceId: getOptString(17),
            hopCount: getInt(18),
            hopLimit: getInt(19),
            deliveryAuthority: DeliveryAuthority(rawValue: getInt(20)) ?? .server,
            audioUrl: getOptString(21),
            imageUrl: getOptString(22),
            fileName: getOptString(23),
            mimeType: getOptString(24),
            fileSize: getOptInt(25),
            thumbnailUrl: getOptString(26),
            audioDuration: getOptDouble(27),
            transcriptText: getOptString(28),
            transcriptLang: getOptString(29),
            transcriptStatus: getInt(30),
            serverId: getOptString(31),
            syncState: SyncState(rawValue: getInt(32)) ?? .localOnly,
            localPath: getOptString(33),
            retryCount: getInt(34),
            lastError: getOptString(35),
            replyToMessageId: getOptString(36),
            replyToText: getOptString(37),
            replyToSenderName: getOptString(38),
            replyToType: getOptInt(39).flatMap { MessageType(rawValue: $0) },
            isLiked: getInt(40) == 1,
            sendMode: getOptString(41),
            scheduledAtUtc: getOptString(42).flatMap { formatter.date(from: $0) }
        )
    }
    
    // MARK: - Conversations
    
    func insertConversation(_ conversation: Conversation) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let sql = """
                INSERT OR REPLACE INTO conversations (
                    id, recipientId, recipientName, recipientUsername, recipientAvatarUrl,
                    lastMessage, lastMessageType, lastMessageTime, unreadCount, isOnline, isMuted, isPinned
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """
            
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            
            let formatter = ISO8601DateFormatter()
            
            self.bindText(statement, index: 1, value: conversation.id)
            self.bindText(statement, index: 2, value: conversation.recipientId)
            self.bindText(statement, index: 3, value: conversation.recipientName)
            self.bindText(statement, index: 4, value: conversation.recipientUsername)
            self.bindText(statement, index: 5, value: conversation.recipientAvatarUrl)
            self.bindText(statement, index: 6, value: conversation.lastMessage)
            sqlite3_bind_int(statement, 7, Int32(conversation.lastMessageType.rawValue))
            self.bindText(statement, index: 8, value: formatter.string(from: conversation.lastMessageTime))
            sqlite3_bind_int(statement, 9, Int32(conversation.unreadCount))
            sqlite3_bind_int(statement, 10, conversation.isOnline ? 1 : 0)
            sqlite3_bind_int(statement, 11, conversation.isMuted ? 1 : 0)
            sqlite3_bind_int(statement, 12, conversation.isPinned ? 1 : 0)
            
            sqlite3_step(statement)
        }
    }
    
    func getAllConversations() async -> [Conversation] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: [])
                    return
                }
                
                let sql = "SELECT * FROM conversations ORDER BY isPinned DESC, lastMessageTime DESC"
                var conversations: [Conversation] = []
                
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                    continuation.resume(returning: [])
                    return
                }
                defer { sqlite3_finalize(statement) }
                
                let formatter = ISO8601DateFormatter()
                
                while sqlite3_step(statement) == SQLITE_ROW {
                    func getString(_ col: Int32) -> String {
                        if let cStr = sqlite3_column_text(statement, col) {
                            return String(cString: cStr)
                        }
                        return ""
                    }
                    
                    func getOptString(_ col: Int32) -> String? {
                        if sqlite3_column_type(statement, col) == SQLITE_NULL { return nil }
                        if let cStr = sqlite3_column_text(statement, col) {
                            return String(cString: cStr)
                        }
                        return nil
                    }
                    
                    conversations.append(Conversation(
                        id: getString(0),
                        recipientId: getString(1),
                        recipientName: getString(2),
                        recipientUsername: getString(3),
                        recipientAvatarUrl: getOptString(4),
                        lastMessage: getString(5),
                        lastMessageType: MessageType(rawValue: Int(sqlite3_column_int(statement, 6))) ?? .text,
                        lastMessageTime: formatter.date(from: getString(7)) ?? Date(),
                        unreadCount: Int(sqlite3_column_int(statement, 8)),
                        isOnline: sqlite3_column_int(statement, 9) == 1,
                        isMuted: sqlite3_column_int(statement, 10) == 1,
                        isPinned: sqlite3_column_int(statement, 11) == 1
                    ))
                }
                
                continuation.resume(returning: conversations)
            }
        }
    }
    
    // MARK: - Contacts
    
    func insertContact(_ contact: Contact) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let sql = """
                INSERT OR REPLACE INTO contacts (
                    id, userId, nickname, username, displayName, avatarUrl, publicKey, isBlocked, isFavorite, addedAt
                ) VALUES (?,?,?,?,?,?,?,?,?,?)
            """
            
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            
            let formatter = ISO8601DateFormatter()
            
            self.bindText(statement, index: 1, value: contact.id)
            self.bindText(statement, index: 2, value: contact.userId)
            self.bindText(statement, index: 3, value: contact.nickname)
            self.bindText(statement, index: 4, value: contact.username)
            self.bindText(statement, index: 5, value: contact.displayName)
            self.bindText(statement, index: 6, value: contact.avatarUrl)
            self.bindText(statement, index: 7, value: contact.publicKey)
            sqlite3_bind_int(statement, 8, contact.isBlocked ? 1 : 0)
            sqlite3_bind_int(statement, 9, contact.isFavorite ? 1 : 0)
            self.bindText(statement, index: 10, value: formatter.string(from: contact.addedAt))
            
            sqlite3_step(statement)
        }
    }
    
    func getAllContacts() async -> [Contact] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: [])
                    return
                }
                
                let sql = "SELECT * FROM contacts ORDER BY isBlocked ASC, isFavorite DESC, displayName ASC"
                var contacts: [Contact] = []
                
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                    continuation.resume(returning: [])
                    return
                }
                defer { sqlite3_finalize(statement) }
                
                let formatter = ISO8601DateFormatter()
                
                while sqlite3_step(statement) == SQLITE_ROW {
                    func getString(_ col: Int32) -> String {
                        if let cStr = sqlite3_column_text(statement, col) {
                            return String(cString: cStr)
                        }
                        return ""
                    }
                    
                    func getOptString(_ col: Int32) -> String? {
                        if sqlite3_column_type(statement, col) == SQLITE_NULL { return nil }
                        if let cStr = sqlite3_column_text(statement, col) {
                            return String(cString: cStr)
                        }
                        return nil
                    }
                    
                    contacts.append(Contact(
                        id: getString(0),
                        userId: getString(1),
                        nickname: getOptString(2),
                        username: getString(3),
                        displayName: getString(4),
                        avatarUrl: getOptString(5),
                        publicKey: getOptString(6),
                        isBlocked: sqlite3_column_int(statement, 7) == 1,
                        isFavorite: sqlite3_column_int(statement, 8) == 1,
                        addedAt: formatter.date(from: getString(9)) ?? Date()
                    ))
                }
                
                continuation.resume(returning: contacts)
            }
        }
    }
    
    // MARK: - Cleanup
    
    func deleteAllData() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let tables = ["messages", "conversations", "contacts"]
            for table in tables {
                var statement: OpaquePointer?
                let sql = "DELETE FROM \(table)"
                if sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_step(statement)
                }
                sqlite3_finalize(statement)
            }
            print("✅ [DB] All data deleted")
        }
    }
}
