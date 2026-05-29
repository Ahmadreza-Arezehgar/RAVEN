import Foundation
import UIKit
import UserNotifications

// Backward compatibility alias for NotificationStore
typealias NotificationService = NotificationsService

// Empty body for POST requests
private struct NotificationEmptyBody: Encodable {}

// MARK: - Server Notification Response
struct ServerNotification: Codable, Identifiable {
    let id: String
    let type: String
    let data: NotificationData
    let timestamp: Date
    var isRead: Bool = false

    // 🔴 ROUND 70 (2026-05-23) — BUG FIX: badge always shows 50.
    //
    // PREVIOUSLY this enum had `case isRead = "is_read"`. NetworkService's
    // JSONDecoder uses `.convertFromSnakeCase`, which transforms every
    // JSON key from `is_read` to `isRead` BEFORE the CodingKey lookup
    // runs. With the explicit raw value `"is_read"`, the decoder looked
    // for that LITERAL key — but the JSON had already been transformed
    // to `isRead`, so the lookup MISSED on every single notification.
    // `decodeIfPresent` then returned nil → `isRead` defaulted to false
    // → every notification looked unread → badge counted all 50 in the
    // server's response cap → badge always displayed "50" regardless
    // of how many notifications the user actually read.
    //
    // FIX: drop the explicit `= "is_read"` raw value. The default raw
    // value for `case isRead` is the case name string `"isRead"`, which
    // is exactly the key the JSON arrives with after the snake-case
    // conversion. With this fix `is_read` from the server is correctly
    // honoured and the badge reflects the real unread count.
    enum CodingKeys: String, CodingKey {
        case id, type, data, timestamp, isRead
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        data = try container.decode(NotificationData.self, forKey: .data)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
    }
    
    // NotificationData uses automatic snake_case conversion from NetworkService.decoder
    // DO NOT add CodingKeys here - it conflicts with keyDecodingStrategy
    struct NotificationData: Codable {
        // Friend request specific
        let requestId: String?
        let requesterId: String?
        let requesterUsername: String?
        let requesterAvatar: String?

        // Post interaction specific (like/comment)
        let postId: String?
        let likerId: String?
        let likerUsername: String?
        let likerAvatar: String?       // 🟦 R52 — was missing, banner had no avatar
        let commenterId: String?
        let commenterUsername: String?
        let commenterAvatar: String?   // 🟦 R52 — was missing

        // Generic
        let title: String?
        let message: String?

        // Group notification fields
        let groupId: String?
        let groupName: String?
        let groupAvatarUrl: String?    // 🟦 R52 — was missing
        let addedBy: String?
        let addedById: String?

        // Group message notification fields
        let senderId: String?
        let senderUsername: String?
        let senderAvatar: String?      // 🟦 R52 — was missing, banner showed initials
        let preview: String?
        let roomId: String?
        let messageType: String?

        // Make all optional with default nil
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
            requesterId = try container.decodeIfPresent(String.self, forKey: .requesterId)
            requesterUsername = try container.decodeIfPresent(String.self, forKey: .requesterUsername)
            requesterAvatar = try container.decodeIfPresent(String.self, forKey: .requesterAvatar)
            postId = try container.decodeIfPresent(String.self, forKey: .postId)
            likerId = try container.decodeIfPresent(String.self, forKey: .likerId)
            likerUsername = try container.decodeIfPresent(String.self, forKey: .likerUsername)
            likerAvatar = try container.decodeIfPresent(String.self, forKey: .likerAvatar)
            commenterId = try container.decodeIfPresent(String.self, forKey: .commenterId)
            commenterUsername = try container.decodeIfPresent(String.self, forKey: .commenterUsername)
            commenterAvatar = try container.decodeIfPresent(String.self, forKey: .commenterAvatar)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            // Group fields
            groupId = try container.decodeIfPresent(String.self, forKey: .groupId)
            groupName = try container.decodeIfPresent(String.self, forKey: .groupName)
            groupAvatarUrl = try container.decodeIfPresent(String.self, forKey: .groupAvatarUrl)
            addedBy = try container.decodeIfPresent(String.self, forKey: .addedBy)
            addedById = try container.decodeIfPresent(String.self, forKey: .addedById)
            // Group message fields
            senderId = try container.decodeIfPresent(String.self, forKey: .senderId)
            senderUsername = try container.decodeIfPresent(String.self, forKey: .senderUsername)
            senderAvatar = try container.decodeIfPresent(String.self, forKey: .senderAvatar)
            preview = try container.decodeIfPresent(String.self, forKey: .preview)
            roomId = try container.decodeIfPresent(String.self, forKey: .roomId)
            messageType = try container.decodeIfPresent(String.self, forKey: .messageType)
        }

        enum CodingKeys: String, CodingKey {
            case requestId, requesterId, requesterUsername, requesterAvatar
            case postId, likerId, likerUsername, likerAvatar
            case commenterId, commenterUsername, commenterAvatar
            case title, message
            case groupId, groupName, groupAvatarUrl, addedBy, addedById
            case senderId, senderUsername, senderAvatar, preview, roomId, messageType
        }
    }
}

// MARK: - Notifications Service
/// Service to poll server notifications and route to NotificationPipeline
actor NotificationsService {
    static let shared = NotificationsService()
    
    private var lastFetchedIds: Set<String> = []
    private var isInitialized = false
    
    // Published unread count for Bell badge
    @MainActor static var unreadCount: Int = 0
    
    /// Until this date, polls will NOT overwrite `pipeline.unreadCount`.
    /// Set by `markAllAsRead()` to a 15-second window, which is plenty
    /// of time for the server to commit + the next 1–3 poll cycles to
    /// see consistent data.
    ///
    /// 🔴 Bug fix (2026-05-09): the previous implementation was a
    /// `Bool` that suppressed exactly ONE poll cycle. If the server
    /// took longer than a single cycle to commit the mark-all-read
    /// (or if a notification arrived between the POST and the next
    /// poll), the poll would revert `pipeline.unreadCount` back to a
    /// non-zero value — the user-reported "I open Notifications, the
    /// number doesn't go down" bug. A time window solves both cases.
    private var suppressUntil: Date?
    
    private init() {}
    
    // MARK: - Poll Notifications
    
    /// Fetch notifications and show new ones as toasts
    func pollNotifications() async {
        // Skip polling when offline
        guard NetworkMonitor.shared.isOnline else {
            #if DEBUG
            print("📦 [NotificationsService] Offline - skipping poll")
            #endif
            return
        }
        
        do {
            let notifications: [ServerNotification] = try await NetworkService.shared.get(
                path: "/api/notifications",
                queryItems: [URLQueryItem(name: "limit", value: "20")]
            )
            
            // Merge with local cache: if the user already marked a notification read
            // locally but the server hasn't processed the POST yet, preserve the local
            // read state to prevent the badge from reverting.
            let cachedNotifications = await MainActor.run {
                LocalNotificationService.shared.getCachedNotifications() ?? []
            }
            let localReadIds = Set(cachedNotifications.filter { $0.isRead }.map { $0.id })
            
            let unread = notifications.filter { n in
                // If locally marked as read, treat as read even if server says otherwise
                if localReadIds.contains(n.id) { return false }
                return !n.isRead
            }.count
            
            // 🔴 Don't revert unreadCount while a mark-all-read is
            // still propagating server-side. Time-based window so
            // multiple poll cycles are covered, not just the first.
            if let until = suppressUntil, until > Date() {
                #if DEBUG
                print("🔔 [NotificationsService] Poll suppressed — mark-all-read window active for \(Int(until.timeIntervalSinceNow))s more")
                #endif
            } else {
                // Window expired — clear marker.
                if suppressUntil != nil { suppressUntil = nil }

                // Even outside the suppress window, never bounce the
                // badge UP if we have a recent local "all caught up"
                // signal. The cap rule mirrors the chat-scroll fix:
                // local cache is the upper bound until the server
                // catches up. If every cached notification is
                // marked read, the local upper bound is 0 — so the
                // badge cannot revert to a non-zero number.
                let localUpperBound = cachedNotifications.contains(where: { !$0.isRead }) ? unread : 0

                await MainActor.run {
                    NotificationPipeline.shared.unreadCount = localUpperBound
                    #if DEBUG
                    print("🔔 [NotificationsService] unreadCount updated to: \(localUpperBound) (raw=\(unread))")
                    #endif
                }
            }
            
            // On first poll, just store IDs without showing toasts
            if !isInitialized {
                lastFetchedIds = Set(notifications.map { $0.id })
                isInitialized = true
                #if DEBUG
                print("📢 [NotificationsService] Initialized with \(notifications.count) notifications, \(unread) unread")
                #endif
                return
            }
            
            // Filter new notifications only
            let newNotifications = notifications.filter { !lastFetchedIds.contains($0.id) }
            
            if !newNotifications.isEmpty {
                #if DEBUG
                print("📢 [NotificationsService] Found \(newNotifications.count) new notifications")
                #endif
                
                // Update tracked IDs
                for notification in newNotifications {
                    lastFetchedIds.insert(notification.id)
                }
                
                // Show toasts for new notifications
                await showToasts(for: newNotifications)
            }
            
        } catch {
            #if DEBUG
            print("❌ [NotificationsService] Poll failed: \(error)")
            #endif
        }
    }
    
    // MARK: - Show Toasts
    
    @MainActor
    private func showToasts(for notifications: [ServerNotification]) {
        #if DEBUG
        print("  [showToasts] Attempting to show \(notifications.count) toasts")
        #endif
        let appState = UIApplication.shared.applicationState
        
        for notification in notifications {
            let toast = createToast(from: notification)
            if let toast = toast {
                #if DEBUG
                print("  [showToasts] Processing toast: \(toast.type) - \(toast.title)")
                #endif
                
                if appState == .active {
                    // P1 FIX: Don't show toast if user is already viewing this chat
                    if let chatId = toast.chatId, DeepLinkRouter.shared.isInChat(roomId: chatId) {
                        #if DEBUG
                        print("🔕 [showToasts] Suppressed — user is viewing chat: \(chatId.prefix(8))")
                        #endif
                        continue
                    }
                    NotificationPipeline.shared.enqueue(toast)
                }
                
                // ⚡️ FIX: بخش else و تابع fireLocalNotification کلا پاک شد! 
                // وقتی اپ در بکگراند است، اپل (APNs) به صورت خودکار پیامها را روی لاکاسکرین نشان میدهد.
                // ساختن نوتیفیکیشن لوکال در اینجا باعث دوتا شدن (Duplicate) هشدارها میشد.
            } else {
                #if DEBUG
                print("  [showToasts] Failed to create toast for type: \(notification.type)")
                #endif
            }
        }
    }
    
    
    
    @MainActor
    private func createToast(from notification: ServerNotification) -> ToastItem? {
        let conversations = ConversationStore.shared.conversations
        
        switch notification.type {
        case "message":
            guard let roomId = notification.data.roomId else { return nil }
            var senderUsername = notification.data.senderUsername ?? notification.data.title ?? "New message"
            
            if senderUsername.looksEncrypted || senderUsername.isEmpty {
                if let conv = conversations.first(where: { $0.roomId == roomId }) {
                    senderUsername = conv.isGroup ? (conv.groupName ?? conv.peer.displayName) : conv.peer.displayName
                } else {
                    senderUsername = "New message"
                }
            }
            
            // 🔴 ROUND 28 (2026-05-17) — empty preview hardening.
            // PREVIOUSLY: `data.preview ?? data.message ?? "fallback"` —
            // nil-coalescing doesn't catch empty strings, so a server
            // payload with `"preview": ""` (which happens for media
            // messages without captions) produced a banner whose
            // second line was blank. Run the candidate strings through
            // MessagePreviewFormatter so we land on a type-aware label
            // ("💬 Message", "📷 Photo", etc.) instead.
            let rawPreview = notification.data.preview ?? notification.data.message
            var preview = MessagePreviewFormatter.format(
                messageType: notification.data.messageType,
                body: rawPreview
            )
            if preview.looksEncrypted { preview = "Sent a secure message" }
            
            // 🟦 ROUND 52 (2026-05-17) — resolve avatar from notification
            // data first, fall back to local conversation cache. Was
            // hard-coded nil before, so every banner showed initials.
            let messageAvatarURL = AppConfig.mediaURL(from: notification.data.senderAvatar)
                ?? conversations.first(where: { $0.roomId == roomId })
                    .flatMap { AppConfig.mediaURL(from: $0.peer.avatarPath) }

            return ToastItem.message(
                id: notification.id,
                senderName: senderUsername,
                preview: preview,
                avatarURL: messageAvatarURL,
                chatId: roomId,
                senderId: notification.data.senderId ?? roomId,
                isGroup: false
            )

        case "friend_request":
            // 🔴 ROUND 71 phase 3 — only `senderId` + `requestId` are
            // hard requirements. Pre-fix the guard ALSO required
            // `requesterUsername`, so any legacy notification row
            // with a nil username (the exact bug the server now
            // fixes by populating via build_push_display_name) was
            // silently dropped from the toast pipeline — no banner,
            // no list-side hint, recipient never saw the request.
            // Now we fall back to "Someone" so the toast still
            // surfaces; the row-side renderer in NotificationsList
            // can pull a better display name from ConversationStore
            // peer cache when available.
            guard let senderId = notification.data.requesterId,
                  let requestId = notification.data.requestId else {
                return nil
            }
            var username = notification.data.requesterUsername ?? "Someone"
            if username.isEmpty || username.looksEncrypted { username = "Someone" }

            return ToastItem.friendRequest(
                id: notification.id,
                fromName: username,
                // 🟦 R52 — was `URL(string: $0)` direct, which produces
                // a relative URL with no scheme that AsyncImage can't
                // resolve. Use AppConfig.mediaURL to prepend the
                // server host when the path is relative.
                avatarURL: AppConfig.mediaURL(from: notification.data.requesterAvatar),
                senderId: senderId,
                requestId: requestId
            )
            
        case "like":
            #if DEBUG
            print("  [createToast] Like notification data: postId=\(notification.data.postId ?? "nil"), likerUsername=\(notification.data.likerUsername ?? "nil")")
            #endif
            guard var username = notification.data.likerUsername,
                  let postId = notification.data.postId else {
                #if DEBUG
                print("  [createToast] Like missing required fields!")
                #endif
                return nil
            }
            if username.looksEncrypted { username = "Someone" }
            
            return ToastItem.like(
                id: notification.id,
                userName: username,
                // 🟦 R52 — avatar plumbing.
                avatarURL: AppConfig.mediaURL(from: notification.data.likerAvatar),
                postId: postId
            )

        case "comment":
            guard var username = notification.data.commenterUsername,
                  let postId = notification.data.postId else {
                return nil
            }
            if username.looksEncrypted { username = "Someone" }

            var preview = notification.data.message ?? notification.data.preview ?? "commented on your post"
            if preview.looksEncrypted { preview = "commented on your post" }

            return ToastItem.comment(
                id: notification.id,
                userName: username,
                preview: preview,
                // 🟦 R52 — avatar plumbing.
                avatarURL: AppConfig.mediaURL(from: notification.data.commenterAvatar),
                postId: postId
            )
            
        case "added_to_group":
            guard notification.data.groupId != nil,
                  var groupName = notification.data.groupName else {
                #if DEBUG
                print("  [createToast] added_to_group missing required fields")
                #endif
                return nil
            }
            if groupName.looksEncrypted { groupName = "a Group" }
            
            // Trigger group sync to add group to conversations
            Task {
                #if DEBUG
                print("  [NotificationsService] Added to group '\(groupName)', fetching groups...")
                #endif
                do {
                    _ = try await GroupService.shared.fetchMyGroups()
                    // Refresh conversations to include the new group
                    await ConversationStore.shared.fetchConversations(forceFull: true)
                    #if DEBUG
                    print("  [NotificationsService] Group sync complete for '\(groupName)'")
                    #endif
                } catch {
                    #if DEBUG
                    print("  [NotificationsService] Group sync failed: \(error)")
                    #endif
                }
            }
            
            var addedBy = notification.data.addedBy ?? "Someone"
            if addedBy.looksEncrypted { addedBy = "Someone" }
            
            return ToastItem.appUpdate(
                id: notification.id,
                title: "Added to Group",
                message: "\(addedBy) added you to \(groupName)"
            )
            
        case "group_message":
            guard let groupId = notification.data.groupId ?? notification.data.roomId,
                  var senderUsername = notification.data.senderUsername else {
                #if DEBUG
                print("  [createToast] group_message missing required fields")
                #endif
                return nil
            }
            
            var groupName = notification.data.groupName ?? "Group"
            // 🔴 ROUND 28 — same empty-string nil-coalescing trap as
            // the 1-to-1 message path above. Route through the
            // formatter so media-without-caption / empty-preview
            // payloads still produce a useful banner body.
            var preview = MessagePreviewFormatter.format(
                messageType: notification.data.messageType,
                body: notification.data.preview
            )
            let senderId = notification.data.senderId ?? ""
            
            if senderUsername.looksEncrypted || groupName.looksEncrypted || groupName == "Group" {
                if let conv = ConversationStore.shared.conversations.first(where: { $0.roomId == groupId }) {
                    groupName = conv.groupName ?? conv.displayTitle
                    senderUsername = conv.peer.displayName
                } else {
                    if senderUsername.looksEncrypted { senderUsername = "Someone" }
                    if groupName.looksEncrypted { groupName = "Group" }
                }
            }
            
            if preview.looksEncrypted { preview = "Secure message" }
            
            // 🟦 R52 — prefer group avatar, fall back to sender avatar
            // (some servers ship the sender's avatar on group_message
            // pushes; the group avatar is more visually informative
            // for a group context).
            let groupMessageAvatarURL = AppConfig.mediaURL(from: notification.data.groupAvatarUrl)
                ?? AppConfig.mediaURL(from: notification.data.senderAvatar)
                ?? ConversationStore.shared.conversations.first(where: { $0.roomId == groupId })
                    .flatMap { AppConfig.mediaURL(from: $0.groupAvatarUrl ?? $0.peer.avatarPath) }

            return ToastItem.message(
                id: notification.id,
                senderName: "\(senderUsername) in \(groupName)",
                preview: preview,
                avatarURL: groupMessageAvatarURL,
                chatId: groupId,
                senderId: senderId,
                isGroup: true
            )

        case "mention":
            guard var username = notification.data.commenterUsername,
                  let postId = notification.data.postId else { return nil }

            if username.looksEncrypted { username = "someone" }

            var preview = notification.data.preview ?? "mentioned you"
            if preview.looksEncrypted { preview = "mentioned you" }

            return ToastItem.comment(
                id: notification.id,
                userName: username,
                preview: preview,
                // 🟦 R52 — avatar plumbing.
                avatarURL: AppConfig.mediaURL(from: notification.data.commenterAvatar),
                postId: postId
            )
            
        case "audio_room", "audio_room_join":
            var username = notification.data.senderUsername ?? notification.data.addedBy ?? "Someone"
            if username.looksEncrypted { username = "Someone" }
            
            let defaultMessage = notification.type == "audio_room" ? "\(username) started an audio room" : "\(username) joined the audio room"
            var safePreview = notification.data.message ?? notification.data.preview ?? defaultMessage
            if safePreview.looksEncrypted { safePreview = defaultMessage }

            return ToastItem.appUpdate(
                id: notification.id,
                title: "Live Audio Room",
                message: safePreview
            )
            
        default:
            // Generic notification
            if var title = notification.data.title,
               var message = notification.data.message {
               
                if title.looksEncrypted { title = "Notification" }
                if message.looksEncrypted { message = "You have a new secure notification" }
                
                return ToastItem.appUpdate(
                    id: notification.id,
                    title: title,
                    message: message
                )
            }
            return nil
        }
    }
    
    // MARK: - Reset
    
    func reset() {
        lastFetchedIds.removeAll()
        isInitialized = false
    }
    
    // MARK: - NotificationStore Compatibility Methods
    
    /// Get all notifications (for NotificationStore)
    func getNotifications() async throws -> [AppNotification] {
        let serverNotifications: [ServerNotification] = try await NetworkService.shared.get(
            path: "/api/notifications",
            queryItems: [URLQueryItem(name: "limit", value: "50")]
        )
        
        // Convert ServerNotification to AppNotification
        return serverNotifications.map { server in
            AppNotification(
                id: server.id,
                type: NotificationType(rawValue: server.type) ?? .security,
                data: .generic,  // Simplified - use generic for now
                timestamp: server.timestamp,
                isRead: server.isRead
            )
        }
    }
    
    /// Mark single notification as read
    func markAsRead(id: String) async throws {
        await PendingReadService.shared.enqueue(type: "notification", targetId: id, isAll: false)
    }
    
    /// Mark all notifications as read
    func markAllAsRead() async throws {
        // Suppress polls from reverting the badge for 15s — long
        // enough for the server to commit + ≥2 poll cycles to see
        // consistent data.
        suppressUntil = Date().addingTimeInterval(15)
        await PendingReadService.shared.enqueue(type: "notification", targetId: nil, isAll: true)
    }

    /// Open a fresh suppression window from any caller (e.g. when the
    /// view-side `markAllAsRead` runs through `LocalNotificationService`
    /// and bypasses this actor's POST). Same 15s window.
    func extendSuppressionWindow() {
        suppressUntil = Date().addingTimeInterval(15)
    }
}
