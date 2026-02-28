import Foundation

// MARK: - Post Status
enum PostStatus: String, Codable {
    case uploading = "uploading"
    case posted = "posted"
    case failed = "failed"
}

// MARK: - Feed Type (for caching)
enum FeedType: String {
    case local = "local"
    case friends = "friends"
    case recommended = "recommended"
}

// MARK: - Local Post Draft (before server response)
struct LocalPostDraft {
    let clientPostId: String
    let authorId: String
    let authorUsername: String
    let authorAvatar: String?
    let content: String
    let imageUrl: String?        // Legacy single image
    let imageUrls: [String]?     // ✅ Multi-image support
    let visibility: String
    let latitude: Double?
    let longitude: Double?
    let status: PostStatus
    let timestamp: Date
    var initialSend: String? = "internet"
    
    // Voice post fields
    var voiceUrl: String?
    var voiceDuration: Int?
    var waveform: [Float]?
    
    func asPost() -> Post {
        // Create media array from imageUrls (or fallback to single imageUrl)
        let mediaItems: [PostMedia]?
        if let urls = imageUrls, !urls.isEmpty {
            mediaItems = urls.enumerated().map { idx, url in
                PostMedia(id: "\(clientPostId)_\(idx)", url: url, orderIndex: idx, mediaType: "image", thumbnailUrl: nil, topComments: nil)
            }
        } else if let url = imageUrl {
            mediaItems = [PostMedia(id: "\(clientPostId)_0", url: url, orderIndex: 0, mediaType: "image", thumbnailUrl: nil, topComments: nil)]
        } else {
            mediaItems = nil
        }
        
        // Determine post type based on content
        let resolvedPostType = voiceUrl != nil ? "voice" : "text"
        
        var post = Post(
            id: clientPostId,  // Use client ID temporarily
            authorId: authorId,
            authorUsername: authorUsername,
            authorAvatar: authorAvatar,
            content: content,
            imageUrl: imageUrl,
            timestamp: timestamp,
            editedAt: nil,
            likes: 0,
            comments: 0,
            reposts: 0,
            viewCount: 0,
            isLocal: visibility == "local",
            isLiked: false,
            isReposted: false,
            visibility: visibility,
            distanceM: nil,
            postType: resolvedPostType,
            roomId: nil,
            source: visibility == "local" ? .nearby : nil
        )
        post.initialSend = initialSend ?? (status == .posted ? "internet" : nil)
        post.isVerified = AuthService.shared.currentUser?.isVerified ?? false
        post.isPremium = PremiumLimits.isPremium
        post.media = mediaItems
        post.voiceUrl = voiceUrl
        post.voiceDuration = voiceDuration
        post.waveform = waveform
        return post
    }
}

// MARK: - Post Repository
actor PostRepository {
    static let shared = PostRepository()
    
    private let db = DatabaseService.shared
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    private init() {}
    
    // MARK: - Insert Local Draft (before upload)
    
    func insertDraft(_ draft: LocalPostDraft, feedType: FeedType) async throws {
        // Encode media to JSON for persistence
        var mediaJson: String? = nil
        if let media = draft.imageUrls, !media.isEmpty {
            let mediaItems = media.enumerated().map { idx, url in
                PostMedia(id: "\(draft.clientPostId)_\(idx)", url: url, orderIndex: idx, mediaType: "image", thumbnailUrl: nil, topComments: nil)
            }
            if let data = try? JSONEncoder().encode(mediaItems) {
                mediaJson = String(data: data, encoding: .utf8)
            }
        }
        
        let sql = """
            INSERT OR REPLACE INTO posts (
                id, client_post_id, author_id, author_username, author_avatar,
                content, image_url, visibility, latitude, longitude,
                likes, comments, reposts, view_count, is_local,
                is_liked, is_reposted, source, status, feed_type, timestamp,
                initial_send, media_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        
        let params: [Any] = [
            draft.clientPostId,
            draft.clientPostId,
            draft.authorId,
            draft.authorUsername,
            draft.authorAvatar ?? NSNull(),
            draft.content,
            draft.imageUrl ?? NSNull(),
            draft.visibility,
            draft.latitude ?? NSNull(),
            draft.longitude ?? NSNull(),
            0, 0, 0, 0,  // likes, comments, reposts, viewCount
            draft.visibility == "local" ? 1 : 0,
            0, 0,  // isLiked, isReposted
            draft.visibility == "local" ? "nearby" : NSNull(),
            draft.status.rawValue,
            feedType.rawValue,
            dateFormatter.string(from: draft.timestamp),
            draft.initialSend ?? NSNull(),
            mediaJson ?? NSNull()
        ]
        
        try await db.execute(sql, params: params)
        #if DEBUG
        print("💾 Saved draft post: \(draft.clientPostId)")
        #endif
    }
    
    // MARK: - Upsert Post (from server response)
    
    func upsert(_ post: Post, feedType: FeedType) async throws {
        // Encode media to JSON for persistence
        var mediaJson: String? = nil
        if let media = post.media, !media.isEmpty {
            if let data = try? JSONEncoder().encode(media) {
                mediaJson = String(data: data, encoding: .utf8)
            }
        }
        
        let sql = """
            INSERT OR REPLACE INTO posts (
                id, client_post_id, author_id, author_username, author_avatar,
                content, image_url, visibility, distance_m,
                likes, comments, reposts, view_count, is_local,
                is_liked, is_reposted, source, status, feed_type, timestamp, edited_at,
                is_verified, is_premium, initial_send, media_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        
        let params: [Any] = [
            post.id,
            NSNull(),  // client_post_id is null for server posts
            post.authorId,
            post.authorUsername,
            post.authorAvatar ?? NSNull(),
            post.content,
            post.imageUrl ?? NSNull(),
            post.visibility ?? NSNull(),
            post.distanceM ?? NSNull(),
            post.likes,
            post.comments,
            post.reposts,
            post.viewCount,
            post.isLocal ? 1 : 0,
            post.isLiked ? 1 : 0,
            post.isReposted ? 1 : 0,
            post.source?.rawValue ?? NSNull(),
            PostStatus.posted.rawValue,
            feedType.rawValue,
            dateFormatter.string(from: post.timestamp),
            post.editedAt.map { dateFormatter.string(from: $0) } ?? NSNull(),
            post.verifiedStatus ? 1 : 0,
            post.premiumStatus ? 1 : 0,
            post.initialSend ?? NSNull(),
            mediaJson ?? NSNull()
        ]
        
        try await db.execute(sql, params: params)
    }
    
    // MARK: - Bulk Upsert (after feed fetch)
    
    func upsertAll(_ posts: [Post], feedType: FeedType) async throws {
        try await db.executeInTransaction { db in
            for post in posts {
                // Encode media to JSON for persistence
                var mediaJson: String? = nil
                if let media = post.media, !media.isEmpty {
                    if let data = try? JSONEncoder().encode(media) {
                        mediaJson = String(data: data, encoding: .utf8)
                    }
                }
                
                // Inline the upsert SQL within the transaction
                let sql = """
                    INSERT OR REPLACE INTO posts (
                        id, client_post_id, author_id, author_username, author_avatar,
                        content, image_url, visibility, distance_m,
                        likes, comments, reposts, view_count, is_local,
                        is_liked, is_reposted, source, status, feed_type, timestamp, edited_at,
                        is_verified, is_premium, initial_send, media_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
                
                let params: [Any] = [
                    post.id,
                    NSNull(),
                    post.authorId,
                    post.authorUsername,
                    post.authorAvatar ?? NSNull(),
                    post.content,
                    post.imageUrl ?? NSNull(),
                    post.visibility ?? NSNull(),
                    post.distanceM ?? NSNull(),
                    post.likes,
                    post.comments,
                    post.reposts,
                    post.viewCount,
                    post.isLocal ? 1 : 0,
                    post.isLiked ? 1 : 0,
                    post.isReposted ? 1 : 0,
                    post.source?.rawValue ?? NSNull(),
                    PostStatus.posted.rawValue,
                    feedType.rawValue,
                    self.dateFormatter.string(from: post.timestamp),
                    post.editedAt.map { self.dateFormatter.string(from: $0) } ?? NSNull(),
                    post.verifiedStatus ? 1 : 0,
                    post.premiumStatus ? 1 : 0,
                    post.initialSend ?? NSNull(),
                    mediaJson ?? NSNull()
                ]
                
                try db.execute(sql, params: params)
            }
        }
        #if DEBUG
        print("💾 Saved \(posts.count) posts to cache (feedType: \(feedType.rawValue))")
        #endif
    }
    
    // MARK: - Upsert Mesh Post (received via BLE mesh)
    
    func upsertMeshPost(_ post: Post, meshStatus: MeshPostStatus) async throws {
        let sql = """
            INSERT OR REPLACE INTO posts (
                id, client_post_id, author_id, author_username, author_avatar,
                content, image_url, visibility, distance_m,
                likes, comments, reposts, view_count, is_local,
                is_liked, is_reposted, source, status, feed_type, timestamp,
                mesh_status, mesh_broadcast_stopped,
                is_verified, is_premium, initial_send
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        
        let params: [Any] = [
            post.id,
            post.id,  // client_post_id = id for mesh posts
            post.authorId,
            post.authorUsername,
            post.authorAvatar ?? NSNull(),
            post.content,
            post.imageUrl ?? NSNull(),
            post.visibility ?? NSNull(),
            post.distanceM ?? NSNull(),
            post.likes,
            post.comments,
            post.reposts,
            post.viewCount,
            post.isLocal ? 1 : 0,
            post.isLiked ? 1 : 0,
            post.isReposted ? 1 : 0,
            post.source?.rawValue ?? "nearby",
            PostStatus.posted.rawValue,
            FeedType.local.rawValue,
            dateFormatter.string(from: post.timestamp),
            meshStatus.rawValue,
            0,  // mesh_broadcast_stopped = false initially
            post.verifiedStatus ? 1 : 0,
            post.premiumStatus ? 1 : 0,
            post.initialSend ?? "mesh"
        ]
        
        try await db.execute(sql, params: params)
        #if DEBUG
        print("📡 Saved mesh post: \(post.id.prefix(8))...")
        #endif
    }
    
    // MARK: - Update Status (after upload success/failure)
    
    func updateStatus(clientPostId: String, serverId: String?, status: PostStatus) async throws {
        if let serverId = serverId {
            // Replace client ID with server ID
            let sql = """
                UPDATE posts SET id = ?, status = ? WHERE client_post_id = ?
            """
            try await db.execute(sql, params: [serverId, status.rawValue, clientPostId])
        } else {
            let sql = """
                UPDATE posts SET status = ? WHERE client_post_id = ?
            """
            try await db.execute(sql, params: [status.rawValue, clientPostId])
        }
        #if DEBUG
        print("💾 Updated post status: \(clientPostId) → \(status.rawValue)")
        #endif
    }
    
    // MARK: - Get All Posts (for cache restore)
    
    func getAllPosts(feedType: FeedType) async throws -> [Post] {
        let sql = """
            SELECT * FROM posts 
            WHERE feed_type = ? AND status != 'failed'
            ORDER BY timestamp DESC
            LIMIT 100
        """
        
        let rows = try await db.query(sql, params: [feedType.rawValue])
        return rows.compactMap { parsePost(from: $0) }
    }
    
    // MARK: - Get Pending Posts (uploads that failed/pending)
    
    func getPendingPosts() async throws -> [Post] {
        let sql = """
            SELECT * FROM posts WHERE status IN ('uploading', 'failed') ORDER BY timestamp DESC
        """
        
        let rows = try await db.query(sql, params: [])
        return rows.compactMap { parsePost(from: $0) }
    }
    
    // MARK: - Delete Old Posts (cache cleanup)
    
    func deleteOldPosts(olderThan days: Int = 7) async throws {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let sql = """
            DELETE FROM posts WHERE timestamp < ? AND status = 'posted'
        """
        try await db.execute(sql, params: [dateFormatter.string(from: cutoffDate)])
        #if DEBUG
        print("🧹 Cleaned up posts older than \(days) days")
        #endif
    }
    
    // MARK: - Clear Feed Cache
    
    func clearCache(feedType: FeedType) async throws {
        let sql = "DELETE FROM posts WHERE feed_type = ? AND status = 'posted'"
        try await db.execute(sql, params: [feedType.rawValue])
        #if DEBUG
        print("🧹 Cleared cache for \(feedType.rawValue)")
        #endif
    }
    
    // MARK: - Delete Single Post (after user deletion)
    
    func delete(postId: String) async throws {
        let sql = "DELETE FROM posts WHERE id = ? OR client_post_id = ?"
        try await db.execute(sql, params: [postId, postId])
        #if DEBUG
        print("🗑️ Deleted post from cache: \(postId.prefix(8))...")
        #endif
    }
    
    // MARK: - Parse Post from DB Row
    
    private func parsePost(from row: [String: Any]) -> Post? {
        guard let id = row["id"] as? String,
              let authorId = row["author_id"] as? String,
              let authorUsername = row["author_username"] as? String,
              let timestampStr = row["timestamp"] as? String,
              let timestamp = dateFormatter.date(from: timestampStr) else {
            return nil
        }
        
        let editedAt: Date?
        if let editedAtStr = row["edited_at"] as? String {
            editedAt = dateFormatter.date(from: editedAtStr)
        } else {
            editedAt = nil
        }
        
        let source: PostSource?
        if let sourceStr = row["source"] as? String {
            source = PostSource(rawValue: sourceStr)
        } else {
            source = nil
        }
        
        var media: [PostMedia]? = nil
        if let mediaJsonStr = row["media_json"] as? String, let data = mediaJsonStr.data(using: .utf8) {
            media = try? JSONDecoder().decode([PostMedia].self, from: data)
        }
        
        var post = Post(
            id: id,
            authorId: authorId,
            authorUsername: authorUsername,
            authorAvatar: row["author_avatar"] as? String,
            content: (row["content"] as? String) ?? "",
            imageUrl: row["image_url"] as? String,
            timestamp: timestamp,
            editedAt: editedAt,
            likes: Int(row["likes"] as? Int64 ?? 0),
            comments: Int(row["comments"] as? Int64 ?? 0),
            reposts: Int(row["reposts"] as? Int64 ?? 0),
            viewCount: Int(row["view_count"] as? Int64 ?? 0),
            isLocal: (row["is_local"] as? Int64 ?? 0) == 1,
            isLiked: (row["is_liked"] as? Int64 ?? 0) == 1,
            isReposted: (row["is_reposted"] as? Int64 ?? 0) == 1,
            visibility: row["visibility"] as? String,
            distanceM: (row["distance_m"] as? Int64).map { Int($0) },
            postType: row["post_type"] as? String ?? "text",
            roomId: row["room_id"] as? String,
            source: source,
            isVerified: (row["is_verified"] as? Int64 ?? 0) == 1,
            isPremium: (row["is_premium"] as? Int64 ?? 0) == 1
        )
        post.initialSend = row["initial_send"] as? String
        post.media = media
        return post
    }
}
