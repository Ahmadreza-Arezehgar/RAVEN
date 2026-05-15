//
//  MeshSeenPostsRepository.swift
//  RAVEN
//
//  Deduplication cache for mesh-received posts
//  Prevents the same post from being processed multiple times
//

import Foundation

// MARK: - Mesh Seen Posts Repository

actor MeshSeenPostsRepository {
    static let shared = MeshSeenPostsRepository()
    
    private let db = DatabaseService.shared
    
    /// Default TTL for seen posts (7 days)
    private let defaultTTLSeconds: TimeInterval = 7 * 24 * 60 * 60
    
    private init() {}
    
    // MARK: - Check if Post Seen
    
    /// Check if we've already seen this post via mesh
    func hasSeenPost(postId: String) async -> Bool {
        let sql = """
            SELECT 1 FROM mesh_seen_posts 
            WHERE post_id = ? AND expires_at > ?
            LIMIT 1
        """
        
        do {
            let results = try await db.query(sql, params: [postId, Date().timeIntervalSince1970])
            return !results.isEmpty
        } catch {
            #if DEBUG
            print("⚠️ [MeshSeenPosts] Query error: \(error)")
            #endif
            return false
        }
    }
    
    // MARK: - Mark Post as Seen
    
    /// Mark a post as seen with optional custom TTL
    func markSeen(postId: String, ttlSeconds: TimeInterval? = nil) async {
        let now = Date().timeIntervalSince1970
        let ttl = ttlSeconds ?? defaultTTLSeconds
        let expiresAt = now + ttl
        
        let sql = """
            INSERT OR REPLACE INTO mesh_seen_posts (post_id, first_seen_at, expires_at)
            VALUES (?, ?, ?)
        """
        
        do {
            try await db.execute(sql, params: [postId, now, expiresAt])
            #if DEBUG
            print("📝 [MeshSeenPosts] Marked seen: \(postId.prefix(8))...")
            #endif
        } catch {
            #if DEBUG
            print("⚠️ [MeshSeenPosts] Failed to mark seen: \(error)")
            #endif
        }
    }
    
    // MARK: - Clean Expired Entries
    
    /// Remove expired entries from the cache
    func cleanExpired() async {
        let sql = "DELETE FROM mesh_seen_posts WHERE expires_at < ?"
        
        do {
            try await db.execute(sql, params: [Date().timeIntervalSince1970])
            #if DEBUG
            print("🧹 [MeshSeenPosts] Cleaned expired entries")
            #endif
        } catch {
            #if DEBUG
            print("⚠️ [MeshSeenPosts] Cleanup error: \(error)")
            #endif
        }
    }
    
    // MARK: - Get All Seen Post IDs (for debugging)
    
    func getAllSeenPostIds() async -> [String] {
        let sql = """
            SELECT post_id FROM mesh_seen_posts 
            WHERE expires_at > ?
            ORDER BY first_seen_at DESC
        """
        
        do {
            let results = try await db.query(sql, params: [Date().timeIntervalSince1970])
            return results.compactMap { $0["post_id"] as? String }
        } catch {
            return []
        }
    }
    
    // MARK: - Count (for debugging)
    
    func count() async -> Int {
        let sql = "SELECT COUNT(*) as cnt FROM mesh_seen_posts WHERE expires_at > ?"
        
        do {
            let results = try await db.query(sql, params: [Date().timeIntervalSince1970])
            if let row = results.first, let count = row["cnt"] as? Int64 {
                return Int(count)
            }
        } catch {
            #if DEBUG
            print("⚠️ [MeshSeenPosts] count() failed: \(error)")
            #endif
        }

        return 0
    }
}
