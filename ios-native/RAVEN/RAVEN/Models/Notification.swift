import Foundation

// MARK: - Notification Type
enum NotificationType: String, Codable {
    case message
    case like
    case comment
    case friendRequest = "friend_request"
    case friendRequestSent = "friend_request_sent"
    case mention
    case presence
    case deadDrop = "dead_drop"
    case security
}

// MARK: - Notification Model
struct AppNotification: Identifiable, Codable {
    let id: String
    let type: NotificationType
    let data: NotificationData
    let timestamp: Date
    var isRead: Bool
}

// Keep backwards compatibility
typealias RAVENNotification = AppNotification

// MARK: - Notification Data (for Deep Links)
enum NotificationData: Codable {
    case message(MessageNotificationData)
    case like(LikeNotificationData)
    case comment(CommentNotificationData)
    case friendRequest(FriendRequestNotificationData)
    case security(SecurityNotificationData)
    case generic
    
    // Custom coding
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let message = try? container.decode(MessageNotificationData.self) {
            self = .message(message)
        } else if let like = try? container.decode(LikeNotificationData.self) {
            self = .like(like)
        } else if let comment = try? container.decode(CommentNotificationData.self) {
            self = .comment(comment)
        } else if let friendRequest = try? container.decode(FriendRequestNotificationData.self) {
            self = .friendRequest(friendRequest)
        } else if let security = try? container.decode(SecurityNotificationData.self) {
            self = .security(security)
        } else {
            self = .generic
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .message(let data): try container.encode(data)
        case .like(let data): try container.encode(data)
        case .comment(let data): try container.encode(data)
        case .friendRequest(let data): try container.encode(data)
        case .security(let data): try container.encode(data)
        case .generic: try container.encodeNil()
        }
    }
}

// MARK: - Notification Data Types

struct MessageNotificationData: Codable {
    let roomId: String
    let peerId: String
    let peerUsername: String
    let senderId: String
    let senderUsername: String
    let messageId: String
    let preview: String
    let messageType: MessageType
}

struct LikeNotificationData: Codable {
    let postId: String
    let likerId: String
    let likerUsername: String
}

struct CommentNotificationData: Codable {
    let postId: String
    let commentId: String
    let commenterId: String
    let commenterUsername: String
    let preview: String
}

struct FriendRequestNotificationData: Codable {
    let requesterId: String
    let requesterUsername: String
}

struct SecurityNotificationData: Codable {
    let event: String  // new_login, password_changed
    let device: String?
    let ip: String?
    let location: String?
}
