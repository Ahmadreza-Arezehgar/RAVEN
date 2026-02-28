// RAVEN - Social Models
// Converted from Flutter to Swift
// Source: lib/models/post_model.dart, lib/models/comment.dart

import Foundation

// MARK: - Post Model
struct Post: Identifiable, Codable {
    let id: String
    let authorId: String
    let authorName: String
    let authorUsername: String
    let authorAvatarUrl: String?
    var content: String
    var mediaUrls: [String]
    let createdAt: Date
    var likesCount: Int
    var commentsCount: Int
    var repostsCount: Int
    var isLiked: Bool
    var isReposted: Bool
    var isBookmarked: Bool
    var repostedBy: String?
    var originalPostId: String?
    var hashtags: [String]
    // Contact avatar preview: up to 20 user IDs for client-side intersection
    var likePreviewUserIds: [String]
    var commentPreviewUserIds: [String]
    
    enum CodingKeys: String, CodingKey {
        case id
        case authorId = "author_id"
        case authorUsername = "author_username"
        case authorAvatarUrl = "author_avatar"
        case content
        case mediaUrls = "media_urls"
        case createdAt = "timestamp"
        case likesCount = "likes"
        case commentsCount = "comments"
        case repostsCount = "reposts"
        case isLiked = "is_liked"
        case isReposted = "is_reposted"
        case isBookmarked = "is_bookmarked"
        case repostedBy = "reposted_by"
        case originalPostId = "original_post_id"
        case hashtags
        case likePreviewUserIds = "like_preview_user_ids"
        case commentPreviewUserIds = "comment_preview_user_ids"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        authorId = try container.decodeIfPresent(String.self, forKey: .authorId) ?? ""
        let username = try container.decodeIfPresent(String.self, forKey: .authorUsername) ?? "Unknown"
        authorName = username
        authorUsername = username
        authorAvatarUrl = try container.decodeIfPresent(String.self, forKey: .authorAvatarUrl)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        mediaUrls = try container.decodeIfPresent([String].self, forKey: .mediaUrls) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        likesCount = try container.decodeIfPresent(Int.self, forKey: .likesCount) ?? 0
        commentsCount = try container.decodeIfPresent(Int.self, forKey: .commentsCount) ?? 0
        repostsCount = try container.decodeIfPresent(Int.self, forKey: .repostsCount) ?? 0
        isLiked = try container.decodeIfPresent(Bool.self, forKey: .isLiked) ?? false
        isReposted = try container.decodeIfPresent(Bool.self, forKey: .isReposted) ?? false
        isBookmarked = try container.decodeIfPresent(Bool.self, forKey: .isBookmarked) ?? false
        repostedBy = try container.decodeIfPresent(String.self, forKey: .repostedBy)
        originalPostId = try container.decodeIfPresent(String.self, forKey: .originalPostId)
        hashtags = try container.decodeIfPresent([String].self, forKey: .hashtags) ?? []
        likePreviewUserIds = try container.decodeIfPresent([String].self, forKey: .likePreviewUserIds) ?? []
        commentPreviewUserIds = try container.decodeIfPresent([String].self, forKey: .commentPreviewUserIds) ?? []
    }
    
    init(
        id: String = UUID().uuidString,
        authorId: String,
        authorName: String,
        authorUsername: String,
        authorAvatarUrl: String? = nil,
        content: String,
        mediaUrls: [String] = [],
        createdAt: Date = Date(),
        likesCount: Int = 0,
        commentsCount: Int = 0,
        repostsCount: Int = 0,
        isLiked: Bool = false,
        isReposted: Bool = false,
        isBookmarked: Bool = false,
        repostedBy: String? = nil,
        originalPostId: String? = nil,
        hashtags: [String] = [],
        likePreviewUserIds: [String] = [],
        commentPreviewUserIds: [String] = []
    ) {
        self.id = id
        self.authorId = authorId
        self.authorName = authorName
        self.authorUsername = authorUsername
        self.authorAvatarUrl = authorAvatarUrl
        self.content = content
        self.mediaUrls = mediaUrls
        self.createdAt = createdAt
        self.likesCount = likesCount
        self.commentsCount = commentsCount
        self.repostsCount = repostsCount
        self.isLiked = isLiked
        self.isReposted = isReposted
        self.isBookmarked = isBookmarked
        self.repostedBy = repostedBy
        self.originalPostId = originalPostId
        self.hashtags = hashtags
        self.likePreviewUserIds = likePreviewUserIds
        self.commentPreviewUserIds = commentPreviewUserIds
    }
}

// MARK: - Comment Model
struct Comment: Identifiable, Codable {
    let id: String
    let postId: String
    let authorId: String
    let authorName: String
    let authorUsername: String
    let authorAvatarUrl: String?
    let content: String
    let createdAt: Date
    var likesCount: Int
    var isLiked: Bool
    var parentCommentId: String?
    var replies: [Comment]
    
    init(
        id: String = UUID().uuidString,
        postId: String,
        authorId: String,
        authorName: String,
        authorUsername: String,
        authorAvatarUrl: String? = nil,
        content: String,
        createdAt: Date = Date(),
        likesCount: Int = 0,
        isLiked: Bool = false,
        parentCommentId: String? = nil,
        replies: [Comment] = []
    ) {
        self.id = id
        self.postId = postId
        self.authorId = authorId
        self.authorName = authorName
        self.authorUsername = authorUsername
        self.authorAvatarUrl = authorAvatarUrl
        self.content = content
        self.createdAt = createdAt
        self.likesCount = likesCount
        self.isLiked = isLiked
        self.parentCommentId = parentCommentId
        self.replies = replies
    }
}

// MARK: - Notification Model
struct RAVENNotification: Identifiable, Codable {
    let id: String
    let type: NotificationType
    let title: String
    let body: String
    let senderId: String?
    let senderName: String?
    let senderAvatarUrl: String?
    let targetId: String?
    let timestamp: Date
    var isRead: Bool
    
    enum NotificationType: String, Codable {
        case message
        case like
        case comment
        case follow
        case mention
        case repost
        case system
        
        var icon: String {
            switch self {
            case .message: return "bubble.left.fill"
            case .like: return "heart.fill"
            case .comment: return "text.bubble.fill"
            case .follow: return "person.badge.plus"
            case .mention: return "at"
            case .repost: return "arrow.2.squarepath"
            case .system: return "bell.fill"
            }
        }
    }
    
    init(
        id: String = UUID().uuidString,
        type: NotificationType,
        title: String,
        body: String,
        senderId: String? = nil,
        senderName: String? = nil,
        senderAvatarUrl: String? = nil,
        targetId: String? = nil,
        timestamp: Date = Date(),
        isRead: Bool = false
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.body = body
        self.senderId = senderId
        self.senderName = senderName
        self.senderAvatarUrl = senderAvatarUrl
        self.targetId = targetId
        self.timestamp = timestamp
        self.isRead = isRead
    }
}

// MARK: - News Article Model
struct NewsArticle: Identifiable, Codable {
    let id: String
    let title: String
    let summary: String
    let content: String
    let imageUrl: String?
    let sourceUrl: String
    let sourceName: String
    let publishedAt: Date
    let category: String
    var isRead: Bool
    var isBookmarked: Bool
}

// MARK: - Scheduled Message
struct ScheduledMessage: Identifiable, Codable {
    let id: String
    let recipientId: String
    let recipientName: String
    let content: String
    let scheduledAt: Date
    var status: ScheduledStatus
    let createdAt: Date
    
    enum ScheduledStatus: Int, Codable {
        case pending = 0
        case sent = 1
        case failed = 2
        case cancelled = 3
    }
}
