// RAVEN - Core Data Models
// Converted from Flutter to Swift
// Source: lib/models/message_model.dart, lib/models/user_model.dart

import Foundation

// MARK: - User Model
struct User: Identifiable, Codable, Equatable {
    let id: String
    let username: String
    var email: String?
    var phone: String?
    var avatarPath: String?
    var bio: String?
    let createdAt: Date
    var showUsername: Bool
    var publicKey: String?
    var firstName: String?
    var lastName: String?
    
    init(
        id: String,
        username: String,
        email: String? = nil,
        phone: String? = nil,
        avatarPath: String? = nil,
        bio: String? = nil,
        createdAt: Date = Date(),
        showUsername: Bool = true,
        publicKey: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil
    ) {
        self.id = id
        self.username = username
        self.email = email
        self.phone = phone
        self.avatarPath = avatarPath
        self.bio = bio
        self.createdAt = createdAt
        self.showUsername = showUsername
        self.publicKey = publicKey
        self.firstName = firstName
        self.lastName = lastName
    }
    
    /// Display name: "FirstName LastName" or fallback to username
    var displayName: String {
        let parts = [firstName, lastName].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let full = parts.joined(separator: " ")
        return full.isEmpty ? username : full
    }
    
    var avatarUrl: String? { avatarPath }
    
    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first }.map { String($0) }.joined().uppercased()
    }
}

// MARK: - Message Model
struct ChatMessage: Identifiable, Codable, Equatable {
    let id: String
    let roomId: String
    let senderId: String
    let senderName: String
    let recipientId: String
    var text: String
    let timestamp: Date
    var via: String
    var status: MessageStatus
    var type: MessageType
    var ttl: Int
    var routePath: [String]
    var needsForwarding: Bool
    var deliveredAt: Date?
    var readAt: Date?
    
    // DTN Mesh Networking fields
    var messageSignature: String?
    var sprayCounter: Int
    var originDeviceId: String?
    var hopCount: Int
    var hopLimit: Int
    var deliveryAuthority: DeliveryAuthority
    
    // Media fields
    var audioUrl: String?
    var imageUrl: String?
    var fileName: String?
    var mimeType: String?
    var fileSize: Int?
    var thumbnailUrl: String?
    var audioDuration: TimeInterval?
    
    // Voice transcript fields
    var transcriptText: String?
    var transcriptLang: String?
    var transcriptStatus: Int
    
    // Offline-first sync fields
    var serverId: String?
    var syncState: SyncState
    var localPath: String?
    var retryCount: Int
    var lastError: String?
    
    // Reply fields
    var replyToMessageId: String?
    var replyToText: String?
    var replyToSenderName: String?
    var replyToType: MessageType?
    
    // Like field
    var isLiked: Bool
    
    // Scheduled message fields
    var sendMode: String?
    var scheduledAtUtc: Date?
    
    init(
        id: String = UUID().uuidString,
        roomId: String,
        senderId: String,
        senderName: String,
        recipientId: String,
        text: String,
        timestamp: Date = Date(),
        via: String = "",
        status: MessageStatus = .pending,
        type: MessageType = .text,
        ttl: Int = 10,
        routePath: [String] = [],
        needsForwarding: Bool = true,
        deliveredAt: Date? = nil,
        readAt: Date? = nil,
        messageSignature: String? = nil,
        sprayCounter: Int = 5,
        originDeviceId: String? = nil,
        hopCount: Int = 0,
        hopLimit: Int = 10,
        deliveryAuthority: DeliveryAuthority = .server,
        audioUrl: String? = nil,
        imageUrl: String? = nil,
        fileName: String? = nil,
        mimeType: String? = nil,
        fileSize: Int? = nil,
        thumbnailUrl: String? = nil,
        audioDuration: TimeInterval? = nil,
        transcriptText: String? = nil,
        transcriptLang: String? = nil,
        transcriptStatus: Int = 0,
        serverId: String? = nil,
        syncState: SyncState = .localOnly,
        localPath: String? = nil,
        retryCount: Int = 0,
        lastError: String? = nil,
        replyToMessageId: String? = nil,
        replyToText: String? = nil,
        replyToSenderName: String? = nil,
        replyToType: MessageType? = nil,
        isLiked: Bool = false,
        sendMode: String? = "instant",
        scheduledAtUtc: Date? = nil
    ) {
        self.id = id
        self.roomId = roomId
        self.senderId = senderId
        self.senderName = senderName
        self.recipientId = recipientId
        self.text = text
        self.timestamp = timestamp
        self.via = via
        self.status = status
        self.type = type
        self.ttl = ttl
        self.routePath = routePath
        self.needsForwarding = needsForwarding
        self.deliveredAt = deliveredAt
        self.readAt = readAt
        self.messageSignature = messageSignature
        self.sprayCounter = sprayCounter
        self.originDeviceId = originDeviceId
        self.hopCount = hopCount
        self.hopLimit = hopLimit
        self.deliveryAuthority = deliveryAuthority
        self.audioUrl = audioUrl
        self.imageUrl = imageUrl
        self.fileName = fileName
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.thumbnailUrl = thumbnailUrl
        self.audioDuration = audioDuration
        self.transcriptText = transcriptText
        self.transcriptLang = transcriptLang
        self.transcriptStatus = transcriptStatus
        self.serverId = serverId
        self.syncState = syncState
        self.localPath = localPath
        self.retryCount = retryCount
        self.lastError = lastError
        self.replyToMessageId = replyToMessageId
        self.replyToText = replyToText
        self.replyToSenderName = replyToSenderName
        self.replyToType = replyToType
        self.isLiked = isLiked
        self.sendMode = sendMode
        self.scheduledAtUtc = scheduledAtUtc
    }
    
    func isForMe(_ myUserId: String) -> Bool {
        recipientId == myUserId || roomId == "broadcast"
    }
    
    func hasPassedThrough(_ deviceId: String) -> Bool {
        routePath.contains(deviceId)
    }
    
    func isAlive() -> Bool {
        ttl > 0
    }
    
    var mediaUrl: String? { audioUrl }
}

// MARK: - Enums
enum MessageStatus: Int, Codable, CaseIterable {
    case pending = 0
    case sending = 1
    case sent = 2
    case forwarding = 3
    case delivered = 4
    case read = 5
    case failed = 6
    case scheduled = 7
    
    var icon: String {
        switch self {
        case .pending: return "clock"
        case .sending: return "arrow.up.circle"
        case .sent: return "checkmark"
        case .forwarding: return "arrow.right.arrow.left"
        case .delivered: return "checkmark.circle"
        case .read: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        case .scheduled: return "calendar.circle"
        }
    }
}

enum MessageType: Int, Codable, CaseIterable {
    case text = 0
    case image = 1
    case file = 2
    case voice = 3
    case location = 4
    
    var icon: String {
        switch self {
        case .text: return "text.bubble"
        case .image: return "photo"
        case .file: return "doc"
        case .voice: return "waveform"
        case .location: return "location"
        }
    }
}

enum SyncState: Int, Codable {
    case localOnly = 0
    case queued = 1
    case uploading = 2
    case synced = 3
    case failed = 4
}

enum DeliveryAuthority: Int, Codable {
    case server = 0
    case mesh = 1
}

// MARK: - Conversation Model
struct Conversation: Identifiable, Codable {
    let id: String
    let recipientId: String
    let recipientName: String
    let recipientUsername: String
    let recipientAvatarUrl: String?
    var lastMessage: String
    var lastMessageType: MessageType
    var lastMessageTime: Date
    var unreadCount: Int
    var isOnline: Bool
    var isMuted: Bool
    var isPinned: Bool
    var isGroup: Bool
    
    init(
        id: String = UUID().uuidString,
        recipientId: String,
        recipientName: String,
        recipientUsername: String,
        recipientAvatarUrl: String? = nil,
        lastMessage: String = "",
        lastMessageType: MessageType = .text,
        lastMessageTime: Date = Date(),
        unreadCount: Int = 0,
        isOnline: Bool = false,
        isMuted: Bool = false,
        isPinned: Bool = false,
        isGroup: Bool = false
    ) {
        self.id = id
        self.recipientId = recipientId
        self.recipientName = recipientName
        self.recipientUsername = recipientUsername
        self.recipientAvatarUrl = recipientAvatarUrl
        self.lastMessage = lastMessage
        self.lastMessageType = lastMessageType
        self.lastMessageTime = lastMessageTime
        self.unreadCount = unreadCount
        self.isOnline = isOnline
        self.isMuted = isMuted
        self.isPinned = isPinned
        self.isGroup = isGroup
    }
}

// MARK: - Contact Model
struct Contact: Identifiable, Codable {
    let id: String
    let userId: String
    var nickname: String?
    let username: String
    var displayName: String
    var avatarUrl: String?
    var publicKey: String?
    var isBlocked: Bool
    var isFavorite: Bool
    let addedAt: Date
    
    init(
        id: String = UUID().uuidString,
        userId: String,
        nickname: String? = nil,
        username: String,
        displayName: String,
        avatarUrl: String? = nil,
        publicKey: String? = nil,
        isBlocked: Bool = false,
        isFavorite: Bool = false,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.nickname = nickname
        self.username = username
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.publicKey = publicKey
        self.isBlocked = isBlocked
        self.isFavorite = isFavorite
        self.addedAt = addedAt
    }
    
    var effectiveName: String {
        nickname ?? displayName
    }
}
