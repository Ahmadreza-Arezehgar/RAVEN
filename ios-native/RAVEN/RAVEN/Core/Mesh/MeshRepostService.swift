//
//  MeshRepostService.swift
//  RAVEN
//
//  Repost fan-out that survives offline. The internet path is owned
//  by `FeedStore.toggleRepost` (POST /api/posts/{id}/repost). When
//  the device is offline that call rolls back, so we ALSO persist
//  the intent here and:
//    1. Broadcast a `MeshRepostEnvelope` over BLE so peers see the
//       repost immediately (peer-to-peer, no server).
//    2. Queue the intent in UserDefaults; the queue drains when
//       NetworkMonitor reports the device back online.
//
//  This keeps the UI optimistic and never loses a repost intent.
//

import Foundation
import Combine

// MARK: - Mesh Repost Envelope (BLE wire format)

/// Compact BLE envelope advertising a repost. Mirrors
/// `MeshPostEnvelope` but with a different `kind` discriminator and
/// only the fields a peer needs to show "@you reposted post X".
struct MeshRepostEnvelope: Codable {
    let kind: String = "mesh_repost_v1"

    let originalPostId: String
    let originalAuthorId: String
    /// Reposter's user id (who is doing the repost).
    let reposterId: String
    /// `true` when the user is adding the repost, `false` when they
    /// undid it. Receivers update their local `reposts` count
    /// accordingly.
    let isAdding: Bool
    let createdAt: TimeInterval
    let originDeviceId: String

    enum CodingKeys: String, CodingKey {
        case kind = "k"
        case originalPostId = "opi"
        case originalAuthorId = "oai"
        case reposterId = "rid"
        case isAdding = "add"
        case createdAt = "ca"
        case originDeviceId = "od"
    }
}

// MARK: - Mesh Repost Service

/// Bridges the fullscreen-video repost button to both the BLE mesh
/// (immediate peer fan-out) and a UserDefaults retry queue (so an
/// offline repost still lands when the device reconnects).
actor MeshRepostService {
    static let shared = MeshRepostService()

    private let queueKey = "raven.mesh.pendingReposts"
    private let mesh: any MeshTransportProtocol
    private var didStartDrainObserver = false

    init(mesh: any MeshTransportProtocol = BLEMeshEngine.shared) {
        self.mesh = mesh
    }

    // MARK: - Public API

    /// Called from the fullscreen player when the user taps repost.
    /// Safe to call regardless of online state — handles both paths
    /// (best-effort BLE fan-out + retry-on-reconnect queue).
    func broadcastRepost(
        originalPostId: String,
        authorId: String,
        isAdding: Bool
    ) async {
        guard !originalPostId.isEmpty else { return }

        let isOnline = await MainActor.run { NetworkMonitor.shared.isOnline }
        if !isOnline {
            // Internet path will have failed in FeedStore — queue the
            // intent for retry when we're back online.
            persistPending(postId: originalPostId, isAdding: isAdding)
            await ensureDrainObserver()
        }

        // Always attempt BLE fan-out so nearby peers see the repost
        // without needing the server. Peer code can choose to
        // increment a local counter or just display "@you reposted".
        await broadcastMeshFrame(
            originalPostId: originalPostId,
            authorId: authorId,
            isAdding: isAdding
        )
    }

    /// Drains the queue of offline-saved repost intents. Hooked up to
    /// `NetworkMonitor.$isOnline` becoming true.
    func drainPendingReposts() async {
        let isOnline = await MainActor.run { NetworkMonitor.shared.isOnline }
        guard isOnline else { return }

        let pending = readPending()
        guard !pending.isEmpty else { return }

        // Clear up-front so concurrent retries don't double-fire.
        clearPending()

        for entry in pending {
            await FeedStore.shared.toggleRepost(postId: entry.postId)
        }

        #if DEBUG
        print("✅ [MeshRepost] Drained \(pending.count) pending reposts")
        #endif
    }

    // MARK: - BLE fan-out

    private func broadcastMeshFrame(
        originalPostId: String,
        authorId: String,
        isAdding: Bool
    ) async {
        guard let deviceId = DeviceIdentityService.shared.fingerprint else { return }
        let reposterId = (await KeychainService.shared.getUserId()) ?? deviceId

        let envelope = MeshRepostEnvelope(
            originalPostId: originalPostId,
            originalAuthorId: authorId,
            reposterId: reposterId,
            isAdding: isAdding,
            createdAt: Date().timeIntervalSince1970,
            originDeviceId: deviceId
        )

        guard let data = try? JSONEncoder().encode(envelope) else { return }
        await mesh.broadcastPostData(data)
        #if DEBUG
        print("📡 [MeshRepost] Broadcast repost \(originalPostId.prefix(8))... (add=\(isAdding))")
        #endif
    }

    // MARK: - UserDefaults queue

    private struct PendingRepost {
        let postId: String
        let isAdding: Bool
    }

    private func persistPending(postId: String, isAdding: Bool) {
        var queue = UserDefaults.standard.array(forKey: queueKey) as? [[String: Any]] ?? []
        queue.append([
            "postId": postId,
            "isAdding": isAdding,
            "ts": Date().timeIntervalSince1970
        ])
        UserDefaults.standard.set(queue, forKey: queueKey)
    }

    private func readPending() -> [PendingRepost] {
        let raw = UserDefaults.standard.array(forKey: queueKey) as? [[String: Any]] ?? []
        return raw.compactMap { entry in
            guard let postId = entry["postId"] as? String else { return nil }
            let isAdding = entry["isAdding"] as? Bool ?? true
            return PendingRepost(postId: postId, isAdding: isAdding)
        }
    }

    private func clearPending() {
        UserDefaults.standard.removeObject(forKey: queueKey)
    }

    // MARK: - Drain observer

    /// Lazy installer for the NetworkMonitor observer. We can't
    /// register a strong-retained Combine sink from an actor's init,
    /// so we install once on first offline-queue.
    private func ensureDrainObserver() async {
        guard !didStartDrainObserver else { return }
        didStartDrainObserver = true
        await MeshRepostDrainBridge.shared.start()
    }
}

// MARK: - Drain bridge (MainActor)
//
// `NetworkMonitor` is an `ObservableObject` whose @Published values
// are most easily watched from a `MainActor`-isolated class. This
// bridge owns the Combine sink and pokes the actor when we go from
// offline → online.

@MainActor
final class MeshRepostDrainBridge {
    static let shared = MeshRepostDrainBridge()

    private var cancellable: AnyCancellable?

    func start() {
        guard cancellable == nil else { return }
        cancellable = NetworkMonitor.shared.$isOnline
            .removeDuplicates()
            .sink { online in
                guard online else { return }
                Task { await MeshRepostService.shared.drainPendingReposts() }
            }
    }
}
