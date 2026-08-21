import Foundation

// MARK: - Toast Type
/// Types of notifications that can be displayed as toast
enum ToastType: Int, Codable, CaseIterable {
    case message = 0        // Text message
    case voice = 1          // Voice message
    case friendRequest = 2  // Friend request
    case security = 3       // Security alert (login, etc.)
    case like = 4           // Retired legacy value; decode-and-drop only
    case comment = 5        // Retired legacy value; decode-and-drop only
    case groupInvite = 6    // Invited to a group
    case appUpdate = 7      // App update available
    // (2026-05-15 — round 8) New in-app toast types matching the
    // newly-registered APNs categories. Keep the raw values stable
    // so existing serialised toasts in NotificationStore survive.
    case vaultAccess = 8        // Recipient opened a vault attachment
    case meshPeerNearby = 9     // Paired peer just appeared on BLE
    case backupDone = 10        // Encrypted backup finished
    case twoFactorRequest = 11  // Sign-in approval request
    case disasterMode = 12      // Disaster mode flipped on
    case audioRoomMention = 13  // Retired legacy value; decode-and-drop only

    var isMessagingProductEvent: Bool {
        switch self {
        case .message, .voice, .friendRequest, .security, .groupInvite,
             .appUpdate, .vaultAccess, .meshPeerNearby, .backupDone,
             .twoFactorRequest, .disasterMode:
            true
        case .like, .comment, .audioRoomMention:
            false
        }
    }

    var icon: String {
        switch self {
        case .message: return "message.fill"
        case .voice: return "waveform"
        case .friendRequest: return "person.badge.plus"
        case .security: return "shield.checkered"
        case .like, .comment: return "nosign"
        case .groupInvite: return "person.3.fill"
        case .appUpdate: return "arrow.down.circle.fill"
        case .vaultAccess: return "lock.open.fill"
        case .meshPeerNearby: return "antenna.radiowaves.left.and.right"
        case .backupDone: return "externaldrive.fill.badge.checkmark"
        case .twoFactorRequest: return "key.fill"
        case .disasterMode: return "exclamationmark.triangle.fill"
        case .audioRoomMention: return "nosign"
        }
    }

    var accentColor: String {
        switch self {
        case .message: return "blue"
        case .voice: return "purple"
        case .friendRequest: return "green"
        case .security: return "orange"
        case .like, .comment: return "gray"
        case .groupInvite: return "indigo"
        case .appUpdate: return "mint"
        case .vaultAccess: return "indigo"
        case .meshPeerNearby: return "blue"
        case .backupDone: return "green"
        case .twoFactorRequest: return "yellow"
        case .disasterMode: return "red"
        case .audioRoomMention: return "gray"
        }
    }

    /// Display name for the notification type
    var displayName: String {
        switch self {
        case .message: return "Message"
        case .voice: return "Voice"
        case .friendRequest: return "Friend Request"
        case .security: return "Security"
        case .like, .comment: return "Unavailable"
        case .groupInvite: return "Group Invite"
        case .appUpdate: return "Update"
        case .vaultAccess: return "Vault Access"
        case .meshPeerNearby: return "Mesh Peer"
        case .backupDone: return "Backup Done"
        case .twoFactorRequest: return "Sign-in Request"
        case .disasterMode: return "Disaster Mode"
        case .audioRoomMention: return "Unavailable"
        }
    }
}

// MARK: - Toast Item
/// A notification item that can be displayed as a toast
struct ToastItem: Identifiable, Equatable {
    let id: String
    let type: ToastType
    var title: String
    var body: String
    let avatarURL: URL?
    let chatId: String?
    let senderId: String?
    let senderName: String?
    let isGroup: Bool
    let canReply: Bool
    let receivedAt: Date
    var mergedCount: Int = 1
    // 🔴 ROUND 71 phase 3 follow-up #4 (2026-05-24) — group context.
    // For group messages we want the banner to show
    // "<sender> in <group>" so the recipient can see which group
    // the message belongs to without opening it. Pre-fix the
    // toast carried only `isGroup: Bool` — the title was either
    // just the sender's username (no group context) or just the
    // group name (no sender). Now we carry the group name
    // separately so the renderer can compose the full subtitle.
    var groupName: String? = nil
    // 🔴 ROUND 71 phase 3 follow-up #4 — server notification id
    // for proper read-tracking. Toast.id is a fresh UUID per
    // surface event (so dedup across re-renders works); the
    // server's Notification row has its OWN UUID. Pre-fix
    // `NotificationPipeline.handleTap` called `markAsRead(id:
    // item.id)` with the toast UUID — server never had a matching
    // row → unread count never decremented when the user tapped
    // the banner. Carry the server-side id here so the tap
    // handler can mark the right row read.
    var serverNotificationId: String? = nil
    // 🔴 ROUND 71 phase 3 follow-up #4 — message id for navigation
    // / dedup with other channels. Toast.id was used as the dedup
    // key, but the same message can arrive via WS + APNs + mesh,
    // each generating a fresh toast UUID. Carry the actual
    // message id so cross-channel dedup works.
    var messageId: String? = nil

    static func == (lhs: ToastItem, rhs: ToastItem) -> Bool {
        lhs.id == rhs.id
    }
    
    // MARK: - Factory Methods
    
    /// Create a message toast
    ///
    /// 🔴 ROUND 28 (2026-05-17) — defensive preview sanitation.
    /// The in-app banner used to render with an EMPTY second line when
    /// the server's notification payload carried `preview: ""` (empty
    /// string, not null). The factory accepted the empty string at
    /// face value, `Text("")` still claimed layout height per font
    /// metrics, and the result was a banner showing only the sender's
    /// username with a visibly-blank body line. The few NotificationsService
    /// paths that used `data.preview ?? "Sent you a message"` weren't
    /// catching this because nil-coalescing doesn't apply to `""`.
    /// Centralise the safety check here so every caller benefits.
    static func message(
        id: String = UUID().uuidString,
        senderName: String,
        preview: String,
        avatarURL: URL? = nil,
        chatId: String,
        senderId: String,
        isGroup: Bool = false,
        groupName: String? = nil,
        serverNotificationId: String? = nil,
        messageId: String? = nil
    ) -> ToastItem {
        // 🔴 ROUND 28 (2026-05-17) — strip invisible Unicode before
        // checking emptiness. PREVIOUSLY: only whitespace was
        // trimmed, so a body containing just an LRM / RLM / ZWSP /
        // control char (a real shape for failed-decrypt or empty
        // E2EE handoff payloads) survived the trim and rendered as
        // a visually-blank toast. Strip control/format/separator
        // scalars first so we fall back to "💬 Message" instead.
        let visibleScalars = preview.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return false
            default:
                return true
            }
        }
        let stripped = String(String.UnicodeScalarView(visibleScalars))
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBody = trimmed.isEmpty ? "💬 Message" : trimmed
        return ToastItem(
            id: id,
            type: .message,
            title: senderName,
            body: safeBody,
            avatarURL: avatarURL,
            chatId: chatId,
            senderId: senderId,
            senderName: senderName,
            isGroup: isGroup,
            canReply: true,
            receivedAt: Date(),
            groupName: groupName,
            serverNotificationId: serverNotificationId,
            messageId: messageId
        )
    }
    
    /// Create a voice message toast
    static func voice(
        id: String = UUID().uuidString,
        senderName: String,
        duration: TimeInterval,
        avatarURL: URL? = nil,
        chatId: String,
        senderId: String,
        isGroup: Bool = false
    ) -> ToastItem {
        let durationStr = String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
        return ToastItem(
            id: id,
            type: .voice,
            title: senderName,
            body: "Voice • \(durationStr)",
            avatarURL: avatarURL,
            chatId: chatId,
            senderId: senderId,
            senderName: senderName,
            isGroup: isGroup,
            canReply: true,
            receivedAt: Date()
        )
    }
    
    /// Create a friend request toast
    /// Note: requestId is stored in chatId field for use in accept/decline API calls
    static func friendRequest(
        id: String = UUID().uuidString,
        fromName: String,
        avatarURL: URL? = nil,
        senderId: String,
        requestId: String
    ) -> ToastItem {
        ToastItem(
            id: id,
            type: .friendRequest,
            title: "Friend Request",
            body: "\(fromName) wants to connect",
            avatarURL: avatarURL,
            chatId: requestId, // Store request_id here for accept/decline API
            senderId: senderId,
            senderName: fromName,
            isGroup: false,
            canReply: false,
            receivedAt: Date()
        )
    }
    
    /// Create a security alert toast
    static func security(
        id: String = UUID().uuidString,
        title: String,
        message: String,
        deviceInfo: String? = nil
    ) -> ToastItem {
        ToastItem(
            id: id,
            type: .security,
            title: title,
            body: deviceInfo != nil ? "\(message) • \(deviceInfo!)" : message,
            avatarURL: nil,
            chatId: nil,
            senderId: nil,
            senderName: nil,
            isGroup: false,
            canReply: false,
            receivedAt: Date()
        )
    }
    
    /// Create a group invite notification toast
    static func groupInvite(
        id: String = UUID().uuidString,
        groupName: String,
        inviterName: String,
        avatarURL: URL? = nil,
        groupId: String
    ) -> ToastItem {
        ToastItem(
            id: id,
            type: .groupInvite,
            title: groupName,
            body: "\(inviterName) invited you",
            avatarURL: avatarURL,
            chatId: groupId,
            senderId: nil,
            senderName: inviterName,
            isGroup: true,
            canReply: false,
            receivedAt: Date()
        )
    }
    
    /// Create an app update toast
    static func appUpdate(
        id: String = UUID().uuidString,
        title: String,
        message: String
    ) -> ToastItem {
        ToastItem(
            id: id,
            type: .appUpdate,
            title: title,
            body: message,
            avatarURL: nil,
            chatId: nil,
            senderId: nil,
            senderName: nil,
            isGroup: false,
            canReply: false,
            receivedAt: Date()
        )
    }
}

// MARK: - Quick Reply State
/// State for the quick reply sheet
struct QuickReplyState: Equatable {
    let toastItem: ToastItem
    var replyText: String = ""
    var isSending: Bool = false
}
