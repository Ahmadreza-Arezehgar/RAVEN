// RAVEN - Sync Service
// Converted from Flutter sync_service.dart

import Foundation
import Combine
import BackgroundTasks

/// Handles synchronization between local database and server
actor SyncService {
    static let shared = SyncService()
    
    private var isSyncing = false
    private var lastSyncTime: Date?
    private let syncInterval: TimeInterval = 30.0  // 30 seconds
    private var syncTimer: Timer?
    
    private init() {}
    
    // MARK: - Background Task Registration
    
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "im.raven.sync", using: nil) { task in
            self.handleBackgroundSync(task: task as! BGAppRefreshTask)
        }
    }
    
    func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: "im.raven.sync")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 min
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("✅ [Sync] Background sync scheduled")
        } catch {
            print("❌ [Sync] Failed to schedule: \(error)")
        }
    }
    
    private func handleBackgroundSync(task: BGAppRefreshTask) {
        let syncTask = Task {
            await syncAll()
            if !Task.isCancelled { // ✅ Only complete if not already expired
                task.setTaskCompleted(success: true)
                scheduleBackgroundSync()
            }
        }
        
        task.expirationHandler = {
            syncTask.cancel() // ✅ Cancel the sync operation
            task.setTaskCompleted(success: false)
        }
    }
    
    // MARK: - Main Sync
    
    func syncAll() async {
        guard !isSyncing else {
            print("⚠️ [Sync] Already syncing")
            return
        }
        
        isSyncing = true
        defer { isSyncing = false }
        
        print("🔄 [Sync] Starting full sync...")
        
        do {
            // 1. Sync pending messages
            await syncPendingMessages()
            
            // 2. Fetch new messages from server
            await fetchNewMessages()
            
            // 3. Sync contacts
            await syncContacts()
            
            // 4. Update last sync time
            lastSyncTime = Date()
            
            print("✅ [Sync] Completed at \(lastSyncTime!)")
        } catch {
            print("❌ [Sync] Failed: \(error)")
        }
    }
    
    // MARK: - Pending Messages
    
    private func syncPendingMessages() async {
        print("📤 [Sync] Syncing pending offline/mesh messages...")
        let pendingMessages = await DatabaseService.shared.getPendingMessages()
        
        guard !pendingMessages.isEmpty else {
            print("📤 [Sync] No pending messages to sync")
            return
        }
        
        print("📤 [Sync] Found \(pendingMessages.count) pending messages")
        
        for msg in pendingMessages {
            do {
                let success = try await APIService.shared.sendMessage(
                    recipientId: msg.recipientId,
                    content: msg.text,
                    messageId: msg.id,
                    messageType: msg.type == .text ? nil : msg.type.icon,
                    mediaUrl: msg.audioUrl
                )
                
                if success {
                    var updatedMsg = msg
                    updatedMsg.syncState = .synced
                    updatedMsg.status = .sent
                    
                    // Keep "mesh" tag if originally sent via mesh, otherwise mark as "server"
                    if updatedMsg.via != "mesh" {
                        updatedMsg.via = "server"
                    }
                    await DatabaseService.shared.insertMessage(updatedMsg)
                    print("✅ [Sync] Uploaded offline message: \(msg.id)")
                }
            } catch {
                print("❌ [Sync] Failed to sync message \(msg.id): \(error)")
            }
        }
    }
    
    // MARK: - Fetch New Messages
    
    private func fetchNewMessages() async {
        do {
            let messages = try await APIService.shared.getInbox(since: lastSyncTime)
            print("📥 [Sync] Fetched \(messages.count) new messages")
            
            // Save to local database
            for msg in messages {
                let chatMessage = ChatMessage(
                    id: msg.id,
                    roomId: msg.senderId,
                    senderId: msg.senderId,
                    senderName: msg.senderName ?? "Unknown",
                    recipientId: msg.recipientId,
                    text: msg.content,
                    timestamp: ISO8601DateFormatter().date(from: msg.timestamp) ?? Date(),
                    via: "server",
                    status: .delivered,
                    syncState: .synced
                )
                await DatabaseService.shared.insertMessage(chatMessage)
                
                // Notify UI so chats and inbox update live
                await MainActor.run {
                    NotificationCenter.default.post(name: NSNotification.Name("NewIncomingMessage"), object: chatMessage)
                }
            }
        } catch {
            print("❌ [Sync] Fetch messages failed: \(error)")
        }
    }
    
    // MARK: - Contacts
    
    private func syncContacts() async {
        print("👥 [Sync] Syncing contacts...")
    }
    
    // MARK: - Timer Control
    
    func startAutoSync() {
        stopAutoSync()
        Task { @MainActor in
            let timer = Timer.scheduledTimer(withTimeInterval: self.syncInterval, repeats: true) { _ in
                Task {
                    await SyncService.shared.syncAll()
                }
            }
            await self.setSyncTimer(timer)
        }
        print("✅ [Sync] Auto-sync started (every \(Int(syncInterval))s)")
    }
    
    func stopAutoSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
    
    private func setSyncTimer(_ timer: Timer) {
        self.syncTimer = timer
    }
}
