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
    
    /// Build a `Post` from this draft. `isVerified` is passed in by the
    /// caller because `AuthService.shared.currentUser` is now
    /// `@MainActor`-isolated (2026-05-10) — keeping `asPost()` itself
    /// non-isolated lets the existing call sites on `FeedStore` (which
    /// is already main-bound) snapshot the value once and hand it down,
    /// without forcing every caller of this struct method to `await`.
    func asPost(isVerified: Bool = false) -> Post {
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
        post.isVerified = isVerified
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
        
        // BUG FIX (2026-05-10): switched from `INSERT OR REPLACE` to
        // `INSERT … ON CONFLICT(id) DO UPDATE SET …` for the columns
        // we know are server-owned. The previous `OR REPLACE` form
        // performed an internal `DELETE+INSERT` cycle, wiping
        // mesh-only columns (mesh_status, mesh_broadcast_stopped,
        // latitude, longitude, show_on_raven_shot, vault_lock) every
        // time a server-feed refresh touched the row — RavenShot map
        // pins received earlier over BLE silently disappeared after
        // the next /api/feed poll. Listing only server-owned columns
        // in DO UPDATE SET preserves mesh metadata across refreshes.
        let sql = """
            INSERT INTO posts (
                id, client_post_id, author_id, author_username, author_avatar,
                content, image_url, visibility, distance_m,
                likes, comments, reposts, view_count, is_local,
                is_liked, is_reposted, source, status, feed_type, post_type, timestamp, edited_at,
                is_verified, is_premium, initial_send, media_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                author_id      = excluded.author_id,
                author_username= excluded.author_username,
                author_avatar  = excluded.author_avatar,
                content        = excluded.content,
                image_url      = excluded.image_url,
                visibility     = excluded.visibility,
                distance_m     = excluded.distance_m,
                likes          = excluded.likes,
                comments       = excluded.comments,
                reposts        = excluded.reposts,
                view_count     = excluded.view_count,
                is_local       = excluded.is_local,
                is_liked       = excluded.is_liked,
                is_reposted    = excluded.is_reposted,
                source         = excluded.source,
                status         = excluded.status,
                feed_type      = excluded.feed_type,
                post_type      = excluded.post_type,
                timestamp      = excluded.timestamp,
                edited_at      = excluded.edited_at,
                is_verified    = excluded.is_verified,
                is_premium     = excluded.is_premium,
                initial_send   = excluded.initial_send,
                media_json     = excluded.media_json
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
            post.postType ?? "text",
            dateFormatter.string(from: post.timestamp),
            post.editedAt.map { dateFormatter.string(from: $0) } ?? NSNull(),
            post.verifiedStatus ? 1 : 0,
            post.premiumStatus ? 1 : 0,
            post.initialSend ?? NSNull(),
            mediaJson ?? NSNull()
        ]
        
        try await db.execute(sql, params: params)
        #if DEBUG
        if post.postType == "video" || post.allMedia.contains(where: { $0.isVideo }) {
            print("🎬💾 [PostRepo] UPSERT post_type='\(post.postType ?? "nil")' media_types=\(post.media?.map(\.mediaType) ?? []) id=\(post.id.prefix(8)) mediaJson=\(mediaJson?.prefix(100) ?? "nil")")
        }
        #endif
    }
    
    // MARK: - Bulk Upsert (after feed fetch)
    
    func upsertAll(_ posts: [Post], feedType: FeedType) async throws {
        // ISO8601DateFormatter is not Sendable, so format the dates here
        // (still inside the actor) and ship plain strings into the
        // transaction closure.
        let formatted: [(post: Post, timestamp: String, editedAt: String?)] = posts.map {
            ($0,
             dateFormatter.string(from: $0.timestamp),
             $0.editedAt.map { dateFormatter.string(from: $0) })
        }
        try await db.executeInTransaction { db in
            for (post, timestampString, editedAtString) in formatted {
                // Encode media to JSON for persistence
                var mediaJson: String? = nil
                if let media = post.media, !media.isEmpty {
                    if let data = try? JSONEncoder().encode(media) {
                        mediaJson = String(data: data, encoding: .utf8)
                    }
                }
                
                // BUG FIX (2026-05-10): same `INSERT OR REPLACE` →
                // `ON CONFLICT(id) DO UPDATE SET …` migration the
                // single-row `upsert(_:feedType:)` got. The previous
                // bulk path was overlooked, so every server-feed
                // refresh that hit `upsertAll` (the typical /api/feed
                // poll) re-introduced the bug, wiping mesh-only
                // columns (mesh_status, mesh_broadcast_stopped,
                // latitude, longitude, show_on_raven_shot, vault_lock)
                // and dropping RavenShot map pins received earlier
                // over BLE.
                let sql = """
                    INSERT INTO posts (
                        id, client_post_id, author_id, author_username, author_avatar,
                        content, image_url, visibility, distance_m,
                        likes, comments, reposts, view_count, is_local,
                        is_liked, is_reposted, source, status, feed_type, post_type, timestamp, edited_at,
                        is_verified, is_premium, initial_send, media_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        author_id      = excluded.author_id,
                        author_username= excluded.author_username,
                        author_avatar  = excluded.author_avatar,
                        content        = excluded.content,
                        image_url      = excluded.image_url,
                        visibility     = excluded.visibility,
                        distance_m     = excluded.distance_m,
                        likes          = excluded.likes,
                        comments       = excluded.comments,
                        reposts        = excluded.reposts,
                        view_count     = excluded.view_count,
                        is_local       = excluded.is_local,
                        is_liked       = excluded.is_liked,
                        is_reposted    = excluded.is_reposted,
                        source         = excluded.source,
                        status         = excluded.status,
                        feed_type      = excluded.feed_type,
                        post_type      = excluded.post_type,
                        timestamp      = excluded.timestamp,
                        edited_at      = excluded.edited_at,
                        is_verified    = excluded.is_verified,
                        is_premium     = excluded.is_premium,
                        initial_send   = excluded.initial_send,
                        media_json     = excluded.media_json
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
                    post.postType ?? "text",
                    timestampString,
                    editedAtString ?? NSNull(),
                    post.verifiedStatus ? 1 : 0,
                    post.premiumStatus ? 1 : 0,
                    post.initialSend ?? NSNull(),
                    mediaJson ?? NSNull()
                ]
                
                try db.execute(sql, params: params)
            }
        }
        #if DEBUG
        let videoCount = posts.filter { $0.postType == "video" || $0.allMedia.contains(where: { $0.isVideo }) }.count
        print("💾 Saved \(posts.count) posts to cache (feedType: \(feedType.rawValue), videos: \(videoCount))")
        for vp in posts where vp.postType == "video" || vp.allMedia.contains(where: { $0.isVideo }) {
            print("🎬💾 [PostRepo] BULK UPSERT post_type='\(vp.postType ?? "nil")' media_types=\(vp.media?.map(\.mediaType) ?? []) id=\(vp.id.prefix(8))")
        }
        #endif
    }
    
    // MARK: - Upsert Mesh Post (received via BLE mesh)
    
    func upsertMeshPost(_ post: Post, meshStatus: MeshPostStatus) async throws {
        let sql = """
            INSERT OR REPLACE INTO posts (
                id, client_post_id, author_id, author_username, author_avatar,
                content, image_url, visibility, distance_m,
                likes, comments, reposts, view_count, is_local,
                is_liked, is_reposted, source, status, feed_type, post_type, timestamp,
                mesh_status, mesh_broadcast_stopped,
                is_verified, is_premium, initial_send,
                latitude, longitude, show_on_raven_shot
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            post.postType ?? "text",
            dateFormatter.string(from: post.timestamp),
            meshStatus.rawValue,
            0,  // mesh_broadcast_stopped = false initially
            post.verifiedStatus ? 1 : 0,
            post.premiumStatus ? 1 : 0,
            post.initialSend ?? "mesh",
            post.latitude ?? NSNull(),
            post.longitude ?? NSNull(),
            (post.showOnRavenShot ?? false) ? 1 : 0,
        ]

        try await db.execute(sql, params: params)
        #if DEBUG
        print("📡 Saved mesh post: \(post.id.prefix(8))...")
        #endif
    }

    /// Mesh-only RavenShot reader: returns posts received via BLE that
    /// opted-in to the social map AND carry coordinates. Used by
    /// `RavenShotStore` so the map populates even with no internet.
    func getMeshPostsForRavenShot(limit: Int = 100) async throws -> [Post] {
        let sql = """
            SELECT * FROM posts
            WHERE show_on_raven_shot = 1
              AND latitude IS NOT NULL
              AND longitude IS NOT NULL
              AND mesh_status IS NOT NULL
            ORDER BY timestamp DESC
            LIMIT ?
        """
        let rows = try await db.query(sql, params: [limit])
        return rows.compactMap { parsePost(from: $0) }
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
    
    // MARK: - Get Recent Posts (fast shallow query for cache warming)
    
    /// Fast shallow query — only fetches top N posts for instant cache warm on cold start.
    /// Lighter than getAllPosts (which fetches 100) — designed to fill ~3 screens immediately.
    func getRecentPosts(feedType: FeedType, limit: Int = 30) async throws -> [Post] {
        let sql = """
            SELECT * FROM posts 
            WHERE feed_type = ? AND status != 'failed'
            ORDER BY timestamp DESC
            LIMIT ?
        """
        let rows = try await db.query(sql, params: [feedType.rawValue, limit])
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
            do {
                media = try JSONDecoder().decode([PostMedia].self, from: data)
            } catch {
                #if DEBUG
                print("⚠️🎬 [PostRepo] media_json DECODE FAILED for id=\(id.prefix(8)): \(error)")
                print("⚠️🎬 [PostRepo] raw media_json: \(mediaJsonStr.prefix(200))")
                #endif
            }
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
        
        // 🛡️ Defense-in-depth: If media_json shows video content but post_type
        // was NULL/text (legacy data before Migration 22), auto-correct at read time.
        let dbPostType = row["post_type"] as? String
        if (dbPostType == nil || dbPostType == "text"),
           media?.contains(where: { $0.isVideo }) == true {
            post = Post(
                id: post.id, authorId: post.authorId, authorUsername: post.authorUsername,
                authorAvatar: post.authorAvatar, content: post.content, imageUrl: post.imageUrl,
                timestamp: post.timestamp, editedAt: post.editedAt, likes: post.likes,
                comments: post.comments, reposts: post.reposts, viewCount: post.viewCount,
                isLocal: post.isLocal, isLiked: post.isLiked, isReposted: post.isReposted,
                visibility: post.visibility, distanceM: post.distanceM,
                postType: "video",  // ← auto-corrected
                roomId: post.roomId, source: post.source,
                isVerified: post.isVerified, isPremium: post.isPremium
            )
            post.initialSend = row["initial_send"] as? String
            post.media = media
            #if DEBUG
            print("🎬🛡️ [PostRepo] AUTO-CORRECTED post_type NULL→'video' for id=\(id.prefix(8))")
            #endif
        }
        #if DEBUG
        if dbPostType == "video" || media?.contains(where: { $0.isVideo }) == true {
            print("🎬📖 [PostRepo] PARSE post_type='\(dbPostType ?? "NULL")' resolved='\(post.postType ?? "nil")' media_types=\(media?.map(\.mediaType) ?? []) id=\(id.prefix(8))")
        }
        #endif
        return post
    }
}
