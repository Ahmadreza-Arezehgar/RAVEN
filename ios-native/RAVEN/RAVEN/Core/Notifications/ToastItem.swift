import Foundation

// MARK: - Toast Type
/// Types of notifications that can be displayed as toast
enum ToastType: Int, Codable, CaseIterable {
    case message = 0        // Text message
    case voice = 1          // Voice message
    case friendRequest = 2  // Friend request
    case security = 3       // Security alert (login, etc.)
    case like = 4           // Someone liked your post
    case comment = 5        // Someone commented on your post
    case groupInvite = 6    // Invited to a group
    case appUpdate = 7      // App update available
    
    var icon: String {
        switch self {
        case .message: return "message.fill"
        case .voice: return "waveform"
        case .friendRequest: return "person.badge.plus"
        case .security: return "shield.checkered"
        case .like: return "heart.fill"
        case .comment: return "bubble.left.fill"
        case .groupInvite: return "person.3.fill"
        case .appUpdate: return "arrow.down.circle.fill"
        }
    }
    
    var accentColor: String {
        switch self {
        case .message: return "blue"
        case .voice: return "purple"
        case .friendRequest: return "green"
        case .security: return "orange"
        case .like: return "pink"
        case .comment: return "cyan"
        case .groupInvite: return "indigo"
        case .appUpdate: return "mint"
        }
    }
    
    /// Display name for the notification type
    var displayName: String {
        switch self {
        case .message: return "Message"
        case .voice: return "Voice"
        case .friendRequest: return "Friend Request"
        case .security: return "Security"
        case .like: return "Like"
        case .comment: return "Comment"
        case .groupInvite: return "Group Invite"
        case .appUpdate: return "Update"
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
    
    static func == (lhs: ToastItem, rhs: ToastItem) -> Bool {
        lhs.id == rhs.id
    }
    
    // MARK: - Factory Methods
    
    /// Create a message toast
    static func message(
        id: String = UUID().uuidString,
        senderName: String,
        preview: String,
        avatarURL: URL? = nil,
        chatId: String,
        senderId: String,
        isGroup: Bool = false
    ) -> ToastItem {
        ToastItem(
            id: id,
            type: .message,
            title: senderName,
            body: preview,
            avatarURL: avatarURL,
            chatId: chatId,
            senderId: senderId,
            senderName: senderName,
            isGroup: isGroup,
            canReply: true,
            receivedAt: Date()
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
    
    /// Create a like notification toast
    static func like(
        id: String = UUID().uuidString,
        userName: String,
        avatarURL: URL? = nil,
        postId: String
    ) -> ToastItem {
        ToastItem(
            id: id,
            type: .like,
            title: userName,
            body: "liked your post",
            avatarURL: avatarURL,
            chatId: postId, // reuse chatId for postId
            senderId: nil,
            senderName: userName,
            isGroup: false,
            canReply: false,
            receivedAt: Date()
        )
    }
    
    /// Create a comment notification toast
    static func comment(
        id: String = UUID().uuidString,
        userName: String,
        preview: String,
        avatarURL: URL? = nil,
        postId: String
    ) -> ToastItem {
        ToastItem(
            id: id,
            type: .comment,
            title: userName,
            body: preview.isEmpty ? "commented on your post" : preview,
            avatarURL: avatarURL,
            chatId: postId, // reuse chatId for postId
            senderId: nil,
            senderName: userName,
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
