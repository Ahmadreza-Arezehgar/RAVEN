//
//  MessageRouter.swift
//  RAVEN
//
//  Internet-First + Presence-Aware + Parallel Mesh Routing
//  Core rule: "Persist first, never lose, then route smartly"
//

import Foundation
import UIKit

// MARK: - Message Router

final class MessageRouter: ObservableObject {
    static let shared = MessageRouter()
    
    private let outbox = OutboxRepository.shared
    private let mesh: any MeshTransportProtocol
    private let net: any NetworkStatusProviding
    private let presence = PresenceService.shared
    
    // DTN Configuration — defaults must be within MeshCryptoService validation bounds
    struct DTNConfig {
        var sprayCounter: Int { PremiumLimits.meshSprayBudget }
        var hopLimit: Int = PremiumLimits.meshHopLimit
        var maxQueueSize: Int = 100
    }
    
    // Bug #6 fix: Thread-safe config access
    private let configLock = NSLock()
    private var _config = DTNConfig()
    
    private var config: DTNConfig {
        get {
            configLock.lock()
            defer { configLock.unlock() }
            return _config
        }
        set {
            configLock.lock()
            _config = newValue
            configLock.unlock()
        }
    }
    
    init(mesh: any MeshTransportProtocol = BLEMeshEngine.shared,
         net: any NetworkStatusProviding = NetworkMonitor.shared) {
        self.mesh = mesh
        self.net = net
        #if DEBUG
        print("📡 [MessageRouter] Initialized with Internet-First routing")
        #endif
    }
    
    // MARK: - Config
    
    func getConfig() -> DTNConfig { config }
    func updateConfig(_ newConfig: DTNConfig) { config = newConfig }
    
    // MARK: - Main Entry Point
    
    /// Send a text message using Internet-First routing
    /// 1. Persist to outbox FIRST (never lose)
    /// 2. Check presence of receiver
    /// 3. Route based on receiver's connectivity
    ///
    /// Routing uses `serverReachable` (application-layer probe) rather than just
    /// `isOnline` (NWPath) to handle captive portals and broken Wi-Fi correctly.
    func send(to receiverId: String, text: String, clientMessageId: String? = nil, roomId: String? = nil) async throws {
        let mid = clientMessageId ?? UUID().uuidString
        let currentNetState = net.netState
        let canReachServer = net.serverReachable
        let pathType = (net as? NetworkMonitor)?.connectionType.rawValue ?? "Unknown"
        
        // 🚨 DTN: Protect user-initiated send with background task
        final class TaskBox { 
            var id: UIBackgroundTaskIdentifier = .invalid 
            var isEnded = false  // 🛡️ Guards against expiration-handler race
            let lock = NSLock()
            func end() {
                lock.lock()
                defer { lock.unlock() }
                isEnded = true
                if id != .invalid {
                    UIApplication.shared.endBackgroundTask(id)
                    id = .invalid
                }
            }
        }
        
        let box = TaskBox()
        
        let assignedId = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "raven.send.\(mid.prefix(8))") {
                #if DEBUG
                print("⚠️ [Router] Background task expired for \(mid.prefix(8))")
                #endif
                box.end()
            }
        }
        
        box.lock.lock()
        box.id = assignedId
        // 🛡️ If expiration handler fired before ID was assigned, end it now
        if box.isEnded && assignedId != .invalid {
            UIApplication.shared.endBackgroundTask(assignedId)
            box.id = .invalid
        }
        box.lock.unlock()
        
        // NOTE: Do NOT use defer { box.end() } here — the background task must
        // stay alive until the async server send completes. box.end() is called
        // explicitly at each branch's completion point below.
        
        // 1. Persist first (Golden Rule: never lose messages)
        let entry = OutboxEntry.create(
            clientMessageId: mid,
            receiverId: receiverId,
            payload: text,
            serverState: .queued,
            meshState: .idle
        )
        
        do {
            try await outbox.insert(entry)
            
            // Bug #7 fix: Create persistent DeliveryJobs for background processing.
            // Without this, DeliveryJobRunner never picks up messages sent via MessageRouter.
            let allowMesh = true  // MessageRouter only handles text messages
            try await DeliveryJobRepository.shared.createJobs(
                messageId: mid,
                channels: allowMesh ? [.server, .mesh] : [.server]
            )
        } catch {
            await MainActor.run { box.end() }
            throw error // Propagate to UI for error display
        }
        
        // 🚀 Detailed routing decision log (critical for diagnosing cellular routing issues)
        #if DEBUG
        print("🚀 [MessageRouter] =========================================")
        print("🚀 [MessageRouter] Routing message: \(mid.prefix(8))")
        print("🚀 [MessageRouter] Path: \(pathType) | NWPath Online: \(net.isOnline) | Server Reachable: \(canReachServer)")
        print("🚀 [Router] Recipient: \(receiverId.prefix(8)), NetState: \(currentNetState.rawValue)")
        #endif
        
        // Spec V1 §2.2: Log effective hopLimit in degraded mode (actual hop limit set in enqueueMesh via PremiumLimits)
        if currentNetState == .degraded {
            let effectiveHopLimit = min(config.hopLimit + 5, MeshCryptoService.protocolMaxHopLimit)
            #if DEBUG
            print("🚀 [Router] Degraded → effectiveHopLimit: \(effectiveHopLimit)")
            #endif
        }
        
        if canReachServer {
            #if DEBUG
            print("🚀 [MessageRouter] ➡️ DECISION: Dual-path (SERVER + MESH)")
            #endif
            // ════════════════════════════════════════════════════════════
            // ALWAYS DUAL-PATH: Internet + Mesh simultaneously (text only)
            // Same clientMessageId → server dedup + first-delivery-wins
            // Whichever path delivers first notifies server; the other is
            // stopped via ServerReceipt gossip / broadcastStop.
            // ════════════════════════════════════════════════════════════
            #if DEBUG
            print("🚀 [Router] Dual-path: Internet + Mesh (text)")
            #endif
            
            // 2.1 Internet path (async — doesn't block mesh send)
            Task {
                await self.tryServerSend(mid: mid, roomId: roomId)
                await MainActor.run { box.end() }
            }
            
            // 2.2 Mesh path (parallel)
            try? await outbox.updateMeshState(clientMessageId: mid, state: .queued)
            await enqueueMesh(mid: mid, receiverId: receiverId, payload: text)
            
        } else {
            // 3. Server unreachable (offline, captive portal, broken Wi-Fi) → mesh only
            #if DEBUG
            print("🚀 [MessageRouter] ➡️ DECISION: MESH ONLY (Offline)")
            print("🚀 [Router] Server unreachable → Mesh only")
            #endif
            try? await outbox.updateServerState(clientMessageId: mid, state: .idle)
            try? await outbox.updateMeshState(clientMessageId: mid, state: .queued)
            await enqueueMesh(mid: mid, receiverId: receiverId, payload: text)
            await MainActor.run { box.end() }
        }
        
        #if DEBUG
        print("🚀 [Router] ════════════════════════════════════════")
        #endif
    }
    
    // MARK: - Media Send (Spec V1 §4.2)
    
    /// Route media messages — NEVER sent via mesh.
    /// Media (image/voice/file/location) requires internet; stays queued in outbox
    /// until connectivity is restored.
    func sendMedia(to receiverId: String, clientMessageId: String) async {
        let currentNetState = net.netState
        
        #if DEBUG
        print("🚀 [Router] Media routing: \(clientMessageId.prefix(8)), NetState: \(currentNetState.rawValue)")
        #endif
        
        switch currentNetState {
        case .offline:
            // Media stays in outbox — will be drained on reconnect
            #if DEBUG
            print("⏳ [Router] Offline — media queued, waiting for internet")
            #endif
            
        case .online, .degraded:
            // Attempt server upload
            Task { await self.tryServerSend(mid: clientMessageId) }
        }
    }
    
    // MARK: - Server Send
    
    /// Attempt server delivery (idempotent via client_message_id)
    func tryServerSend(mid: String, roomId: String? = nil) async {
        guard let entry = try? await outbox.get(clientMessageId: mid) else { return }
        if entry.deliveredVia != nil { return }
        
        // Bug 7 fix: Mark job as in_progress BEFORE sending to prevent
        // DeliveryJobRunner from picking up the same job concurrently.
        // Without this, both Router and JobRunner fire the same request → 429.
        try? await DeliveryJobRepository.shared.markInProgress(messageId: mid, channel: .server)
        
        try? await outbox.updateServerState(clientMessageId: mid, state: .sending)
        try? await outbox.updateTimeline(clientMessageId: mid, field: .firstServerUpload)
        
        do {
            let messageRows = try? await DatabaseService.shared.query("SELECT * FROM messages WHERE client_message_id = ? LIMIT 1", params: [mid])
            let msgRow = messageRows?.first
            let msgTypeStr = msgRow?["type"] as? String ?? "text"
            
            // Bug 2 fix: Use DB-based group detection instead of string comparison
            // which falsely identifies 1:1 chats as groups (roomId = UUID1_UUID2 != receiverId)
            let actualRoomId = msgRow?["room_id"] as? String ?? roomId
            let isGroup = (try? await DatabaseService.shared.exists("SELECT 1 FROM groups WHERE id = ? LIMIT 1", params: [actualRoomId ?? ""])) ?? false
            let isChannel = (try? await DatabaseService.shared.exists("SELECT 1 FROM conversations WHERE room_id = ? AND is_channel = 1 LIMIT 1", params: [actualRoomId ?? ""])) ?? false
            
            if isGroup || isChannel, let gid = actualRoomId {
                let response: GroupMessageResponse = try await NetworkService.shared.post(
                    path: "/api/groups/\(gid)/messages",
                    body: SendGroupMessageRequest(
                        messageId: mid,
                        content: entry.payloadCiphertext,
                        messageType: msgTypeStr,
                        replyToMessageId: msgRow?["reply_to_message_id"] as? String,
                        replyToTextPreview: msgRow?["reply_to_text_preview"] as? String,
                        replyToSenderName: msgRow?["reply_to_sender_name"] as? String,
                        replyToType: msgRow?["reply_to_type"] as? String
                    ),
                    idempotencyKey: mid
                )
                try? await outbox.updateServerState(clientMessageId: mid, state: .sent)
                try? await outbox.updateTimeline(clientMessageId: mid, field: .serverAck)
                try? await MessageRepository.shared.updateServerId(clientMessageId: mid, serverId: response.id)
                await mesh.gossipReceipt(ServerReceipt(messageId: mid, serverReceivedAt: Date(), serverSequence: nil, uploaderDeviceId: await getDeviceId()))
                try? await DeliveryJobRepository.shared.markDelivered(messageId: mid, channel: .server)
                try? await DeliveryJobRepository.shared.markStopped(messageId: mid)
                
            } else {
                let response: SendMessageResponse = try await NetworkService.shared.post(
                    path: "/api/messages/send",
                    body: SendMessageRequest(
                        messageId: mid,
                        recipientId: entry.receiverId,
                        content: entry.payloadCiphertext,
                        messageType: msgTypeStr,
                        audioUrl: nil,
                        replyToMessageId: msgRow?["reply_to_message_id"] as? String
                    ),
                    idempotencyKey: mid
                )
                try? await outbox.updateServerState(clientMessageId: mid, state: .sent)
                try? await outbox.updateTimeline(clientMessageId: mid, field: .serverAck)
                try? await MessageRepository.shared.updateServerId(clientMessageId: mid, serverId: response.id)
                await mesh.gossipReceipt(ServerReceipt(messageId: mid, serverReceivedAt: Date(), serverSequence: nil, uploaderDeviceId: await getDeviceId()))
                try? await DeliveryJobRepository.shared.markDelivered(messageId: mid, channel: .server)
                try? await DeliveryJobRepository.shared.markStopped(messageId: mid)
                
                if response.recipientDelivered == true {
                    try? await outbox.markDelivered(clientMessageId: mid, via: .server)
                    await mesh.broadcastStop(mid)
                }
            }
        } catch {
            try? await outbox.updateServerState(clientMessageId: mid, state: .failed)
            
            // Bug 4 fix: Return job from in_progress → pending so DeliveryJobRunner
            // can retry after connectivity is restored. Without this, the job is
            // stuck in in_progress forever.
            try? await DeliveryJobRepository.shared.incrementAttempt(
                messageId: mid,
                channel: .server,
                error: error.localizedDescription,
                retryAfter: 5
            )
        }
    }
    
    // MARK: - Mesh Send
    
    /// Enqueue message for mesh delivery
    private func enqueueMesh(mid: String, receiverId: String, payload: String) async {
        try? await outbox.updateMeshState(clientMessageId: mid, state: .sending)
        
        let messageRows = try? await DatabaseService.shared.query("SELECT * FROM messages WHERE client_message_id = ? LIMIT 1", params: [mid])
        let msgRow = messageRows?.first
        let typeStr = msgRow?["type"] as? String ?? "text"
        let msgType = MessageType.from(name: typeStr)
        
        let myId = await KeychainService.shared.getUserId() ?? ""
        let myName = AuthService.shared.currentUser?.displayName ?? ""
        let deviceId = await getDeviceId()
        
        var envelope = MeshEnvelope(
            clientMessageId: mid,
            roomId: msgRow?["room_id"] as? String ?? receiverId,
            senderId: myId,
            senderName: myName,
            recipientId: receiverId,
            type: msgType.index,
            text: payload,
            timestamp: Date().timeIntervalSince1970,
            sprayCounter: config.sprayCounter,
            hopCount: 0,
            hopLimit: PremiumLimits.meshHopLimit,
            routePath: [deviceId],
            originDeviceId: deviceId,
            needsForwarding: true
        )
        envelope.ttlSeconds = PremiumLimits.meshTTLSeconds
        
        // Bug 2 fix: Use DB-based group detection instead of string comparison
        let actualRoomId = msgRow?["room_id"] as? String ?? receiverId
        let isGroupMsg = (try? await DatabaseService.shared.exists("SELECT 1 FROM groups WHERE id = ? LIMIT 1", params: [actualRoomId])) ?? false
        envelope.isGroup = isGroupMsg
        
        if let replyToId = msgRow?["reply_to_message_id"] as? String {
            envelope.replyToMessageId = replyToId
            envelope.replyToTextPreview = msgRow?["reply_to_text_preview"] as? String
            envelope.replyToSenderName = msgRow?["reply_to_sender_name"] as? String
        }
        
        await mesh.enqueueForBroadcast(envelope)
        try? await outbox.updateTimeline(clientMessageId: mid, field: .firstMeshSend)
    }
    
    // MARK: - First Delivery Wins Handlers
    
    /// Called when mesh delivers first (mesh ACK received)
    func onMeshDelivered(mid: String) async {
        // 1. Update outbox
        if let entry = try? await outbox.get(clientMessageId: mid),
           entry.deliveredVia == nil {
            try? await outbox.markDelivered(clientMessageId: mid, via: .mesh)
        }
        
        // 2. Notify server (or queue if offline)
        if net.isOnline {
            do {
                let response: AckDeliveredResponse = try await NetworkService.shared.post(
                    path: "/api/messages/ack-delivered",
                    body: AckDeliveredRequest(
                        messageId: mid,
                        deliveredVia: "mesh",
                        pathUsed: "mesh"
                    ),
                    idempotencyKey: "ack-\(mid)"
                )
                if response.stopMesh {
                    await mesh.broadcastStop(mid)
                    try? await outbox.updateMeshState(clientMessageId: mid, state: .stopped)
                }
                #if DEBUG
                print("✅ [Router] Notified server of mesh delivery: \(mid.prefix(8))")
                #endif
            } catch {
                // Failed - queue for later
                try? await PendingACKRepository.shared.add(
                    clientMessageId: mid,
                    deliveredVia: "mesh",
                    pathUsed: "mesh",
                    idempotencyKey: "ack-\(mid)"
                )
                #if DEBUG
                print("⚠️ [Router] Queued ACK for later: \(mid.prefix(8))")
                #endif
            }
        } else {
            // Offline - queue for later
            try? await PendingACKRepository.shared.add(
                clientMessageId: mid,
                deliveredVia: "mesh",
                pathUsed: "mesh",
                idempotencyKey: "ack-\(mid)"
            )
            #if DEBUG
            print("📥 [Router] Queued offline ACK: \(mid.prefix(8))")
            #endif
        }
    }
    
    /// Called when server delivers first (stop mesh command received)
    func onStopMesh(mid: String) async {
        // 1. Update outbox
        try? await outbox.updateMeshState(clientMessageId: mid, state: .stopped)
        
        if let entry = try? await outbox.get(clientMessageId: mid),
           entry.deliveredVia == nil {
            try? await outbox.markDelivered(clientMessageId: mid, via: .server)
        }
        
        // 2. Stop mesh propagation
        await mesh.broadcastStop(mid)
        
        // ⏱️ Observability: stamp cancellation propagation
        try? await outbox.updateTimeline(clientMessageId: mid, field: .cancellationPropagated)
        
        #if DEBUG
        print("🛑 [Router] Server delivered first - stopped mesh: \(mid.prefix(8))")
        #endif
    }
    
    /// Sync pending ACKs to server (called on internet restore)
    func syncPendingACKs() async {
        guard net.isOnline else { return }
        
        do {
            let pending = try await PendingACKRepository.shared.getDue(limit: 100)
            guard !pending.isEmpty else { return }
            
            #if DEBUG
            print("🔄 [Router] Syncing \(pending.count) pending ACKs...")
            #endif
            
            for ack in pending {
                do {
                    let response: AckDeliveredResponse = try await NetworkService.shared.post(
                        path: "/api/messages/ack-delivered",
                        body: AckDeliveredRequest(
                            messageId: ack.clientMessageId,
                            deliveredVia: ack.deliveredVia,
                            pathUsed: ack.pathUsed
                        ),
                        idempotencyKey: ack.idempotencyKey ?? "ack-\(ack.clientMessageId)"
                    )
                    if response.stopMesh {
                        await mesh.broadcastStop(ack.clientMessageId)
                        try? await outbox.updateMeshState(clientMessageId: ack.clientMessageId, state: .stopped)
                    }
                    
                    try? await PendingACKRepository.shared.remove(clientMessageId: ack.clientMessageId)
                } catch {
                    if let willRetry = try? await PendingACKRepository.shared.markAttemptFailure(
                        clientMessageId: ack.clientMessageId,
                        error: error.localizedDescription
                    ), !willRetry {
                        #if DEBUG
                        print("🧯 [Router] ACK retry budget exhausted: \(ack.clientMessageId.prefix(8))")
                        #endif
                    }
                    #if DEBUG
                    print("⚠️ [Router] Failed to sync ACK \(ack.clientMessageId.prefix(8)): \(error)")
                    #endif
                }
            }
            
            #if DEBUG
            print("✅ [Router] Pending ACK sync complete")
            #endif
        } catch {
            #if DEBUG
            print("❌ [Router] Failed to get pending ACKs: \(error)")
            #endif
        }
    }
    
    // MARK: - Legacy Handler (for compatibility)
    
    /// Called when message delivery is confirmed (from ACK)
    func handleDeliveryConfirmed(mid: String, via: DeliveryVia) async {
        if via == .mesh {
            await onMeshDelivered(mid: mid)
        } else {
            await onStopMesh(mid: mid)
        }
    }
    
    // MARK: - Helpers
    
    private func getDeviceId() async -> String {
        await MainActor.run {
            UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        }
    }
}
