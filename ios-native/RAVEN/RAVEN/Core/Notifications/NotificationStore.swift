import SwiftUI
import Observation

// MARK: - Notification Store (Single Source of Truth)
@MainActor
@Observable
final class NotificationStore {
    static let shared = NotificationStore()
    
    var notifications: [AppNotification] = []
    var unreadCount: Int = 0
    var isLoading = false
    var lastSyncTime: Date?
    
    private let syncInterval: TimeInterval = 30 // Sync every 30 seconds
    
    private init() {}
    
    // MARK: - Sync from Server
    func sync() async {
        // Don't sync too frequently
        if let lastSync = lastSyncTime, Date().timeIntervalSince(lastSync) < 5 {
            return
        }
        
        isLoading = true
        defer { isLoading = false }
        
        // Collect IDs already marked read locally (optimistic state + cache)
        let localReadIds = Set(notifications.filter { $0.isRead }.map { $0.id })
        let cachedReadIds: Set<String> = {
            let cached = LocalNotificationService.shared.getCachedNotifications() ?? []
            return Set(cached.filter { $0.isRead }.map { $0.id })
        }()
        let allReadIds = localReadIds.union(cachedReadIds)
        
        do {
            var items = try await NotificationService.shared.getNotifications()
            // Merge: preserve local read state for notifications the server hasn't caught up with
            for i in items.indices {
                if !items[i].isRead && allReadIds.contains(items[i].id) {
                    items[i].isRead = true
                }
            }
            notifications = items
            unreadCount = items.filter { !$0.isRead }.count
            lastSyncTime = Date()
            #if DEBUG
            print("🔔 [NotificationStore] Synced \(items.count) notifications, \(unreadCount) unread")
            #endif
        } catch {
            #if DEBUG
            print("❌ [NotificationStore] Sync failed: \(error)")
            #endif
        }
    }
    
    // MARK: - Force Sync (after push notification)
    func syncNow() async {
        lastSyncTime = nil // Force bypass throttle
        await sync()
    }
    
    // MARK: - Mark as Read (Optimistic)
    func markAsRead(_ id: String) async {
        // 1. Optimistic UI update
        if let index = notifications.firstIndex(where: { $0.id == id }) {
            notifications[index].isRead = true
            unreadCount = notifications.filter { !$0.isRead }.count
        }
        
        // 2. Queue for server sync (fire-and-forget)
        try? await NotificationService.shared.markAsRead(id: id)
    }
    
    // MARK: - Mark All as Read (Optimistic)
    func markAllAsRead() async {
        // 1. Optimistic UI update (local copy → 1 UI refresh)
        var updated = notifications
        for i in updated.indices {
            updated[i].isRead = true
        }
        notifications = updated
        unreadCount = 0
        
        // 2. Queue for server sync (fire-and-forget)
        try? await NotificationService.shared.markAllAsRead()
    }
    
    // MARK: - Periodic Sync Timer
    func startPeriodicSync() {
        Task {
            while true {
                try? await Task.sleep(nanoseconds: UInt64(syncInterval * 1_000_000_000))
                await sync()
            }
        }
    }
}
