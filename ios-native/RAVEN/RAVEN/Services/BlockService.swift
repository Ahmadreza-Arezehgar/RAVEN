import SwiftUI
import Observation

// MARK: - Block Service
/// Centralized block service with local cache for instant checks + server sync.
@Observable
final class BlockService {
    static let shared = BlockService()
    
    /// Set of user IDs that are blocked (by me or blocked me)
    private(set) var blockedUserIds: Set<String> = []
    
    /// Loading state
    private(set) var isLoading = false
    
    private init() {}
    
    /// Clear all cached block data (used on logout)
    func clearBlockList() {
        blockedUserIds = []
    }
    
    // MARK: - Local Check
    
    /// Instant local check — no network call.
    func isBlocked(_ userId: String) -> Bool {
        blockedUserIds.contains(userId)
    }
    
    // MARK: - Sync from Server
    
    /// Fetch the full blocked IDs list from server and cache locally.
    func syncBlockList() async {
        do {
            let response: BlockIdsResponse = try await NetworkService.shared.get(
                path: "/api/blocks/ids"
            )
            await MainActor.run {
                self.blockedUserIds = Set(response.blocked_ids)
            }
            #if DEBUG
            print("🚫 [BlockService] Synced \(response.blocked_ids.count) blocked IDs")
            #endif
        } catch {
            #if DEBUG
            print("⚠️ [BlockService] Sync failed: \(error)")
            #endif
        }
    }
    
    // MARK: - Block User
    
    /// Block a user. Optimistic: adds to local cache immediately.
    func blockUser(userId: String) async throws -> BlockResult {
        // 1. Optimistic UI: Add to block list and INSTANTLY remove content from feeds
        await MainActor.run {
            blockedUserIds.insert(userId)
            
            // APPLE GUIDELINE 1.2: Instantly remove blocked user's content from all feeds
            FeedStore.shared.mergedLocalPosts.removeAll { $0.authorId == userId }
            FeedStore.shared.friendsPosts.removeAll { $0.authorId == userId }
            FeedStore.shared.recommendedPosts.removeAll { $0.authorId == userId }
            ConversationStore.shared.conversations.removeAll { !$0.isGroup && $0.peer.userId == userId }
        }
        
        // 2. APPLE GUIDELINE 1.2: Notify developer automatically when blocking
        Task.detached {
            struct AutoReportPayload: Encodable {
                let target_type: String
                let target_id: String
                let reported_user_id: String
                let reason: String
            }
            let payload = AutoReportPayload(
                target_type: "user", 
                target_id: userId,
                reported_user_id: userId,
                reason: "auto_report_via_block_button"
            )
            // Fire and forget report
            _ = try? await NetworkService.shared.post(path: "/api/reports", body: payload) as Empty?
        }
        
        // 3. Send actual block request to server
        do {
            let result: BlockResult = try await NetworkService.shared.post(
                path: "/api/blocks",
                body: BlockRequest(blocked_id: userId)
            )
            await MainActor.run { Haptics.success() }
            return result
        } catch {
            // Rollback on failure
            await MainActor.run {
                blockedUserIds.remove(userId)
                Haptics.error()
            }
            throw error
        }
    }
    
    // MARK: - Unblock User
    
    /// Unblock a user. Optimistic: removes from local cache immediately.
    func unblockUser(userId: String) async throws {
        // Optimistic: remove immediately. Discard the removed-element return
        // values so MainActor.run keeps a Void inferred type.
        await MainActor.run {
            _ = blockedUserIds.remove(userId)
        }

        do {
            let _: UnblockResponse = try await NetworkService.shared.delete(
                path: "/api/blocks/\(userId)"
            )
            Haptics.success()
            #if DEBUG
            print("✅ [BlockService] Unblocked \(userId)")
            #endif
        } catch {
            // Rollback on failure
            await MainActor.run {
                _ = blockedUserIds.insert(userId)
            }
            Haptics.error()
            throw error
        }
    }
    
    // MARK: - Get Block Status
    
    func getBlockStatus(userId: String) async -> BlockStatus {
        do {
            return try await NetworkService.shared.get(
                path: "/api/blocks/status/\(userId)"
            )
        } catch {
            return BlockStatus(i_blocked_them: false, they_blocked_me: false, can_message: true)
        }
    }
}

// MARK: - Models

private struct BlockRequest: Encodable {
    let blocked_id: String
}

struct BlockResult: Decodable {
    let success: Bool?
    let message: String?
    let block_id: String?
    let cleanup_actions: [String]?
}

private struct UnblockResponse: Decodable {
    let success: Bool?
    let message: String?
}

private struct BlockIdsResponse: Decodable {
    let blocked_ids: [String]
}

struct BlockStatus: Decodable {
    let i_blocked_them: Bool
    let they_blocked_me: Bool
    let can_message: Bool
}
