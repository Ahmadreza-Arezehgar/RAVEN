import Foundation
import Combine

// MARK: - Read Receipt Store (Per-room seen-by state)

/// Observable store that tracks which users have seen each message in a group chat.
/// Lives as @State in ChatView and provides data to SeenByAvatarsView.
@MainActor
@Observable
class ReadReceiptStore {
    /// Dictionary of messageId → [SeenByUser], keyed by message client_message_id
    var seenByMessage: [String: [SeenByUser]] = [:]
    
    private var seenObserver: NSObjectProtocol?
    private var roomId: String = ""
    
    // MARK: - Load
    
    /// Batch-load seen-by data for all messages currently visible in the room
    func loadForMessages(messageIds: [String]) async {
        guard !messageIds.isEmpty else { return }
        
        do {
            let results = try await ReadReceiptRepository.shared.getSeenByBatch(messageIds: messageIds)
            // Merge with existing data (don't overwrite if WebSocket already delivered newer data)
            for (msgId, users) in results {
                seenByMessage[msgId] = users
            }
        } catch {
            #if DEBUG
            print("❌ [ReadReceiptStore] Failed to load seen-by data: \(error)")
            #endif
        }
    }
    
    /// Load seen-by for a single message (used when sheet is opened)
    func loadForMessage(messageId: String) async -> [SeenByUser] {
        do {
            let users = try await ReadReceiptRepository.shared.getSeenBy(messageId: messageId)
            seenByMessage[messageId] = users
            return users
        } catch {
            #if DEBUG
            print("❌ [ReadReceiptStore] Failed to load seen-by for \(messageId.prefix(8)): \(error)")
            #endif
            return seenByMessage[messageId] ?? []
        }
    }
    
    // MARK: - Observers
    
    /// Listen for real-time seen updates from WebSocket
    func setupObservers(roomId: String) {
        self.roomId = roomId
        guard seenObserver == nil else { return }
        
        seenObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("MessageSeenUpdated"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let msgId = notification.userInfo?["messageId"] as? String else { return }
            
            // Reload this specific message's seen-by data
            Task { @MainActor in
                _ = await self.loadForMessage(messageId: msgId)
            }
        }
    }
    
    /// Remove observers on disappear
    func removeObservers() {
        if let obs = seenObserver {
            NotificationCenter.default.removeObserver(obs)
            seenObserver = nil
        }
    }
    
    // MARK: - Convenience
    
    /// Get seen-by users for a message (excludes current user)
    func seenBy(for messageId: String) -> [SeenByUser] {
        let currentUserId = AuthService.shared.currentUser?.id ?? ""
        return (seenByMessage[messageId] ?? []).filter { $0.userId != currentUserId }
    }
}
