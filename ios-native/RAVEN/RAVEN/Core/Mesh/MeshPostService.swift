//
//  MeshPostService.swift
//  RAVEN
//
//  Service for broadcasting and receiving posts via BLE Mesh
//  Text-only posts with deduplication and online sync
//

import Foundation

// Note: MeshPostStatus enum is defined in MeshPostTypes.swift

// MARK: - Mesh Post Service

actor MeshPostService {
    static let shared = MeshPostService()
    
    private let seenPosts = MeshSeenPostsRepository.shared
    private let db = DatabaseService.shared
    private let mesh: any MeshTransportProtocol
    
    // MARK: - Stopped Posts (broadcast stopped after online sync)
    
    private var stoppedPostIds: Set<String> = []
    
    init(mesh: any MeshTransportProtocol = BLEMeshEngine.shared) {
        self.mesh = mesh
    }
    
    // MARK: - Enforcement: Can Post be Broadcast via Mesh?
    
    /// Check if a post can be broadcast via mesh (text-only enforcement)
    func canBroadcastViaMesh(text: String, hasMedia: Bool) -> Bool {
        // Rule 1: Must have text content
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        
        // Rule 2: Must NOT have media (image, video, voice, file, location)
        guard !hasMedia else {
            return false
        }
        
        return true
    }
    
    // MARK: - Broadcast Post via Mesh
    
    /// Broadcast a text-only post to the mesh network
    func broadcast(post: Post) async -> Bool {
        // Get device ID for envelope
        guard let deviceId = DeviceIdentityService.shared.fingerprint else {
            #if DEBUG
            print("❌ [MeshPost] No device fingerprint available")
            #endif
            return false
        }
        
        // Convert to mesh envelope
        guard var envelope = post.toMeshPostEnvelope(originDeviceId: deviceId) else {
            #if DEBUG
            print("❌ [MeshPost] Cannot convert post to mesh envelope (has media?)")
            #endif
            return false
        }
        
        // SECURITY: Sign the envelope before broadcast
        envelope.sign()
        
        // Mark as broadcasting in DB
        await markMeshStatus(postId: post.id, status: .broadcasting)
        
        // Mark as seen locally (to prevent self-echo)
        await seenPosts.markSeen(postId: post.id, ttlSeconds: TimeInterval(envelope.ttlSeconds))
        
        // Encode and broadcast
        guard let data = try? JSONEncoder().encode(envelope) else {
            #if DEBUG
            print("❌ [MeshPost] Failed to encode envelope")
            #endif
            return false
        }
        
        await mesh.broadcastPostData(data)
        #if DEBUG
        print("📡 [MeshPost] Broadcast post \(post.id.prefix(8))... (\(data.count) bytes)")
        #endif
        
        return true
    }
    
    // MARK: - Handle Incoming Mesh Post
    
    /// Process an incoming mesh post envelope
    func handleIncoming(_ envelope: MeshPostEnvelope) async {
        let postId = envelope.postId
        
        // 1. Check if already seen (dedup)
        if await seenPosts.hasSeenPost(postId: postId) {
            #if DEBUG
            print("⚠️ [MeshPost] Already seen post \(postId.prefix(8))... - dropping")
            #endif
            return
        }
        
        // 2. Check if stopped (broadcast disabled after online sync)
        //    Check both in-memory cache AND database (survives app restart)
        var isStopped = stoppedPostIds.contains(postId)
        if !isStopped {
            isStopped = await isPostStoppedInDB(postId: postId)
        }
        if isStopped {
            stoppedPostIds.insert(postId) // Cache in memory for fast future lookups
            #if DEBUG
            print("🛑 [MeshPost] Post \(postId.prefix(8))... is stopped - dropping")
            #endif
            return
        }
        
        // 3. Check validity (TTL, hops)
        guard envelope.isValid && !envelope.isExpired else {
            #if DEBUG
            print("⚠️ [MeshPost] Post \(postId.prefix(8))... expired or exhausted - dropping")
            #endif
            return
        }
        
        // 4. Mark as seen
        await seenPosts.markSeen(postId: postId, ttlSeconds: TimeInterval(envelope.ttlSeconds))
        
        // 5. Convert to Post and save locally
        let post = envelope.toPost()
        do {
            try await PostRepository.shared.upsertMeshPost(post, meshStatus: .broadcasting)
            #if DEBUG
            print("📥 [MeshPost] Saved mesh post: \(postId.prefix(8))...")
            #endif
        } catch {
            #if DEBUG
            print("❌ [MeshPost] Failed to save: \(error)")
            #endif
        }
        
        // 6. Notify UI (post notification for FeedStore to pick up)
        await MainActor.run {
            NotificationCenter.default.post(
                name: .meshPostReceived,
                object: nil,
                userInfo: ["post": post]
            )
            
            // 7. Record view receipt for offline sync
            MeshViewReceiptService.shared.recordView(for: envelope)
        }
        
        // 8. Forward (relay) to other mesh peers
        await relayIfNeeded(envelope)
    }
    
    // MARK: - Relay to Other Peers
    
    private func relayIfNeeded(_ envelope: MeshPostEnvelope) async {
        // Check if we should forward
        guard envelope.hopCount < envelope.ttlHops - 1 else {
            #if DEBUG
            print("🌉 [MeshPost] Hop limit reached - not relaying")
            #endif
            return
        }
        
        // Get my device ID and add to route
        guard let myDeviceId = DeviceIdentityService.shared.fingerprint else { return }
        
        // Check if already passed through this device
        if envelope.hasPassedThrough(deviceId: myDeviceId) {
            #if DEBUG
            print("🌉 [MeshPost] Already relayed by this device - skipping")
            #endif
            return
        }
        
        // Create forwarded envelope
        let forwarded = envelope.forwarded(by: myDeviceId)
        
        // Encode and broadcast
        guard let data = try? JSONEncoder().encode(forwarded) else { return }
        
        await mesh.broadcastPostData(data)
        #if DEBUG
        print("🌉 [MeshPost] Relayed post \(envelope.postId.prefix(8))... (hop \(forwarded.hopCount)/\(forwarded.ttlHops))")
        #endif
    }
    
    // MARK: - Stop Broadcasting (when online)
    
    /// Stop mesh broadcast for a post (called when synced to server)
    func stopBroadcast(postId: String) async {
        stoppedPostIds.insert(postId)
        
        // Update DB status
        await updateMeshBroadcastStopped(postId: postId)
        
        #if DEBUG
        print("🛑 [MeshPost] Stopped broadcast for \(postId.prefix(8))...")
        #endif
    }
    
    // MARK: - Drain Mesh Posts to Peer
    func drainMeshPosts(to peerDeviceId: String) async {
        let queuedPosts = await getQueuedForSync()
        guard let myDeviceId = DeviceIdentityService.shared.fingerprint else { return }
        
        for post in queuedPosts {
            guard post.meshStatus == "broadcasting" || post.meshStatus == "queued_mesh" else { continue }
            guard var envelope = post.toMeshPostEnvelope(originDeviceId: myDeviceId) else { continue }
            
            // SECURITY: Sign before sending
            envelope.sign()
            
            if !envelope.hasPassedThrough(deviceId: peerDeviceId) {
                if let data = try? JSONEncoder().encode(envelope) {
                    // BUG FIX [P2]: ارسال هدفمند به جای Broadcast
                    await mesh.sendPostData(data, to: peerDeviceId)
                }
            }
        }
    }
    
    // MARK: - Get Queued Posts (for sync worker)
    
    /// Get posts that need to be synced to server
    func getQueuedForSync() async -> [Post] {
        // Bug fix: LIMIT 50 prevents OOM when thousands of posts queue up offline.
        // The networkStatusChanged observer naturally re-triggers sync to drain the queue in chunks.
        let sql = """
            SELECT * FROM posts 
            WHERE mesh_status = 'queued_mesh' OR mesh_status = 'broadcasting'
            ORDER BY timestamp ASC
            LIMIT 50
        """
        
        do {
            let rows = try await db.query(sql, params: [])
            return rows.compactMap { row -> Post? in
                // Parse post from row
                guard let id = row["id"] as? String,
                      let authorId = row["author_id"] as? String,
                      let authorUsername = row["author_username"] as? String,
                      let content = row["content"] as? String,
                      let timestampStr = row["timestamp"] as? String else {
                    return nil
                }
                
                let timestamp = PerformanceConstants.iso8601Fractional.date(from: timestampStr) ?? Date()
                
                var post = Post(
                    id: id,
                    authorId: authorId,
                    authorUsername: authorUsername,
                    authorAvatar: row["author_avatar"] as? String,
                    content: content,
                    imageUrl: row["image_url"] as? String,
                    timestamp: timestamp,
                    editedAt: nil,
                    likes: Int(row["likes"] as? Int64 ?? 0),
                    comments: Int(row["comments"] as? Int64 ?? 0),
                    reposts: Int(row["reposts"] as? Int64 ?? 0),
                    viewCount: Int(row["view_count"] as? Int64 ?? 0),
                    isLocal: (row["is_local"] as? Int64 ?? 0) == 1,
                    isLiked: (row["is_liked"] as? Int64 ?? 0) == 1,
                    isReposted: (row["is_reposted"] as? Int64 ?? 0) == 1,
                    visibility: row["visibility"] as? String,
                    distanceM: nil,
                    postType: row["post_type"] as? String ?? "text",
                    roomId: row["room_id"] as? String,
                    source: .nearby
                )
                post.initialSend = row["initial_send"] as? String
                return post
            }
        } catch {
            #if DEBUG
            print("❌ [MeshPost] Failed to query queued posts: \(error)")
            #endif
            return []
        }
    }
    
    // MARK: - Mark Mesh Status
    
    func markMeshStatus(postId: String, status: MeshPostStatus) async {
        let sql = "UPDATE posts SET mesh_status = ? WHERE id = ? OR client_post_id = ?"
        
        do {
            try await db.execute(sql, params: [status.rawValue, postId, postId])
        } catch {
            #if DEBUG
            print("⚠️ [MeshPost] Failed to update mesh status: \(error)")
            #endif
        }
    }
    
    // MARK: - DB-backed Stop Check (survives app restart)
    
    private func isPostStoppedInDB(postId: String) async -> Bool {
        let sql = "SELECT mesh_broadcast_stopped, mesh_status FROM posts WHERE id = ? OR client_post_id = ? LIMIT 1"
        do {
            let rows = try await db.query(sql, params: [postId, postId])
            if let first = rows.first {
                let stopped = first["mesh_broadcast_stopped"] as? Int64 ?? 0
                let status = first["mesh_status"] as? String ?? ""
                return stopped == 1 || status == "synced"
            }
        } catch { return false }
        return false
    }
    
    private func updateMeshBroadcastStopped(postId: String) async {
        let sql = "UPDATE posts SET mesh_broadcast_stopped = 1, mesh_status = 'synced' WHERE id = ? OR client_post_id = ?"
        
        do {
            try await db.execute(sql, params: [postId, postId])
        } catch {
            #if DEBUG
            print("⚠️ [MeshPost] Failed to update broadcast stopped: \(error)")
            #endif
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let meshPostReceived = Notification.Name("meshPostReceived")
}
