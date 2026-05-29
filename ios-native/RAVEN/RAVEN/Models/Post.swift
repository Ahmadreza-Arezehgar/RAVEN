import Foundation

// MARK: - Post Source (for merged Local feed)
enum PostSource: String, Codable {
    case nearby = "nearby"
    case forYou = "for_you"
    case recommended = "recommended"
}

// MARK: - Post Media (for multi-image posts)
// Note: No CodingKeys needed — NetworkService's decoder uses .convertFromSnakeCase
struct PostMedia: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let url: String
    let orderIndex: Int
    let mediaType: String?  // "image" | "video"
    let thumbnailUrl: String?  // Required for videos (cover frame)
    var topComments: [TopComment]?  // Top 3 comments for this media
    
    /// Defensive video detection — checks mediaType AND URL shape.
    /// Prevents video URLs from being rendered as broken images when mediaType is nil.
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "webm", "mkv"]

    /// URL path segments that indicate video content. Used as a
    /// secondary heuristic when the `mediaType` field is missing AND
    /// the URL no longer carries a recognizable file extension (e.g.
    /// because a CDN rewrite or signed-URL proxy stripped it, or the
    /// uploader stored the file with a UUID-only filename).
    private static let videoPathSegments: Set<String> = ["videos", "video_notes"]

    var isVideo: Bool {
        // 1. Trust the server-supplied media_type when present.
        if mediaType?.lowercased() == "video" { return true }

        // 2. Strip query params (signed-URL X-Goog-... tail) before
        //    extracting the file extension or path segments.
        let cleanUrl = url.components(separatedBy: "?").first ?? url
        let ext = (cleanUrl as NSString).pathExtension.lowercased()
        if Self.videoExtensions.contains(ext) { return true }

        // 3. 🔴 ROUND 29 (2026-05-17) — path-segment fallback.
        //    Some upload pipelines (CDN rewrites, signed-URL proxies,
        //    legacy /files/ migrations) drop the .mp4 extension from
        //    the public URL. Without this check, a perfectly good
        //    video at `https://.../videos/<uuid>` was rendering as a
        //    broken AsyncImage because pathExtension returned "".
        //    The `videos/` and `video_notes/` GCS prefixes are the
        //    server-side source-of-truth — any URL containing one of
        //    them is, by construction, a video.
        if let lower = cleanUrl.lowercased() as String? {
            for segment in Self.videoPathSegments {
                if lower.contains("/\(segment)/") { return true }
            }
        }
        return false
    }
    
    // Top comment preview for per-media display
    // Note: No CodingKeys needed — NetworkService's decoder uses .convertFromSnakeCase
    struct TopComment: Identifiable, Codable, Equatable, Hashable {
        let id: String
        let authorName: String
        let authorAvatar: String?
        let content: String
        let likes: Int
    }
}

// MARK: - Tagged User in Post
struct PostTagUser: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let username: String
    let avatarPath: String?
}

// MARK: - Post Model
struct Post: Identifiable, Codable, Equatable, Hashable {
    var id: String
    let authorId: String
    let authorUsername: String
    let authorAvatar: String?
    let content: String
    let imageUrl: String?  // Legacy single image (backward compatibility)
    let timestamp: Date
    let editedAt: Date?
    var likes: Int
    var comments: Int
    var reposts: Int
    var viewCount: Int
    let isLocal: Bool
    var isLiked: Bool
    var isReposted: Bool
    /// Server-side bookmark state. Defaulted because legacy server
    /// responses (before the `post_bookmarks` table) don't include it.
    var isBookmarked: Bool? = nil
    
    // NEW: Multi-image support (max 4)
    var media: [PostMedia]?
    
    // NEW: Visibility and location fields
    let visibility: String?  // "public", "friends", "local"
    let distanceM: Int?      // Rounded distance in meters (local feed only)
    
    // NEW: Room post support
    let postType: String?    // "text", "image", "room", "voice", "voice_chain"
    let roomId: String?      // FK to AudioRoom if postType == "room"
    
    // Voice post fields
    var voiceUrl: String?
    var voiceDuration: Int?
    var waveform: [Float]?
    
    // Collaborative post fields (chain publish)
    var coAuthors: [String]?
    var coAuthorUsernames: [String]?
    var originChainId: String?
    
    // Voice transcription (on-demand)
    var transcriptText: String?
    var transcriptStatus: String?      // "none"|"pending"|"processing"|"ready"|"failed"
    var transcriptLanguage: String?
    
    // NEW: Source for merged Local feed
    var source: PostSource?
    
    // NEW: Mesh status for offline-sent posts
    var meshStatus: String?  // "queued_mesh", "broadcasting", "synced"
    
    // NEW: Vault lock for location-encrypted posts
    var vaultLock: VaultLock?
    
    // DTN: How was this post first sent? "internet" or "mesh"
    var initialSend: String?  // "internet" | "mesh"
    
    // Location coordinates (for spatial decay in RavenRank)
    var latitude: Double?
    var longitude: Double?
    
    // Raven Shot: opt-in flag for social map display
    var showOnRavenShot: Bool?
    
    // Human-readable location name (e.g. "Starbucks, Madrid")
    var locationName: String?
    
    // Tagged users in post
    var taggedUsers: [PostTagUser]?
    
    // Author verification status
    var isVerified: Bool?
    var verified: Bool?
    var authorIsVerified: Bool?
    var authorVerified: Bool?
    var badgeType: String?
    
    // Author RAVEN+ premium status
    var isPremium: Bool?
    var premium: Bool?
    var authorIsPremium: Bool?
    var authorPremium: Bool?
    var subscriptionTier: String?
    
    var serverId: String {
        if let range = id.range(of: "-loop-") {
            return String(id[..<range.lowerBound])
        }
        return id
    }
    
    // Computed helpers — coalesce all server naming variants
    var verifiedStatus: Bool {
        isVerified == true || verified == true || authorIsVerified == true || authorVerified == true ||
        badgeType == "verified" || badgeType == "brand" || badgeType == "org"
    }
    
    var premiumStatus: Bool {
        isPremium == true || premium == true || authorIsPremium == true || authorPremium == true ||
        subscriptionTier == "premium" || subscriptionTier == "raven_plus" || subscriptionTier == "raven+"
    }
    
    // ✅ FIX Bug 3: Include dynamic fields so SwiftUI re-renders on changes.
    // NavigationLink pops are prevented by using NavigationLink(value: post.id)
    // (a stable String), so expanding Equatable here is safe.
    static func == (lhs: Post, rhs: Post) -> Bool {
        lhs.id == rhs.id &&
        lhs.likes == rhs.likes &&
        lhs.isLiked == rhs.isLiked &&
        lhs.comments == rhs.comments &&
        lhs.reposts == rhs.reposts &&
        lhs.viewCount == rhs.viewCount &&
        lhs.meshStatus == rhs.meshStatus
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    /// Get all media URLs (combines legacy imageUrl with new media array)
    var allMediaUrls: [String] {
        if let media = media, !media.isEmpty {
            return media.sorted { $0.orderIndex < $1.orderIndex }.map { $0.url }
        } else if let imageUrl = imageUrl {
            return [imageUrl]
        }
        return []
    }
    
    /// Get all media items (creates PostMedia from legacy imageUrl if needed)
    var allMedia: [PostMedia] {
        if let media = media, !media.isEmpty {
            return media.sorted { $0.orderIndex < $1.orderIndex }
        } else if let imageUrl = imageUrl {
            // Detect video URLs so they aren't incorrectly rendered as images
            let probe = PostMedia(id: id + "_0", url: imageUrl, orderIndex: 0, mediaType: nil, thumbnailUrl: nil, topComments: nil)
            let resolvedType = probe.isVideo ? "video" : "image"
            return [PostMedia(id: id + "_0", url: imageUrl, orderIndex: 0, mediaType: resolvedType, thumbnailUrl: nil, topComments: nil)]
        }
        return []
    }
    
    /// Whether post has multiple images
    var isMultiImage: Bool {
        allMedia.count > 1
    }
    
    /// Whether this is a voice post
    var isVoicePost: Bool {
        postType == "voice" || postType == "voice_chain"
    }
    
    /// Formatted distance string (e.g., "350m" or "1.2km")
    var formattedDistance: String? {
        guard let distance = distanceM else { return nil }
        if distance < 1000 {
            return "\(distance)m"
        } else {
            let km = Double(distance) / 1000.0
            return String(format: "%.1fkm", km)
        }
    }
    
    /// Creates a copy of this post with the specified source
    func withSource(_ newSource: PostSource) -> Post {
        var copy = self
        copy.source = newSource
        return copy
    }
}

// MARK: - Comment Model
struct Comment: Identifiable, Codable {
    let id: String
    let postId: String
    let authorId: String
    let authorName: String       // Server sends author_name
    let authorAvatar: String?
    var isVerified: Bool?
    var isPremium: Bool?
    var verified: Bool? = nil    // Server fallback key
    var premium: Bool? = nil     // Server fallback key
    var badgeType: String? = nil
    var subscriptionTier: String? = nil
    let parentCommentId: String?
    let content: String
    let timestamp: Date
    let score: Int
    let myVote: Int              // Server always sends this (0 means no vote)
    let isAiGenerated: Bool
    var replies: [Comment]
    
    // Media support (voice/image comments)
    var commentType: String?     // "text" | "voice" | "image"
    var mediaUrl: String?        // Image or voice URL
    var durationSec: Double?     // Voice comment duration in seconds
    
    // Voice comment transcription (on-demand)
    var transcriptText: String?
    var transcriptStatus: String?
    var transcriptLanguage: String?

    // ✏️ Edit support — non-nil when comment was edited at least once.
    // UI shows a small "edited" hint next to the timestamp.
    var editedAt: Date?

    // 📌 Pin support — `is_pinned` floats this comment to the top of its
    // post. `pinned_at` drives ordering within the pinned section.
    var isPinned: Bool? = false
    var pinnedAt: Date?

    // Computed helpers — coalesce all server naming variants
    var verifiedStatus: Bool {
        isVerified == true || verified == true || badgeType == "verified" || badgeType == "brand" || badgeType == "org"
    }
    
    var premiumStatus: Bool {
        isPremium == true || premium == true || subscriptionTier == "premium" || subscriptionTier == "raven_plus" || subscriptionTier == "raven+"
    }
    
    // Note: CodingKeys removed - NetworkService uses .convertFromSnakeCase automatically
}

// MARK: - Like Response
struct LikeResponse: Codable {
    let status: String
    let action: String
    let likes: Int
    let isLiked: Bool
    
    // Note: CodingKeys removed - NetworkService uses .convertFromSnakeCase automatically
}

// MARK: - Repost Response
struct RepostResponse: Codable {
    let status: String
    let action: String
    let reposts: Int
    let isReposted: Bool
    
    // Note: CodingKeys removed - NetworkService uses .convertFromSnakeCase automatically
}

// MARK: - View Response
struct ViewResponse: Codable {
    let ok: Bool
    let viewCount: Int
}

// MARK: - Delete Response
struct DeletePostResponse: Codable {
    let status: String
    let deleted: Bool
    let postId: String
}

// MARK: - Feed Tab
enum FeedTab: String, CaseIterable {
    case local = "Local"
    case friends = "Friends"
}

// MARK: - Paginated Feed Response (for infinite scroll)
struct PaginatedFeedResponse: Codable {
    let items: [Post]
    let hasMore: Bool
    let nextOffset: Int
    
    // Server returns camelCase keys (hasMore, nextOffset) but Swift decoder
    // uses .convertFromSnakeCase which would look for has_more / next_offset.
    // Explicit CodingKeys ensure correct mapping.
    enum CodingKeys: String, CodingKey {
        case items
        case hasMore
        case nextOffset
    }
}
