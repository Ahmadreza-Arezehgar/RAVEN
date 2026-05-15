import Foundation
import UIKit
import UserNotifications

// MARK: - Push Notification Service
// Rule: Push is just a TRIGGER, not source of truth
// Source of truth = DB + RealtimeEngine + ConversationStore

actor PushNotificationService {
    static let shared = PushNotificationService()
    
    private var deviceToken: String?
    private var lastSyncTime: Date?
    private var isSyncing = false
    
    // Debounce interval for multiple pushes
    private let syncDebounceInterval: TimeInterval = 1.0
    
    // MARK: - Register for Push
    
    @MainActor
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            
            if granted {
                #if DEBUG
                print("[Push] ✅ Authorization GRANTED by user")
                #endif
                await registerForRemoteNotifications()
            } else {
                #if DEBUG
                print("[Push] ❌ Authorization DENIED by user")
                #endif
            }
            
            // Log current settings
            let settings = await center.notificationSettings()
            #if DEBUG
            print("[Push] 📋 Settings: authorizationStatus=\(settings.authorizationStatus.rawValue) alertSetting=\(settings.alertSetting.rawValue) soundSetting=\(settings.soundSetting.rawValue) badgeSetting=\(settings.badgeSetting.rawValue) lockScreenSetting=\(settings.lockScreenSetting.rawValue) notificationCenterSetting=\(settings.notificationCenterSetting.rawValue)")
            #endif
            
            return granted
        } catch {
            #if DEBUG
            print("[Push] ❌ Authorization failed: \(error)")
            #endif
            return false
        }
    }
    
    @MainActor
    private func registerForRemoteNotifications() {
        #if DEBUG
        print("[Push] 📲 Calling UIApplication.registerForRemoteNotifications()...")
        #endif
        UIApplication.shared.registerForRemoteNotifications()
    }
    
    // MARK: - Retry Token Registration
    /// Re-sends the stored push token to the server on each app launch.
    /// Covers the case where a previous server call failed silently.
    func retryTokenRegistration() async {
        guard let storedToken = await KeychainService.shared.getPushToken() else {
            #if DEBUG
            print("[Push] ⚠️ No stored push token to retry")
            #endif
            return
        }
        
        #if DEBUG
        print("[Push] 🔄 Retrying token registration (token: \(storedToken.prefix(16))...)")
        #endif
        self.deviceToken = storedToken
        await sendTokenToServer(storedToken, attempt: 1)
    }
    
    // MARK: - Handle Device Token
    
    func handleDeviceToken(_ deviceToken: Data) async {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        
        #if DEBUG
        print("[Push] 📱 Received device token: \(token.prefix(16))... (\(token.count) chars)")
        #endif
        
        // Check if token changed
        let storedToken = await KeychainService.shared.getPushToken()
        
        if token != storedToken {
            #if DEBUG
            print("[Push] 🔄 Token CHANGED (old: \(storedToken?.prefix(16) ?? "nil")...), updating server...")
            #endif
            self.deviceToken = token
            
            // Store in Keychain
            await KeychainService.shared.savePushToken(token)
            
            // Send to server
            await sendTokenToServer(token)
        } else {
            #if DEBUG
            print("[Push] ✅ Token unchanged, already registered")
            #endif
            self.deviceToken = token
        }
    }
    
    func handleRegistrationError(_ error: Error) {
        #if DEBUG
        print("[Push] ❌ registerForRemoteNotifications FAILED: \(error.localizedDescription)")
        print("[Push] ❌ Full error: \(error)")
        #endif
    }
    
    // MARK: - Send Token to Server
    
    private func sendTokenToServer(_ token: String, attempt: Int = 1) async {
        // Guard: skip if user isn't authenticated yet (fresh install race condition)
        guard await KeychainService.shared.getToken() != nil else {
            #if DEBUG
            print("[Push] ⏳ Skipping token registration — no auth token yet (will retry after login)")
            #endif
            return
        }
        
        do {
            let _: EmptyResponse = try await NetworkService.shared.post(
                path: "/api/users/push-token",
                body: PushTokenRequest(
                    token: token,
                    platform: "ios"
                )
            )
            #if DEBUG
            print("[Push] ✅ Token registered with server (Attempt \(attempt))")
            #endif
        } catch {
            let nsError = error as NSError
            #if DEBUG
            print("❌ [Push] Failed to register token: \(error.localizedDescription) (Code: \(nsError.code))")
            #endif
            
            // Exponential backoff retry — cellular may not be ready at first attempt
            if attempt < 3 {
                let delay = TimeInterval(pow(2.0, Double(attempt)))
                #if DEBUG
                print("[Push] 🔄 Retrying in \(delay)s...")
                #endif
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await sendTokenToServer(token, attempt: attempt + 1)
            }
        }
    }
    
    // MARK: - Handle Push Received
    // ONLY syncs, NEVER navigates (navigation is handled by tap)
    
    func handlePushReceived(
        _ userInfo: [AnyHashable: Any],
        appState: UIApplication.State
    ) async {
        guard let payload = parsePushPayload(userInfo) else {
            #if DEBUG
            print("[Push] Invalid payload")
            #endif
            return
        }
        
        switch appState {
        case .active:
            // App is in foreground → Silent update + optional banner
            await handleForegroundPush(payload)
            
        case .background, .inactive:
            // App is in background → Just sync, tap handler will navigate
            await debouncedSync()
            
        @unknown default:
            break
        }
    }
    
    // MARK: - Handle Push Tap (Deep Link)
    // ONLY called when user taps notification
    
    func handlePushTap(_ userInfo: [AnyHashable: Any]) async {
        guard let payload = parsePushPayload(userInfo) else { return }
        
        // 1. Trigger sync first (debounced)
        await debouncedSync()
        
        // 2. Route to destination
        await routeToDestination(payload)
    }
    
    // MARK: - Debounced Sync (Prevents duplicate sync from multiple pushes)
    
    private func debouncedSync() async {
        // Check if already syncing or recently synced
        if isSyncing {
            #if DEBUG
            print("[Push] Sync already in progress, skipping")
            #endif
            return
        }
        
        if let lastSync = lastSyncTime,
           Date().timeIntervalSince(lastSync) < syncDebounceInterval {
            #if DEBUG
            print("[Push] Recently synced, skipping")
            #endif
            return
        }
        
        isSyncing = true
        lastSyncTime = Date()
        
        await RealtimeEngine.shared.syncNow()
        
        isSyncing = false
    }
    
    // MARK: - Foreground Push (Silent Update + Banner)
    
    private func handleForegroundPush(_ payload: PushPayload) async {
        await debouncedSync()
        
        switch payload.type {
        case .message, .groupMessage:
            let isInChat = await MainActor.run { DeepLinkRouter.shared.isInChat(roomId: payload.chatId ?? "") }
            if isInChat { return }
            
            // Check group mute settings before showing banner
            if payload.type == .groupMessage, let chatId = payload.chatId {
                let muteSettings = await GroupService.shared.getMuteSettings(groupId: chatId)
                if muteSettings.isMuted { return }  // Fully muted → suppress banner
                if muteSettings.mentionsOnly {
                    // Only show if the message contains a mention
                    let isMention = payload.preview?.contains("@") == true
                    if !isMention { return }
                }
            }
            
            await showToastForMessage(payload)
            
        case .friendRequest:
            await MainActor.run {
                var userName = payload.senderName ?? "Someone"
                if userName.looksEncrypted { userName = "Someone" }
                let toast = ToastItem.friendRequest(
                    fromName: userName,
                    senderId: payload.senderId ?? "",
                    requestId: payload.senderId ?? ""
                )
                NotificationPipeline.shared.enqueue(toast)
            }
            
        case .security:
            await MainActor.run {
                var safePreview = payload.preview ?? "New activity detected"
                if safePreview.looksEncrypted { safePreview = "New activity detected" }
                let toast = ToastItem.security(title: "Security Alert", message: safePreview)
                NotificationPipeline.shared.enqueue(toast)
            }
            
        case .like, .comment, .mention:
            await MainActor.run {
                var userName = payload.senderName ?? "Someone"
                if userName.looksEncrypted { userName = "Someone" }
                
                let defaultAction: String
                if payload.type == .like { defaultAction = "liked your post" }
                else if payload.type == .mention { defaultAction = "mentioned you" }
                else { defaultAction = "commented on your post" }
                
                var safePreview = payload.preview ?? defaultAction
                if safePreview.looksEncrypted { safePreview = defaultAction }
                
                let toast = ToastItem.comment(
                    id: UUID().uuidString,
                    userName: userName,
                    preview: safePreview,
                    avatarURL: nil,
                    postId: payload.chatId ?? ""
                )
                NotificationPipeline.shared.enqueue(toast)
            }
            
        case .addedToGroup, .audioRoom, .audioRoomJoin:
            await MainActor.run {
                let title = (payload.type == .audioRoom || payload.type == .audioRoomJoin) ? "Voice Room" : "Group Update"
                
                var safeName = payload.senderName ?? "Someone"
                if safeName.looksEncrypted { safeName = "Someone" }
                
                let defaultPreview: String
                if payload.type == .audioRoom { defaultPreview = "\(safeName) started an audio room" }
                else if payload.type == .audioRoomJoin { defaultPreview = "\(safeName) joined the audio room" }
                else { defaultPreview = "\(safeName) invited you" }
                
                var safePreview = payload.preview ?? defaultPreview
                if safePreview.looksEncrypted { safePreview = defaultPreview }
                
                let toast = ToastItem.appUpdate(
                    id: UUID().uuidString,
                    title: title,
                    message: safePreview
                )
                NotificationPipeline.shared.enqueue(toast)
            }
            
        case .postComment, .postLike:
            await MainActor.run {
                var userName = payload.senderName ?? "Someone"
                if userName.looksEncrypted { userName = "Someone" }
                
                let defaultAction = payload.type == .postLike ? "liked your post" : "commented on your post"
                var safePreview = payload.preview ?? defaultAction
                if safePreview.looksEncrypted { safePreview = defaultAction }
                
                let toast = ToastItem.comment(
                    id: UUID().uuidString,
                    userName: userName,
                    preview: safePreview,
                    avatarURL: nil,
                    postId: payload.postId ?? ""
                )
                NotificationPipeline.shared.enqueue(toast)
            }
            
        case .followRequest, .follow:
            await MainActor.run {
                var userName = payload.senderName ?? "Someone"
                if userName.looksEncrypted { userName = "Someone" }
                let toast = ToastItem.friendRequest(
                    fromName: userName,
                    senderId: payload.senderId ?? "",
                    requestId: payload.senderId ?? ""
                )
                NotificationPipeline.shared.enqueue(toast)
            }
            
        case .dmMessage:
            // Alias for .message — handle identically
            let isInChat = await MainActor.run { DeepLinkRouter.shared.isInChat(roomId: payload.chatId ?? "") }
            if !isInChat {
                await showToastForMessage(payload)
            }
        }
    }
    
    // MARK: - Toast for Message
    
    @MainActor
    private func showToastForMessage(_ payload: PushPayload) {
        guard let chatId = payload.chatId else { return }
        
        if let conversation = ConversationStore.shared.conversations.first(where: { $0.roomId == chatId }) {
            let isGroup = conversation.isGroup ?? false
            let senderName = isGroup ? (conversation.groupName ?? "Group") : conversation.peer.displayName
            let preview = conversation.lastMessage?.preview ?? "New message"
            
            let toast = ToastItem.message(
                senderName: senderName,
                preview: preview,
                avatarURL: conversation.peer.avatarPath.flatMap { URL(string: $0) },
                chatId: chatId,
                senderId: payload.senderId ?? "",
                isGroup: isGroup
            )
            NotificationPipeline.shared.enqueue(toast)
        } else {
            // FALLBACK for new chats not yet in local database
            var safeName = payload.senderName ?? "New Message"
            if safeName.looksEncrypted { safeName = "New Message" }
            var safePreview = payload.preview ?? "Sent you a message"
            if safePreview.looksEncrypted { safePreview = "Secure message" }
            
            let toast = ToastItem.message(
                senderName: safeName,
                preview: safePreview,
                chatId: chatId,
                senderId: payload.senderId ?? "",
                isGroup: payload.type == .groupMessage
            )
            NotificationPipeline.shared.enqueue(toast)
        }
    }
    
    // MARK: - Route to Destination
    
    private func routeToDestination(_ payload: PushPayload) async {
        switch payload.type {
        case .message, .groupMessage, .addedToGroup, .dmMessage:
            if let chatId = payload.chatId { await DeepLinkRouter.shared.route(to: .chat(roomId: chatId)) }
        case .friendRequest:
            await DeepLinkRouter.shared.route(to: .friendRequests)
        case .security:
            await DeepLinkRouter.shared.route(to: .security)
        case .like, .comment, .mention:
            if let postId = payload.postId {
                await DeepLinkRouter.shared.route(to: .post(postId: postId))
            } else {
                await DeepLinkRouter.shared.route(to: .notifications)
            }
        case .postComment, .postLike:
            if let postId = payload.postId {
                await DeepLinkRouter.shared.route(to: .post(postId: postId))
            } else {
                await DeepLinkRouter.shared.route(to: .notifications)
            }
        case .followRequest, .follow:
            if let userId = payload.senderId {
                await DeepLinkRouter.shared.route(to: .profile(userId: userId))
            } else {
                await DeepLinkRouter.shared.route(to: .friendRequests)
            }
        case .audioRoom, .audioRoomJoin:
            if let slug = payload.chatId { await DeepLinkRouter.shared.route(to: .audioRoom(slug: slug)) }
        }
    }
    
    // MARK: - Parse Payload
    
    private func parsePushPayload(_ userInfo: [AnyHashable: Any]) -> PushPayload? {
        guard let typeStr = userInfo["type"] as? String else { return nil }
        
        // Fallback to .message for unknown types so they aren't silently dropped
        let type = PushType(rawValue: typeStr) ?? .message
        
        return PushPayload(
            type: type,
            chatId: userInfo["chat_id"] as? String ?? userInfo["room_id"] as? String ?? userInfo["chatId"] as? String ?? userInfo["group_id"] as? String ?? userInfo["groupId"] as? String,
            senderId: userInfo["sender_id"] as? String ?? userInfo["requester_id"] as? String ?? userInfo["senderId"] as? String ?? userInfo["userId"] as? String,
            messageType: userInfo["message_type"] as? String,
            senderName: userInfo["sender_username"] as? String ?? userInfo["sender_name"] as? String ?? userInfo["title"] as? String,
            preview: userInfo["body"] as? String ?? userInfo["preview"] as? String ?? userInfo["message"] as? String,
            postId: userInfo["post_id"] as? String ?? userInfo["postId"] as? String,
            commentId: userInfo["comment_id"] as? String ?? userInfo["commentId"] as? String
        )
    }
}

// MARK: - Push Types

enum PushType: String {
    case message
    case groupMessage = "group_message"
    case friendRequest = "friend_request"
    case security
    case like
    case comment
    case mention
    case addedToGroup = "added_to_group"
    case audioRoom = "audio_room"
    case audioRoomJoin = "audio_room_join"
    // Deep Link notification types
    case postComment = "post_comment"
    case postLike = "post_like"
    case followRequest = "follow_request"
    case follow
    // Backend may also send dm_message / group_message aliases
    case dmMessage = "dm_message"
}

struct PushPayload {
    let type: PushType
    let chatId: String?
    let senderId: String?
    let messageType: String?
    let senderName: String?
    let preview: String?
    let postId: String?
    let commentId: String?
}

// MARK: - Push Token Registration

struct PushTokenRequest: Encodable {
    let token: String
    let platform: String
}
