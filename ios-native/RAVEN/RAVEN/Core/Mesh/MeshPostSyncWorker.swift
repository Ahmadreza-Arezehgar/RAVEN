//
//  MeshPostSyncWorker.swift
//  RAVEN
//
//  Background worker to sync mesh posts to server when online
//  Part of the "never lose messages" guarantee
//

import Foundation
import Combine

// MARK: - Mesh Post Sync Worker

actor MeshPostSyncWorker {
    static let shared = MeshPostSyncWorker()
    
    private var cancellables = Set<AnyCancellable>()
    private var isSyncing = false
    
    private let networkService = NetworkService.shared
    
    private init() {}
    
    // MARK: - Start Monitoring
    
    /// Start monitoring network state and sync when online
    func startMonitoring() {
        // Use NotificationCenter instead of Combine for actor isolation compatibility
        NotificationCenter.default.addObserver(
            forName: .networkStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            
            if NetworkMonitor.shared.isOnline {
                Task {
                    await self.syncQueuedPosts()
                }
            }
        }
        
        #if DEBUG
        print("✅ [MeshPostSync] Started monitoring network state")
        #endif
    }
    
    // MARK: - Sync Queued Posts
    
    /// Sync all queued mesh posts to the server
    func syncQueuedPosts() async {
        guard !isSyncing else {
            #if DEBUG
            print("⏳ [MeshPostSync] Already syncing, skipping...")
            #endif
            return
        }
        
        isSyncing = true
        defer { isSyncing = false }
        
        #if DEBUG
        print("🔄 [MeshPostSync] Starting sync of mesh posts...")
        #endif
        
        // FIX: Drain the ENTIRE queue in chunks of 50.
        // networkStatusChanged fires only ONCE on reconnect — not in a loop.
        // Without this while, posts beyond the first 50 would be stuck forever.
        while true {
            let queuedPosts = await MeshPostService.shared.getQueuedForSync()
            
            guard !queuedPosts.isEmpty else {
                #if DEBUG
                print("✅ [MeshPostSync] Queue fully drained")
                #endif
                break
            }
            
            #if DEBUG
            print("📤 [MeshPostSync] Syncing batch of \(queuedPosts.count) posts...")
            #endif
            
            for post in queuedPosts {
                let success = await syncPost(post)
                if !success {
                    // Mark in DB so this post is excluded from future getQueuedForSync queries.
                    // Without this, the LIMIT 50 query returns the same failing posts forever,
                    // blocking all healthy posts behind them.
                    await MeshPostService.shared.markMeshStatus(postId: post.id, status: .syncFailed)
                }
            }
            
            // Throttle between batches to avoid 429 Rate Limit and CPU pressure
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        
        #if DEBUG
        print("✅ [MeshPostSync] Sync complete")
        #endif
    }
    
    // MARK: - Sync Single Post
    
    private func syncPost(_ post: Post) async -> Bool {
        do {
            let currentUserId = await KeychainService.shared.getUserId()
            let isOwnPost = currentUserId == post.authorId
            
            if isOwnPost {
                // Own post: upload to server as the author
                let body = MeshPostSyncRequest(
                    postId: post.id,
                    content: post.content,
                    visibility: post.visibility ?? "public",
                    initialSend: post.initialSend ?? "mesh"
                )
                
                let response: Post = try await networkService.post(
                    path: "/api/posts/create",
                    body: body
                )
                
                #if DEBUG
                print("✅ [MeshPostSync] Synced OWN post \(post.id.prefix(8))... → server ID: \(response.id)")
                #endif
                
                // Stop mesh broadcast for own post (server has it now)
                await MeshPostService.shared.stopBroadcast(postId: post.id)
                
                // Update FeedStore with server response
                await FeedStore.shared.updatePost(clientPostId: post.id, with: response)
            } else {
                // Someone else's post: bridge it to server without stopping mesh broadcast
                let body = MeshPostBridgeRequest(
                    postId: post.id,
                    authorId: post.authorId,
                    authorUsername: post.authorUsername,
                    authorAvatar: post.authorAvatar,
                    content: post.content,
                    visibility: post.visibility ?? "public",
                    createdAt: SharedDateFormatters.formatISO8601(post.timestamp),
                    initialSend: post.initialSend ?? "mesh"
                )
                
                struct EmptyResp: Decodable {}
                let _: EmptyResp = try await networkService.post(
                    path: "/api/posts/mesh/uplink",
                    body: body
                )
                
                #if DEBUG
                print("✅ [MeshPostSync] Bridged OTHER's post \(post.id.prefix(8))...")
                #endif
                // **Important**: Do NOT stop mesh broadcast — let the message continue relaying in the mesh network
                await MeshPostService.shared.markMeshStatus(postId: post.id, status: .synced)
            }
            return true
        } catch {
            #if DEBUG
            print("❌ [MeshPostSync] Failed to sync post \(post.id.prefix(8))...: \(error)")
            #endif
            return false
        }
    }
}

// MARK: - Sync Request (own posts)

private struct MeshPostSyncRequest: Encodable {
    let postId: String
    let content: String
    let visibility: String
    let initialSend: String
    
    enum CodingKeys: String, CodingKey {
        case postId = "post_id"
        case content
        case visibility
        case initialSend = "initial_send"
    }
}

// MARK: - Bridge Request (others' posts)

private struct MeshPostBridgeRequest: Encodable {
    let postId: String
    let authorId: String
    let authorUsername: String
    let authorAvatar: String?
    let content: String
    let visibility: String
    let createdAt: String
    let initialSend: String
    
    enum CodingKeys: String, CodingKey {
        case postId = "post_id"
        case authorId = "author_id"
        case authorUsername = "author_username"
        case authorAvatar = "author_avatar"
        case content
        case visibility
        case createdAt = "created_at"
        case initialSend = "initial_send"
    }
}
