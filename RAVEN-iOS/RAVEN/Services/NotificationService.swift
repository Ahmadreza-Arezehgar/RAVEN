// RAVEN - Notification Service
// Converted from Flutter notification services

import Foundation
import UserNotifications
import UIKit

/// Handles push notifications and local notifications
@MainActor
class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()
    
    @Published var isAuthorized = false
    @Published var deviceToken: String?
    
    /// The chat ID the user is currently viewing — used to suppress notifications for that chat
    @Published var activeChatId: String?
    
    var onNotificationTap: ((String, String?) -> Void)?  // (type, chatId)
    
    override private init() {
        super.init()
    }
    
    // MARK: - Permission
    
    func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
            
            if granted {
                await UIApplication.shared.registerForRemoteNotifications()
                print("✅ [Notifications] Permission granted")
            }
            
            return granted
        } catch {
            print("❌ [Notifications] Permission error: \(error)")
            return false
        }
    }
    
    func checkPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }
    
    // MARK: - Token
    
    func handleDeviceToken(_ token: Data) {
        deviceToken = token.map { String(format: "%02.2hhx", $0) }.joined()
        print("📱 [Notifications] Token: \(deviceToken ?? "nil")")
        
        // Send to server
        Task {
            // await APIService.shared.registerPushToken(deviceToken)
        }
    }
    
    // MARK: - Local Notifications
    
    /// Show local notification for message
    func showMessageNotification(from senderName: String, content: String, chatId: String) {
        // If user is currently viewing this chat, don't show notification
        if activeChatId == chatId {
            return
        }
        
        let notificationContent = UNMutableNotificationContent()
        notificationContent.title = senderName
        notificationContent.body = content
        notificationContent.sound = .default
        notificationContent.badge = 1
        notificationContent.userInfo = [
            "type": "message",
            "chatId": chatId
        ]
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: notificationContent,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Show local notification for social
    func showSocialNotification(title: String, body: String, type: String, postId: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [
            "type": type,
            "postId": postId ?? ""
        ]
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Schedule notification
    func scheduleNotification(title: String, body: String, date: Date, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Cancel scheduled notification
    func cancelNotification(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
    
    // MARK: - Badge
    
    func updateBadge(count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count)
    }
    
    func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }
    
    // MARK: - Handle Notification
    
    func handleNotification(_ userInfo: [AnyHashable: Any]) {
        guard let type = userInfo["type"] as? String else { return }
        
        switch type {
        case "message":
            if let chatId = userInfo["chatId"] as? String {
                onNotificationTap?("message", chatId)
            }
        case "like", "comment":
            if let postId = userInfo["postId"] as? String {
                onNotificationTap?(type, postId)
            }
        default:
            onNotificationTap?(type, nil)
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        
        // Check if this notification belongs to the currently active chat
        let shouldSuppress = await MainActor.run {
            let notifChatId = (userInfo["chatId"] as? String) ??
                              (userInfo["roomId"] as? String) ??
                              (userInfo["sender_id"] as? String)
            
            if let type = userInfo["type"] as? String, type == "message", let chatId = notifChatId {
                return NotificationService.shared.activeChatId == chatId
            }
            return false
        }
        
        // If user is in the chat, return empty options to suppress banner/sound
        if shouldSuppress {
            return []
        }
        
        // Show notification even when app is foreground
        return [.banner, .sound, .badge]
    }
    
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run {
            handleNotification(userInfo)
        }
    }
}
