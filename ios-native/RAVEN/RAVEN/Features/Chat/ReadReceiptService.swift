import Foundation

// MARK: - Read Receipt Service (API + Offline Queue)

/// Handles sending and receiving read receipts for group messages.
/// Tracks which messages have already been marked as seen locally to avoid duplicate API calls.
@Observable
class ReadReceiptService {
    static let shared = ReadReceiptService()
    
    /// Set of messageIds we've already sent a seen event for (prevents duplicate API calls)
    private var sentSeenIds = Set<String>()
    
    /// Pending seen events to send when network becomes available
    private var pendingSeenEvents: [(messageId: String, chatId: String)] = []
    
    private init() {
        // Observe network changes to flush pending events
        NotificationCenter.default.addObserver(
            forName: .networkStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard NetworkMonitor.shared.isOnline else { return }
            Task { await self?.flushPendingEvents() }
        }
    }
    
    // MARK: - Send Seen Event
    
    /// Mark a message as seen by the current user. Idempotent — skips if already sent.
    func sendSeen(messageId: String, chatId: String) async {
        // Skip if already sent this session
        guard !sentSeenIds.contains(messageId) else { return }
        
        // Ghost Mode: suppress read receipts for premium users
        if PremiumLimits.ghostModeEnabled { return }
        
        sentSeenIds.insert(messageId)
        
        // Store locally immediately (optimistic)
        await storeLocalSeen(messageId: messageId)
        
        // Send to server
        guard NetworkMonitor.shared.isOnline else {
            pendingSeenEvents.append((messageId: messageId, chatId: chatId))
            #if DEBUG
            print("📥 [ReadReceipt] Queued seen event (offline): \(messageId.prefix(8))")
            #endif
            return
        }
        
        await sendToServer(messageId: messageId, chatId: chatId)
    }
    
    /// Batch-send seen events for multiple messages at once
    func sendSeenBatch(messageIds: [String], chatId: String) async {
        for messageId in messageIds {
            await sendSeen(messageId: messageId, chatId: chatId)
        }
    }
    
    // MARK: - Private Helpers
    
    private func storeLocalSeen(messageId: String) async {
        guard let userId = await KeychainService.shared.getUserId(),
              let username = AuthService.shared.currentUser?.username else { return }
        let avatarUrl = AuthService.shared.currentUser?.avatarPath
        
        do {
            try await ReadReceiptRepository.shared.markSeen(
                messageId: messageId,
                userId: userId,
                username: username,
                avatarUrl: avatarUrl,
                seenAt: Date()
            )
        } catch {
            #if DEBUG
            print("❌ [ReadReceipt] Failed to store local seen: \(error)")
            #endif
        }
    }
    
    private func sendToServer(messageId: String, chatId: String) async {
        do {
            let body = MessageSeenRequest(messageId: messageId)
            let _: Empty = try await NetworkService.shared.post(
                path: "/api/groups/\(chatId)/messages/\(messageId)/seen",
                body: body,
                idempotencyKey: "seen-\(messageId)"
            )
            #if DEBUG
            print("✅ [ReadReceipt] Sent seen: \(messageId.prefix(8))")
            #endif
        } catch {
            // Non-critical — don't crash, just log
            #if DEBUG
            print("⚠️ [ReadReceipt] Failed to send seen to server: \(error.localizedDescription)")
            #endif
        }
    }
    
    private func flushPendingEvents() async {
        guard !pendingSeenEvents.isEmpty else { return }
        let events = pendingSeenEvents
        pendingSeenEvents.removeAll()
        
        #if DEBUG
        print("🔄 [ReadReceipt] Flushing \(events.count) pending seen events")
        #endif
        for event in events {
            await sendToServer(messageId: event.messageId, chatId: event.chatId)
        }
    }
}

// MARK: - API Models

struct MessageSeenRequest: Encodable {
    let messageId: String
}

/// WebSocket event for a message being seen by another user
struct MessageSeenEvent: Codable {
    let type: String  // "message_seen"
    let messageId: String
    let chatId: String
    let seenByUserId: String
    let seenByUsername: String
    let seenByAvatarUrl: String?
    let seenAt: Date
}

/// Wrapper for WebSocket events that can be message_seen
struct WebSocketEvent: Codable {
    let type: String
}
