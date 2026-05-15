import Foundation

// MARK: - Conversation Model (for Inbox)

struct Conversation: Identifiable, Codable, Hashable {
    let roomId: String
    let peer: Peer
    var lastMessage: LastMessage?
    var unreadCount: Int
    var isPinned: Bool
    var isMuted: Bool
    var updatedAt: Date
    
    // Group conversation support
    var isGroup: Bool
    var groupName: String?
    var groupAvatarUrl: String?
    
    // Channel support
    var isChannel: Bool
    var channelUsername: String?
    var channelType: String?
    
    // Message request fields (RAVEN+ non-friend messaging)
    var requestStatus: String?
    var isRequestSender: Bool?
    var pendingSentCount: Int?
    var requestId: String?

    // Telegram-style archive (Migration 35) — when true, this row is
    // hidden from the main inbox and surfaced only inside the
    // "Archived" folder pill at the top of the list.
    var isArchived: Bool

    var id: String { roomId }
    
    // Hash/Equatable
    // بررسی کامل فیلدها تا با دریافت پیام جدید، لیست UI به درستی و در لحظه رفرش شود
    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.roomId == rhs.roomId &&
        lhs.unreadCount == rhs.unreadCount &&
        lhs.isPinned == rhs.isPinned &&
        lhs.isMuted == rhs.isMuted &&
        lhs.updatedAt == rhs.updatedAt &&
        lhs.isGroup == rhs.isGroup &&
        lhs.groupName == rhs.groupName &&
        lhs.groupAvatarUrl == rhs.groupAvatarUrl &&
        lhs.isChannel == rhs.isChannel &&
        lhs.channelUsername == rhs.channelUsername &&
        lhs.channelType == rhs.channelType &&
        lhs.peer == rhs.peer &&
        lhs.lastMessage == rhs.lastMessage &&
        lhs.requestStatus == rhs.requestStatus &&
        lhs.isRequestSender == rhs.isRequestSender &&
        lhs.pendingSentCount == rhs.pendingSentCount &&
        lhs.requestId == rhs.requestId &&
        lhs.isArchived == rhs.isArchived
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(roomId)
        hasher.combine(unreadCount)
        hasher.combine(isPinned)
        hasher.combine(isMuted)
        hasher.combine(updatedAt)
        hasher.combine(isGroup)
        hasher.combine(groupName)
        hasher.combine(groupAvatarUrl)
        hasher.combine(isChannel)
        hasher.combine(channelUsername)
        hasher.combine(channelType)
        hasher.combine(peer)
        hasher.combine(lastMessage)
        hasher.combine(requestStatus)
        hasher.combine(isRequestSender)
        hasher.combine(pendingSentCount)
        hasher.combine(requestId)
        hasher.combine(isArchived)
    }
    
    // CodingKeys - Server uses camelCase for most fields
    // IMPORTANT: NetworkService.decoder uses .convertFromSnakeCase
    // So server's "is_group" becomes "isGroup" automatically - don't specify snake_case here!
    enum CodingKeys: String, CodingKey {
        case roomId           // Server sends "roomId" (camelCase)
        case peer
        case lastMessage      // Server sends "lastMessage" (camelCase)
        case unreadCount      // Server sends "unreadCount" (camelCase)
        case isPinned         // Server sends "isPinned" (camelCase)
        case isMuted          // Server sends "isMuted" (camelCase)
        case updatedAt        // Server sends "updatedAt" (camelCase)
        case isGroup          // Server sends "is_group" -> decoder converts to "isGroup"
        case groupName        // Server sends "group_name" -> decoder converts to "groupName"
        case groupAvatarUrl   // Server sends "group_avatar_url" -> decoder converts to "groupAvatarUrl"
        case isChannel        // Server sends "is_channel"
        case channelUsername  // Server sends "channel_username"
        case channelType      // Server sends "channel_type"
        case requestStatus    // Server sends "requestStatus" (camelCase)
        case isRequestSender  // Server sends "isRequestSender" (camelCase)
        case pendingSentCount // Server sends "pendingSentCount" (camelCase)
        case requestId        // Server sends "requestId" (camelCase)
        case isArchived       // Server sends "is_archived" -> decoder converts to "isArchived"
    }
    
    // Custom init to handle optional isGroup from server
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        roomId = try container.decode(String.self, forKey: .roomId)
        peer = try container.decode(Peer.self, forKey: .peer)
        lastMessage = try container.decodeIfPresent(LastMessage.self, forKey: .lastMessage)
        unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        isGroup = try container.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
        groupName = try container.decodeIfPresent(String.self, forKey: .groupName)
        groupAvatarUrl = try container.decodeIfPresent(String.self, forKey: .groupAvatarUrl)
        isChannel = try container.decodeIfPresent(Bool.self, forKey: .isChannel) ?? false
        channelUsername = try container.decodeIfPresent(String.self, forKey: .channelUsername)
        channelType = try container.decodeIfPresent(String.self, forKey: .channelType)
        requestStatus = try container.decodeIfPresent(String.self, forKey: .requestStatus)
        isRequestSender = try container.decodeIfPresent(Bool.self, forKey: .isRequestSender)
        pendingSentCount = try container.decodeIfPresent(Int.self, forKey: .pendingSentCount)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
    
    // Manual init for local creation
    init(roomId: String, peer: Peer, lastMessage: LastMessage? = nil, unreadCount: Int = 0,
         isPinned: Bool = false, isMuted: Bool = false, updatedAt: Date = Date(),
         isGroup: Bool = false, groupName: String? = nil, groupAvatarUrl: String? = nil,
         isChannel: Bool = false, channelUsername: String? = nil, channelType: String? = nil,
         requestStatus: String? = nil, isRequestSender: Bool? = nil,
         pendingSentCount: Int? = nil, requestId: String? = nil,
         isArchived: Bool = false) {
        self.roomId = roomId
        self.peer = peer
        self.lastMessage = lastMessage
        self.unreadCount = unreadCount
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.updatedAt = updatedAt
        self.isGroup = isGroup
        self.groupName = groupName
        self.groupAvatarUrl = groupAvatarUrl
        self.isChannel = isChannel
        self.channelUsername = channelUsername
        self.channelType = channelType
        self.requestStatus = requestStatus
        self.isRequestSender = isRequestSender
        self.pendingSentCount = pendingSentCount
        self.requestId = requestId
        self.isArchived = isArchived
    }
    
    /// Display name: group name for groups, peer name for 1:1, channel name
    var displayTitle: String {
        if isChannel, let name = groupName {
            return name
        }
        if isGroup, let name = groupName {
            return name
        }
        return peer.displayName
    }
    
    /// Avatar URL: group avatar for groups, peer avatar for 1:1, channel avatar
    var displayAvatarUrl: String? {
        if isChannel {
            return groupAvatarUrl
        }
        if isGroup {
            return groupAvatarUrl
        }
        return peer.avatarPath
    }
    
    struct Peer: Codable, Hashable {
        let userId: String
        let username: String
        let firstName: String?
        let lastName: String?
        let avatarPath: String?
        let isVerified: Bool
        
        enum CodingKeys: String, CodingKey {
            case userId       // Server sends "userId" (camelCase)
            case username
            case firstName    // Server sends "firstName" (camelCase)
            case lastName     // Server sends "lastName" (camelCase)
            case avatarPath   // Server sends "avatarPath" (camelCase)
            case isVerified   // Server sends "isVerified" (camelCase)
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            userId = try container.decode(String.self, forKey: .userId)
            username = try container.decode(String.self, forKey: .username)
            firstName = try container.decodeIfPresent(String.self, forKey: .firstName)
            lastName = try container.decodeIfPresent(String.self, forKey: .lastName)
            avatarPath = try container.decodeIfPresent(String.self, forKey: .avatarPath)
            isVerified = try container.decodeIfPresent(Bool.self, forKey: .isVerified) ?? false
        }
        
        // Manual memberwise init (needed because custom decoder init removes auto-generated one)
        init(userId: String, username: String, firstName: String? = nil, lastName: String? = nil, avatarPath: String? = nil, isVerified: Bool = false) {
            self.userId = userId
            self.username = username
            self.firstName = firstName
            self.lastName = lastName
            self.avatarPath = avatarPath
            self.isVerified = isVerified
        }
        
        var displayName: String {
            let safeFirst = firstName?.looksEncrypted == true ? "" : (firstName ?? "")
            let safeLast = lastName?.looksEncrypted == true ? "" : (lastName ?? "")
            let safeUser = username.looksEncrypted ? "" : username
            
            let full = "\(safeFirst) \(safeLast)".trimmingCharacters(in: .whitespaces)
            if !full.isEmpty { return full }
            if !safeUser.isEmpty { return safeUser }
            
            return "User \(String(userId.prefix(8)))"
        }
    }
    
    struct LastMessage: Codable, Hashable {
        let id: String
        let content: String?
        let messageType: MessageType
        let timestamp: Date
        let senderId: String
        let deliveryAuthority: DeliveryAuthority?
        
        enum CodingKeys: String, CodingKey {
            case id
            case content
            case messageType     // Server sends "messageType" (camelCase)
            case timestamp
            case senderId        // Server sends "senderId" (camelCase)
            case deliveryAuthority  // Server sends "deliveryAuthority" (camelCase)
        }
        
        var preview: String {
            switch messageType {
            case .text:
                if let c = content {
                    if c.looksEncrypted { return "Message" }
                    // Mistyped contact-card stored as text — recognise the
                    // JSON shape so the inbox row doesn't leak the raw blob.
                    if ContactSharePayload.looksLikeContactCard(c) {
                        return "👤 Shared a contact"
                    }
                    return c
                }
                return ""
            case .image:
                return "📷 Photo"
            case .video:
                return "🎬 Video"
            case .videoNote:
                return "🎥 Video note"
            case .ephemeralPhoto:
                return "📸 Snap Photo"
            case .file:
                return "📎 File"
            case .voice:
                return "🎤 Voice message"
            case .location:
                return "📍 Location"
            case .postShare:
                return "📬 Shared a post"
            case .contactCard:
                return "👤 Shared a contact"
            case .poll:
                return "📊 Poll"
            case .system:
                return "📢 Notification"
            }
        }
    }
}

// MARK: - Shared Media Item

struct SharedMediaItem: Identifiable, Codable {
    let id: String
    let messageType: MessageType
    let url: String
    let thumbnailUrl: String?
    let filename: String?
    let mimeType: String?
    let fileSize: Int?
    let durationSeconds: Int?
    let senderId: String
    let timestamp: Date
}
