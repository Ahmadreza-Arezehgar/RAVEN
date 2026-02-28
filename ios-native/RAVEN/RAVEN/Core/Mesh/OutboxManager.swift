import Foundation

// MARK: - Outbox Manager (DTN Offline-First Queue)
/// Central manager for pending message queue - implements "Golden Rule": No message should be lost
/// Messages are stored locally FIRST, then sent via best available transport

@Observable
class OutboxManager {
    static let shared = OutboxManager()
    
    private var syncTimer: Timer?
    private var isProcessing = false
    private let messageRepo = MessageRepository.shared
    private let net: any NetworkStatusProviding
    
    init(net: any NetworkStatusProviding = NetworkMonitor.shared) {
        self.net = net
        setupNetworkObserver()
    }
    
    // MARK: - Network State Observer
    
    private func setupNetworkObserver() {
        // Watch for network changes
        NotificationCenter.default.addObserver(
            forName: .networkStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.net.isOnline {
                #if DEBUG
                print("🌐 [OutboxManager] Network back online - syncing pending messages")
                #endif
                Task {
                    await self.syncPendingMessages()
                }
            }
        }
    }
    
    // MARK: - Queue Message for Sending
    
    /// Called immediately after inserting message to DB
    /// Attempts to send via best available transport
    func enqueue(_ message: ChatMessage) async {
        #if DEBUG
        print("📦 [OutboxManager] Enqueueing message: \(message.id)")
        #endif
        
        // ✅ Bug 8 fix: DeliveryJobRunner now handles all network delivery.
        // Previously both OutboxManager AND DeliveryJobRunner would send
        // messages on reconnect, causing every file/image to upload TWICE
        // (doubling bandwidth, triggering 429 errors, and heating the device).
        // OutboxManager now only persists to local outbox for tracking.
        await markAsQueued(message)
    }
    
    // MARK: - Transport: Server (Primary)
    
    private func sendViaServer(_ message: ChatMessage) async {
        do {
            try await messageRepo.updateStatus(clientMessageId: message.id, status: .sending)
            
            // Detect group messages via DB lookup (pattern matching fails in mesh scenarios)
            let isGroup: Bool
            if let roomId = message.roomId {
                isGroup = (try? await DatabaseService.shared.exists(
                    "SELECT 1 FROM conversations WHERE room_id = ? AND (is_group = 1 OR is_channel = 1) LIMIT 1",
                    params: [roomId]
                )) ?? false
            } else {
                isGroup = false
            }
            
            if isGroup, let roomId = message.roomId {
                // Group message: use group endpoint
                let response: GroupMessageResponse = try await NetworkService.shared.post(
                    path: "/api/groups/\(roomId)/messages",
                    body: SendGroupMessageRequest(
                        messageId: message.id,
                        content: message.text ?? "",
                        messageType: message.type.rawValue,
                        audioUrl: message.attachmentUrl,
                        replyToMessageId: message.replyToMessageId,
                        replyToTextPreview: message.replyToTextPreview,
                        replyToSenderName: message.replyToSenderName,
                        replyToType: message.replyToType?.rawValue
                    ),
                    idempotencyKey: message.id
                )
                
                try await messageRepo.updateServerId(clientMessageId: message.id, serverId: response.id)
                try await messageRepo.updateDeliveryAuthority(clientMessageId: message.id, authority: .server)
                #if DEBUG
                print("✅ [OutboxManager] Group message sent via server: \(message.id)")
                #endif
            } else {
                // 1:1 message: use regular endpoint
                let response: SendMessageResponse = try await NetworkService.shared.post(
                    path: "/api/messages/send",
                    body: SendMessageRequest(
                        messageId: message.id,
                        recipientId: message.recipientId,
                        content: message.text ?? "",
                        messageType: message.type.rawValue,
                        audioUrl: message.attachmentUrl,
                        replyToMessageId: message.replyToMessageId
                    ),
                    idempotencyKey: message.id  // Duplicate prevention
                )
                
                try await messageRepo.updateServerId(clientMessageId: message.id, serverId: response.id)
                try await messageRepo.updateDeliveryAuthority(clientMessageId: message.id, authority: .server)
                #if DEBUG
                print("✅ [OutboxManager] Message sent via server: \(message.id)")
                #endif
            }
            
        } catch {
            #if DEBUG
            print("❌ [OutboxManager] Server send failed: \(error)")
            #endif
            // Mark as queued for retry
            await markAsQueued(message)
        }
    }
    
    // MARK: - Mark as Queued (for later sync)
    
    private func markAsQueued(_ message: ChatMessage) async {
        try? await messageRepo.updateStatus(clientMessageId: message.id, status: .pending)
        try? await messageRepo.updateDeliveryAuthority(clientMessageId: message.id, authority: .mesh)
    }
    
    // MARK: - Sync Pending Messages (on network reconnect)
    
    func syncPendingMessages() async {
        // ✅ Bug 8 fix: All network retry is now handled by DeliveryJobRunner.
        // This method is kept as a no-op for backward compatibility.
        #if DEBUG
        print("📦 [OutboxManager] Sync delegated to DeliveryJobRunner")
        #endif
    }
    
    // MARK: - Parse Message from DB Row
    
    private func parseMessage(from row: [String: Any]) -> ChatMessage? {
        guard let id = row["client_message_id"] as? String,
              let senderId = row["sender_id"] as? String,
              let recipientId = row["recipient_id"] as? String,
              let timestampStr = row["timestamp"] as? String,
              let timestamp = PerformanceConstants.iso8601.date(from: timestampStr) else {
            return nil
        }
        
        let typeStr = row["type"] as? String ?? "text"
        let type = MessageType.from(name: typeStr)
        
        return ChatMessage(
            id: id,
            serverId: row["server_id"] as? String,
            roomId: row["room_id"] as? String,
            senderId: senderId,
            senderName: row["sender_name"] as? String ?? "",
            recipientId: recipientId,
            text: row["text"] as? String,
            timestamp: timestamp,
            type: type,
            status: .pending,
            deliveryAuthority: .mesh,
            createdAt: nil,
            deliveredAt: nil,
            readAt: nil,
            hopCount: 0,
            routePath: [],
            sprayCounter: PremiumLimits.meshSprayBudget,
            hopLimit: PremiumLimits.meshHopLimit,
            originDeviceId: "",
            needsForwarding: false,
            attachmentUrl: row["remote_url"] as? String,
            thumbnailUrl: nil,
            fileName: row["file_name"] as? String,
            mimeType: row["mime_type"] as? String,
            fileSize: (row["file_size"] as? Int64).map { Int($0) },
            audioDurationSeconds: (row["audio_duration_seconds"] as? Int64).map { Int($0) },
            syncState: .queued,
            localPath: nil,
            uploadProgress: nil,
            lastError: nil,
            replyToMessageId: row["reply_to_message_id"] as? String,
            replyToTextPreview: nil,
            replyToSenderName: nil,
            replyToType: nil,
            sendMode: nil,
            scheduledAtUtc: nil
        )
    }
}
// NOTE: SendMessageRequest and SendMessageResponse are defined in MessageStore.swift
