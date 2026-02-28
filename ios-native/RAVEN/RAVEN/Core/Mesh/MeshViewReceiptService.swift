//
//  MeshViewReceiptService.swift
//  RAVEN
//
//  Service for tracking views on mesh-distributed posts
//  Creates receipts when viewing offline posts and syncs when online
//

import Foundation
import CryptoKit
import UIKit

// MARK: - Mesh View Receipt

/// Receipt for tracking a single view on a mesh-distributed post
struct MeshViewReceipt: Codable, Identifiable {
    var id: String { receiptId }
    
    let receiptId: String           // UUID for this receipt
    let postId: String              // Post being viewed
    let viewerHash: String          // SHA256(userId) for privacy
    let originDeviceId: String      // Device that created the receipt
    let hopCount: Int               // How many mesh hops this has traveled
    let createdAt: Date
    
    // Compact coding keys for BLE efficiency
    enum CodingKeys: String, CodingKey {
        case receiptId = "rid"
        case postId = "pid"
        case viewerHash = "vh"
        case originDeviceId = "od"
        case hopCount = "hc"
        case createdAt = "ca"
    }
}

// MARK: - Mesh View Receipt Service

/// Manages offline view receipts for mesh-distributed posts
/// - Creates receipts when user views a mesh post
/// - Stores receipts locally until sync
/// - Syncs to server when connectivity returns
@MainActor
final class MeshViewReceiptService: ObservableObject {
    static let shared = MeshViewReceiptService()
    
    // MARK: - Properties
    
    private let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    private let persistenceKey = "mesh_view_receipts_pending"
    
    /// Pending receipts waiting to be synced
    @Published private(set) var pendingReceipts: [MeshViewReceipt] = []
    
    /// Posts we've already created receipts for (prevent duplicates)
    private var viewedPostIds: Set<String> = []
    
    private init() {
        loadPendingReceipts()
    }
    
    // MARK: - Public API
    
    /// Record that user viewed a mesh post
    /// Creates a receipt and queues for sync
    func recordView(for post: Post) {
        // Skip if already viewed
        guard !viewedPostIds.contains(post.id) else {
            #if DEBUG
            print("📊 [MeshReceipt] Already recorded view for \(post.id.prefix(8))")
            #endif
            return
        }
        
        // Get viewer hash (SHA256 of user ID for privacy)
        guard let userId = AuthService.shared.currentUser?.id else {
            #if DEBUG
            print("📊 [MeshReceipt] No user ID, skipping receipt")
            #endif
            return
        }
        
        let viewerHash = hashUserId(userId)
        
        // Create receipt
        let receipt = MeshViewReceipt(
            receiptId: UUID().uuidString,
            postId: post.id,
            viewerHash: viewerHash,
            originDeviceId: deviceId,
            hopCount: 0,
            createdAt: Date()
        )
        
        // Store locally
        pendingReceipts.append(receipt)
        viewedPostIds.insert(post.id)
        savePendingReceipts()
        
        #if DEBUG
        print("📊 [MeshReceipt] Created receipt for post \(post.id.prefix(8))")
        #endif
        
        // Try to sync if online
        Task {
            await syncIfOnline()
        }
    }
    
    /// Record view from a MeshPostEnvelope (when receiving via BLE)
    func recordView(for envelope: MeshPostEnvelope) {
        // Skip if already viewed
        guard !viewedPostIds.contains(envelope.postId) else {
            return
        }
        
        guard let userId = AuthService.shared.currentUser?.id else {
            return
        }
        
        let viewerHash = hashUserId(userId)
        
        let receipt = MeshViewReceipt(
            receiptId: UUID().uuidString,
            postId: envelope.postId,
            viewerHash: viewerHash,
            originDeviceId: deviceId,
            hopCount: envelope.hopCount,
            createdAt: Date()
        )
        
        pendingReceipts.append(receipt)
        viewedPostIds.insert(envelope.postId)
        savePendingReceipts()
        
        #if DEBUG
        print("📊 [MeshReceipt] Created receipt for mesh post \(envelope.postId.prefix(8))")
        #endif
    }
    
    /// Get receipt count for local display
    func getLocalViewCount(for postId: String) -> Int {
        return pendingReceipts.filter { $0.postId == postId }.count
    }
    
    // MARK: - Sync
    
    /// Sync pending receipts to server
    func syncIfOnline() async {
        guard NetworkMonitor.shared.isOnline else {
            #if DEBUG
            print("📊 [MeshReceipt] Offline, deferring sync")
            #endif
            return
        }
        
        guard !pendingReceipts.isEmpty else {
            return
        }
        
        let receiptsToSync = pendingReceipts
        
        do {
            let response: MeshReceiptSyncResponse = try await NetworkService.shared.post(
                path: "/api/posts/mesh/receipts",
                body: MeshReceiptsBatchRequest(receipts: receiptsToSync)
            )
            
            #if DEBUG
            print("📊 [MeshReceipt] Synced: \(response.synced) new, \(response.skipped) skipped")
            #endif
            
            // Clear only the receipts that were actually synced (not ones added during the await)
            let syncedIds = Set(receiptsToSync.map { $0.receiptId })
            pendingReceipts.removeAll(where: { syncedIds.contains($0.receiptId) })
            savePendingReceipts()
            
        } catch {
            #if DEBUG
            print("📊 [MeshReceipt] Sync failed: \(error)")
            #endif
        }
    }
    
    // MARK: - Private Helpers
    
    /// Hash user ID for privacy
    private func hashUserId(_ userId: String) -> String {
        let data = Data(userId.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Load pending receipts from UserDefaults
    private func loadPendingReceipts() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey) else {
            return
        }
        
        do {
            pendingReceipts = try JSONDecoder().decode([MeshViewReceipt].self, from: data)
            viewedPostIds = Set(pendingReceipts.map { $0.postId })
            #if DEBUG
            print("📊 [MeshReceipt] Loaded \(pendingReceipts.count) pending receipts")
            #endif
        } catch {
            #if DEBUG
            print("📊 [MeshReceipt] Failed to load pending: \(error)")
            #endif
        }
    }
    
    /// Save pending receipts to UserDefaults
    private func savePendingReceipts() {
        do {
            let data = try JSONEncoder().encode(pendingReceipts)
            UserDefaults.standard.set(data, forKey: persistenceKey)
        } catch {
            #if DEBUG
            print("📊 [MeshReceipt] Failed to save pending: \(error)")
            #endif
        }
    }
}

// MARK: - Request/Response Models

private struct MeshReceiptsBatchRequest: Codable {
    let receipts: [MeshViewReceipt]
}

private struct MeshReceiptSyncResponse: Codable {
    let status: String
    let synced: Int
    let skipped: Int
    let total: Int
}
