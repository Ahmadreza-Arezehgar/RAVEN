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
                registerForRemoteNotifications()
            } else {
                #if DEBUG
                print("[Push] ❌ Authorization DENIED by user")
                #endif
            }

            // Register notification categories for lock screen actions
            registerNotificationCategories()
            
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
    
    // MARK: - Register Notification Categories (Lock Screen Actions)
    
    /// Register UNNotificationCategory instances so iOS shows action buttons
    /// on lock screen / notification center. The category IDs MUST match the
    /// `category` field in the APNs payload sent by the server.
    @MainActor
    private func registerNotificationCategories() {
        let center = UNUserNotificationCenter.current()
        
        // ── MESSAGE: Reply + Mark Read ──
        let replyAction = UNTextInputNotificationAction(
            identifier: "REPLY",
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a reply..."
        )
        let markReadAction = UNNotificationAction(
            identifier: "MARK_READ",
            title: "Mark as Read",
            options: []
        )
        let messageCategory = UNNotificationCategory(
            identifier: "MESSAGE",
            actions: [replyAction, markReadAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        
        // ── FRIEND_REQUEST: Accept + Decline ──
        let acceptAction = UNNotificationAction(
            identifier: "ACCEPT",
            title: "Accept",
            options: [.authenticationRequired]
        )
        let declineAction = UNNotificationAction(
            identifier: "DECLINE",
            title: "Decline",
            options: [.destructive]
        )
        let friendRequestCategory = UNNotificationCategory(
            identifier: "FRIEND_REQUEST",
            actions: [acceptAction, declineAction],
            intentIdentifiers: [],
            options: []
        )
        
        // ── LIKE: View Post ──
        let viewAction = UNNotificationAction(
            identifier: "VIEW",
            title: "View",
            options: [.foreground]
        )
        let likeCategory = UNNotificationCategory(
            identifier: "LIKE",
            actions: [viewAction],
            intentIdentifiers: [],
            options: []
        )
        
        // ── COMMENT: Reply + View ──
        let commentReplyAction = UNTextInputNotificationAction(
            identifier: "REPLY",
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply to comment..."
        )
        let commentCategory = UNNotificationCategory(
            identifier: "COMMENT",
            actions: [commentReplyAction, viewAction],
            intentIdentifiers: [],
            options: []
        )
        
        // ── MENTION: View Post ──
        let mentionCategory = UNNotificationCategory(
            identifier: "MENTION",
            actions: [viewAction],
            intentIdentifiers: [],
            options: []
        )
        
        // ── NEW_POST: View Post ──
        let newPostCategory = UNNotificationCategory(
            identifier: "NEW_POST",
            actions: [viewAction],
            intentIdentifiers: [],
            options: []
        )
        
        // ── AUDIO_ROOM: Join ──
        let joinAction = UNNotificationAction(
            identifier: "JOIN",
            title: "Join",
            options: [.foreground]
        )
        let audioRoomCategory = UNNotificationCategory(
            identifier: "AUDIO_ROOM",
            actions: [joinAction],
            intentIdentifiers: [],
            options: []
        )

        // ── SECURITY_ALERT: Review (foreground, auth required) ──
        // New-device login, password change, biometric disabled, etc.
        // `authenticationRequired` so the user must unlock before any
        // sensitive action — defends against shoulder-surfing on the
        // lock screen banner.
        let reviewSecurityAction = UNNotificationAction(
            identifier: "REVIEW_SECURITY",
            title: "Review",
            options: [.foreground, .authenticationRequired]
        )
        let securityAlertCategory = UNNotificationCategory(
            identifier: "SECURITY_ALERT",
            actions: [reviewSecurityAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // ── LIVE_LOCATION: Open Map ──
        // Same `View` action label the location bubble uses inside the
        // chat — keeps the muscle memory consistent.
        let openMapAction = UNNotificationAction(
            identifier: "OPEN_MAP",
            title: "Open Map",
            options: [.foreground]
        )
        let liveLocationCategory = UNNotificationCategory(
            identifier: "LIVE_LOCATION",
            actions: [openMapAction],
            intentIdentifiers: [],
            options: []
        )

        // ── REACTION: View Message ──
        let viewMessageAction = UNNotificationAction(
            identifier: "VIEW_MESSAGE",
            title: "View",
            options: [.foreground]
        )
        let reactionCategory = UNNotificationCategory(
            identifier: "REACTION",
            actions: [viewMessageAction],
            intentIdentifiers: [],
            options: []
        )

        // ── CONTACT_SHARED: Privacy Settings + Open Chat ──
        // First action takes the user straight to the Privacy pane so
        // they can flip the `allow_contact_share` toggle if they're
        // unhappy. Second jumps to the chat where it happened.
        let openPrivacyAction = UNNotificationAction(
            identifier: "OPEN_PRIVACY",
            title: "Privacy Settings",
            options: [.foreground, .authenticationRequired]
        )
        let openChatAction = UNNotificationAction(
            identifier: "OPEN_CHAT",
            title: "Open Chat",
            options: [.foreground]
        )
        let contactSharedCategory = UNNotificationCategory(
            identifier: "CONTACT_SHARED",
            actions: [openPrivacyAction, openChatAction],
            intentIdentifiers: [],
            options: []
        )

        // ── PROFILE_VIEW: View Profile ──
        let viewProfileAction = UNNotificationAction(
            identifier: "VIEW_PROFILE",
            title: "View",
            options: [.foreground]
        )
        let profileViewCategory = UNNotificationCategory(
            identifier: "PROFILE_VIEW",
            actions: [viewProfileAction],
            intentIdentifiers: [],
            options: []
        )

        // ── SCREENSHOT_PROFILE / SCREENSHOT_CHAT: Block + Report ──
        // These are sensitive — give the user one-tap escalation paths
        // straight from the lock screen so they can react fast.
        let blockUserAction = UNNotificationAction(
            identifier: "BLOCK_USER",
            title: "Block",
            options: [.destructive, .authenticationRequired]
        )
        let reportUserAction = UNNotificationAction(
            identifier: "REPORT_USER",
            title: "Report",
            options: [.foreground, .destructive]
        )
        let screenshotProfileCategory = UNNotificationCategory(
            identifier: "SCREENSHOT_PROFILE",
            actions: [blockUserAction, reportUserAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let screenshotChatCategory = UNNotificationCategory(
            identifier: "SCREENSHOT_CHAT",
            actions: [blockUserAction, reportUserAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        center.setNotificationCategories([
            messageCategory,
            friendRequestCategory,
            likeCategory,
            commentCategory,
            mentionCategory,
            newPostCategory,
            audioRoomCategory,
            securityAlertCategory,
            liveLocationCategory,
            reactionCategory,
            contactSharedCategory,
            profileViewCategory,
            screenshotProfileCategory,
            screenshotChatCategory
        ])
        
        #if DEBUG
        print("[Push] ✅ Registered 14 notification categories (MESSAGE, FRIEND_REQUEST, LIKE, COMMENT, MENTION, NEW_POST, AUDIO_ROOM, SECURITY_ALERT, LIVE_LOCATION, REACTION, CONTACT_SHARED, PROFILE_VIEW, SCREENSHOT_PROFILE, SCREENSHOT_CHAT)")
        #endif
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
            // App is in background → Sync + ensure lock screen notification
            await debouncedSync()
            
            // ✅ FIX: Schedule local notification for ALL background push types
            // APNs alert pushes should display on lock screen automatically, but
            // iOS sometimes throttles or suppresses non-message notifications.
            // Scheduling a local notification guarantees lock screen delivery.
            // Uses the same pattern as mesh messages (line ~577 in RAVENApp.swift).
            await scheduleLocalNotificationForBackground(payload)
            
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

        // 🔴 Bug fix (2026-05-09): dedup gate — if mesh OR a previous
        // delivery channel already showed this message, skip the
        // in-app banner. Without this, a message arriving via APNs
        // while backgrounded (shown on lockscreen) and then arriving
        // via WS when the app opens produces a redundant in-app banner.
        if let messageId = payload.messageId, !messageId.isEmpty {
            Task {
                let firstToShow = await NotificationDedupCache.shared.claim(messageId: messageId)
                if firstToShow {
                    await MainActor.run { self.enqueueMessageToast(payload, chatId: chatId) }
                } else {
                    #if DEBUG
                    print("📵 [Notif] Skipping APNs/WS in-app toast for \(messageId.prefix(8)) — already shown")
                    #endif
                }
            }
            return
        }
        // No messageId → fall back to the legacy direct enqueue. The
        // pipeline's body-based dedup will catch most duplicates.
        enqueueMessageToast(payload, chatId: chatId)
    }

    @MainActor
    private func enqueueMessageToast(_ payload: PushPayload, chatId: String) {
        if let conversation = ConversationStore.shared.conversations.first(where: { $0.roomId == chatId }) {
            let isGroup = conversation.isGroup
            let senderName = isGroup ? (conversation.groupName ?? "Group") : conversation.peer.displayName
            // Type-aware preview — use the existing conversation
            // last-message metadata if we have it, otherwise format
            // straight from the push payload.
            let preview = MessagePreviewFormatter.format(
                messageType: payload.messageType,
                body: conversation.lastMessage?.preview ?? payload.preview
            )

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
            let safePreview = MessagePreviewFormatter.format(
                messageType: payload.messageType,
                body: payload.preview
            )

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
    
    // MARK: - Background Local Notification (Lock Screen Guarantee)
    
    /// Schedule a local notification for background pushes.
    /// APNs alert pushes SHOULD display on lock screen, but iOS sometimes
    /// throttles or silently drops non-message notifications (likes, comments,
    /// friend requests). This method guarantees lock screen delivery by
    /// scheduling a local UNNotificationRequest — same pattern used for
    /// mesh messages which reliably appear on lock screen.
    private func scheduleLocalNotificationForBackground(_ payload: PushPayload) async {
        // ⚡ Dedup gate for message types
        // ─────────────────────────────────
        // For .message / .dmMessage / .groupMessage iOS already shows
        // the APNs alert payload itself on the lock screen — running
        // a local-notification "safety net" on top of that produces
        // two notifications for the same message, which is the bug
        // users hit. Mesh-delivered duplicates are handled by the
        // shared `NotificationDedupCache` in the mesh handler.
        //
        // We keep the safety net for non-message types (likes,
        // comments, friend requests) where APNs has historically
        // been less reliable.
        if payload.type == .message || payload.type == .dmMessage || payload.type == .groupMessage {
            // If we can identify the message, claim it so the mesh
            // path knows APNs already showed an alert and skips its
            // own local notif.
            if let messageId = payload.messageId, !messageId.isEmpty {
                _ = await NotificationDedupCache.shared.claim(messageId: messageId)
            }
            return
        }

        let content = UNMutableNotificationContent()

        // Build title and body based on notification type
        switch payload.type {
        case .message, .groupMessage, .dmMessage:
            // Unreachable — handled by the early-return above. Kept
            // so the exhaustive switch still compiles.
            var safeName = payload.senderName ?? "New Message"
            if safeName.looksEncrypted { safeName = "New Message" }
            content.title = safeName

            // Type-aware preview — "📷 Photo", "🎤 Voice message · 12s",
            // file name, etc. Falls back to a generic label when the
            // body is missing or looks like ciphertext that didn't
            // make it through E2EE decryption in this process.
            let formattedPreview = MessagePreviewFormatter.format(
                messageType: payload.messageType,
                body: payload.preview
            )
            let showPreview = UserDefaults.standard.object(forKey: "messagePreview") as? Bool ?? true
            content.body = showPreview ? formattedPreview : "New Message"
            content.threadIdentifier = payload.chatId ?? ""
            content.userInfo = [
                "type": payload.type.rawValue,
                "room_id": payload.chatId ?? "",
                "sender_id": payload.senderId ?? ""
            ]
            
        case .like, .postLike:
            var userName = payload.senderName ?? "Someone"
            if userName.looksEncrypted { userName = "Someone" }
            content.title = "New Like"
            content.body = "\(userName) liked your post"
            content.userInfo = [
                "type": payload.type.rawValue,
                "post_id": payload.postId ?? ""
            ]
            
        case .comment, .postComment:
            var userName = payload.senderName ?? "Someone"
            if userName.looksEncrypted { userName = "Someone" }
            var safePreview = payload.preview ?? "commented on your post"
            if safePreview.looksEncrypted { safePreview = "commented on your post" }
            content.title = "\(userName) commented"
            content.body = safePreview
            content.userInfo = [
                "type": payload.type.rawValue,
                "post_id": payload.postId ?? ""
            ]
            
        case .friendRequest:
            var userName = payload.senderName ?? "Someone"
            if userName.looksEncrypted { userName = "Someone" }
            content.title = "New Friend Request"
            content.body = "\(userName) wants to be friends"
            content.userInfo = [
                "type": payload.type.rawValue,
                "requester_id": payload.senderId ?? ""
            ]
            
        case .followRequest, .follow:
            var userName = payload.senderName ?? "Someone"
            if userName.looksEncrypted { userName = "Someone" }
            content.title = "New Follower"
            content.body = "\(userName) started following you"
            content.userInfo = [
                "type": payload.type.rawValue,
                "sender_id": payload.senderId ?? ""
            ]
            
        case .security:
            var safePreview = payload.preview ?? "New activity detected"
            if safePreview.looksEncrypted { safePreview = "New activity detected" }
            content.title = "Security Alert"
            content.body = safePreview
            content.userInfo = ["type": "security"]
            
        case .mention:
            var userName = payload.senderName ?? "Someone"
            if userName.looksEncrypted { userName = "Someone" }
            content.title = "\(userName) mentioned you"
            content.body = payload.preview ?? "mentioned you in a comment"
            content.userInfo = [
                "type": "mention",
                "post_id": payload.postId ?? ""
            ]
            
        case .addedToGroup:
            var userName = payload.senderName ?? "Someone"
            if userName.looksEncrypted { userName = "Someone" }
            content.title = "Group Invite"
            content.body = "\(userName) added you to a group"
            content.userInfo = [
                "type": "added_to_group",
                "group_id": payload.chatId ?? ""
            ]
            
        case .audioRoom, .audioRoomJoin:
            var userName = payload.senderName ?? "Someone"
            if userName.looksEncrypted { userName = "Someone" }
            content.title = "Voice Room"
            content.body = payload.type == .audioRoom
                ? "\(userName) started an audio room"
                : "\(userName) joined the audio room"
            content.userInfo = [
                "type": payload.type.rawValue,
                "room_id": payload.chatId ?? ""
            ]
        }
        
        // FIX: Set categoryIdentifier so iOS shows lock screen actions
        // (Reply, Accept/Decline, View, Join) on locally-scheduled notifications.
        switch payload.type {
        case .message, .groupMessage, .dmMessage:
            content.categoryIdentifier = "MESSAGE"
        case .friendRequest:
            content.categoryIdentifier = "FRIEND_REQUEST"
        case .like, .postLike:
            content.categoryIdentifier = "LIKE"
        case .comment, .postComment:
            content.categoryIdentifier = "COMMENT"
        case .mention:
            content.categoryIdentifier = "MENTION"
        case .audioRoom, .audioRoomJoin:
            content.categoryIdentifier = "AUDIO_ROOM"
        default:
            break
        }
        
        content.sound = .default
        
        // Use a deterministic identifier so if the APNs push already created
        // a notification, this local one replaces it (no duplicates).
        // Include event-specific data (postId/chatId) so different events
        // from the same sender don't collide. Use 10-second buckets to
        // deduplicate rapid retries while preserving distinct events.
        let bucketStamp = Int(Date().timeIntervalSince1970 / 10)
        let eventKey = payload.postId ?? payload.chatId ?? payload.commentId ?? "gen"
        let identifier = "push_\(payload.type.rawValue)_\(payload.senderId ?? "unknown")_\(eventKey)_\(bucketStamp)"
        
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil  // Deliver immediately
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            #if DEBUG
            print("[Push] ✅ Local notification scheduled for background \(payload.type.rawValue)")
            #endif
        } catch {
            #if DEBUG
            print("[Push] ❌ Failed to schedule local notification: \(error)")
            #endif
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
            commentId: userInfo["comment_id"] as? String ?? userInfo["commentId"] as? String,
            messageId: userInfo["message_id"] as? String
                       ?? userInfo["client_message_id"] as? String
                       ?? userInfo["messageId"] as? String
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
    /// Server-assigned message id. When present, used as the dedup
    /// key in `NotificationDedupCache` so APNs + mesh deliveries of
    /// the same message don't double-display.
    let messageId: String?
}

// MARK: - Push Token Registration

struct PushTokenRequest: Encodable {
    let token: String
    let platform: String
    let environment: String
    
    init(token: String, platform: String) {
        self.token = token
        self.platform = platform
        #if DEBUG
        self.environment = "sandbox"
        #else
        self.environment = "production"
        #endif
    }
}
