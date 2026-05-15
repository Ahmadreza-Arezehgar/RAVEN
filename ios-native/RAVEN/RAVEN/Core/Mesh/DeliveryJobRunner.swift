//
//  DeliveryJobRunner.swift
//  RAVEN
//
//  Background service that processes pending delivery jobs
//  Runs periodically to retry failed sends and process new jobs
//

import Foundation

/// Background service for processing delivery jobs
@MainActor
class DeliveryJobRunner {
    static let shared = DeliveryJobRunner()
    
    private var timer: Timer?
    private let safetyNetInterval: TimeInterval = 60.0  // ✅ Perf fix: 60s safety net (was 5s aggressive poll)
    private var isRunning = false
    private var observers: [NSObjectProtocol] = []
    
    private let mesh: any MeshTransportProtocol
    private let net: any NetworkStatusProviding
    
    init(mesh: any MeshTransportProtocol = BLEMeshEngine.shared,
         net: any NetworkStatusProviding = NetworkMonitor.shared) {
        self.mesh = mesh
        self.net = net
    }
    
    // MARK: - Lifecycle
    
    /// Start the job runner (event-driven + safety-net timer)
    func start() {
        guard timer == nil else { return }
        
        #if DEBUG
        print("🚀 [JobRunner] Starting (event-driven mode)...")
        #endif
        
        // Run immediately
        Task { await processReadyJobs() }
        
        // ✅ Perf fix: Event-driven triggers instead of 5s polling.
        // CPU can sleep between events → massive battery savings.
        
        // Trigger when a new message is enqueued
        observers.append(NotificationCenter.default.addObserver(
            forName: NSNotification.Name("OutboxMessageEnqueued"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.trigger() }
        })
        
        // Trigger when a BLE peer connects
        observers.append(NotificationCenter.default.addObserver(
            forName: NSNotification.Name("MeshPeerConnected"),
            object: nil, queue: .main
        ) { [weak self] _ in
            // When a peer connects, ignore exponential backoff and send immediately!
            Task { await self?.trigger(ignoreBackoff: true) }
        })
        
        // Trigger when network connectivity changes
        observers.append(NotificationCenter.default.addObserver(
            forName: .networkStatusChanged, // Fixed Typo
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.trigger(ignoreBackoff: true) }
        })
        
        // Safety-net: 60s fallback timer (catches edge cases)
        timer = Timer.scheduledTimer(withTimeInterval: safetyNetInterval, repeats: true) { [weak self] _ in
            Task { await self?.processReadyJobs(ignoreBackoff: false) }
        }
    }
    
    /// Stop the job runner
    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        #if DEBUG
        print("⏹️ [JobRunner] Stopped")
        #endif
    }
    
    /// Event-driven trigger: process jobs immediately
    func trigger(ignoreBackoff: Bool = false) async {
        await processReadyJobs(ignoreBackoff: ignoreBackoff)
    }
    
    // MARK: - Processing
    
    /// Process all ready jobs
    private func processReadyJobs(ignoreBackoff: Bool = false) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        
        // 1. Process mesh jobs (always, even offline for nearby peers)
        await processMeshJobs(ignoreBackoff: ignoreBackoff)
        
        // 2. Process server jobs (only if online)
        if net.isOnline {
            await net.syncControlPlaneIfNeeded(force: false)
            await processServerJobs(ignoreBackoff: ignoreBackoff)
            await processBridgeUplinks()
        }
        
        // 3. Cleanup old jobs periodically
        try? await DeliveryJobRepository.shared.cleanupOldJobs()
        try? await StopCacheRepository.shared.cleanupExpired()
    }
    
    // MARK: - Bridge Uplinks
    
    private func processBridgeUplinks() async {
        let envelopes = await RelayQueueRepository.shared.getEligible(excludingPeer: "SERVER_UPLINK")
        
        for envelope in envelopes {
            // Check if already stopped or successfully uploaded
            if (try? await StopCacheRepository.shared.isStopped(envelope.clientMessageId)) == true {
                await RelayQueueRepository.shared.remove(messageId: envelope.clientMessageId)
                continue
            }
            
            // Retry the uplink
            let success = await BLEMeshEngine.shared.bridgeMeshMessageToServer(envelope)
            if success {
                try? await Task.sleep(nanoseconds: 100_000_000) // Small delay to prevent API rate limits
            }
        }
    }

    
    // MARK: - Mesh Jobs
    
    private func processMeshJobs(ignoreBackoff: Bool) async {
        do {
            let jobs = try await DeliveryJobRepository.shared.getReadyJobs(channel: .mesh, ignoreBackoff: ignoreBackoff)
            

            
            guard !jobs.isEmpty else { return }
            
            // Check if we have active connections (Central OR Peripheral)
            #if !targetEnvironment(simulator)
            guard await mesh.hasActiveConnections else {
                return  // No peers - jobs stay pending
            }
            #if DEBUG
            print("[JobRunner] \(jobs.count) mesh jobs pending delivery")
            #endif
            #else
            return // simulator
            #endif
            
            for job in jobs {
                // Check if stopped
                if try await StopCacheRepository.shared.isStopped(job.messageId) {
                    try await DeliveryJobRepository.shared.markStopped(messageId: job.messageId)
                    continue
                }
                
                // Get message from DB
                guard let messageRow = try? await getMessageRow(job.messageId) else {
                    // ✅ Bug 7 fix: Message deleted — remove orphan job to stop infinite retries
                    // Previously used incrementAttempt which would reschedule forever, draining battery
                    try await DeliveryJobRepository.shared.markStopped(messageId: job.messageId)
                    #if DEBUG
                    print("🗑️ [JobRunner] Removed orphan mesh job: \(job.messageId.prefix(8)) (message deleted)")
                    #endif
                    continue
                }
                
                // Try to send via mesh
                do {
                    try await DeliveryJobRepository.shared.markInProgress(messageId: job.messageId, channel: .mesh)
                    
                    guard let message = parseMessage(messageRow) else {
                        throw JobError.invalidMessage
                    }
                    
                    guard message.type == .text || message.type == .location || message.type == .system else {
                        try await DeliveryJobRepository.shared.markDelivered(messageId: job.messageId, channel: .mesh)
                        continue
                    }
                    
                    // Trust verification happens on the receive side.
                    // Removing send-side trust gate to avoid 120s retry delays.
                    
                    let envelope = message.toMeshEnvelope()
                    

                    
                    await mesh.enqueueForBroadcast(envelope)
                    
                    // Note: We don't mark as delivered here
                    // Delivery confirmation comes from ACK
                    #if DEBUG
                    print("[JobRunner] ✅ mesh sent: \(job.messageId.prefix(8))")
                    #endif
                    
                    // Mark back to pending (waiting for ACK)
                    // Exponential backoff to prevent broadcast storm
                    let delay = min(TimeInterval(15 * pow(1.5, Double(job.attempts))), 3600)
                    try await DeliveryJobRepository.shared.incrementAttempt(
                        messageId: job.messageId,
                        channel: .mesh,
                        error: nil,
                        retryAfter: delay
                    )
                    
                } catch {
                    try await DeliveryJobRepository.shared.incrementAttempt(
                        messageId: job.messageId,
                        channel: .mesh,
                        error: error.localizedDescription
                    )
                }
            }
            
        } catch {
            #if DEBUG
            print("❌ [JobRunner] Mesh processing error: \(error)")
            #endif
        }
    }
    
    // MARK: - Server Jobs
    
    private func processServerJobs(ignoreBackoff: Bool) async {
        do {
            let jobs = try await DeliveryJobRepository.shared.getReadyJobs(channel: .server, ignoreBackoff: ignoreBackoff)
            
            guard !jobs.isEmpty else { return }
            
            #if DEBUG
            print("🔄 [JobRunner] Processing \(jobs.count) server jobs")
            #endif
            
            for job in jobs {
                // Check if stopped
                if try await StopCacheRepository.shared.isStopped(job.messageId) {
                    try await DeliveryJobRepository.shared.markStopped(messageId: job.messageId)
                    continue
                }
                
                // Get message from DB
                guard let messageRow = try? await getMessageRow(job.messageId) else {
                    // ✅ Bug 7 fix: Message deleted — remove orphan job to stop infinite retries
                    // Previously used incrementAttempt which would reschedule forever, draining battery
                    try await DeliveryJobRepository.shared.markStopped(messageId: job.messageId)
                    #if DEBUG
                    print("🗑️ [JobRunner] Removed orphan server job: \(job.messageId.prefix(8)) (message deleted)")
                    #endif
                    continue
                }
                
                // Try to send via server
                do {
                    try await DeliveryJobRepository.shared.markInProgress(messageId: job.messageId, channel: .server)
                    
                    let result = try await sendViaServer(messageRow)
                    
                    // Mark server job delivered
                    try await DeliveryJobRepository.shared.markDelivered(messageId: job.messageId, channel: .server)
                    
                    // If recipient actually received, stop mesh too
                    if result.recipientDelivered {
                        try await DeliveryJobRepository.shared.markStopped(messageId: job.messageId)
                        try? await StopCacheRepository.shared.persist(job.messageId)
                        await mesh.broadcastStop(job.messageId)
                        #if DEBUG
                        print("✅ [JobRunner] Recipient delivered - stopping mesh")
                        #endif
                    }
                    
                    #if DEBUG
                    print("✅ [JobRunner] Server job completed: \(job.messageId.prefix(8))")
                    #endif
                    
                } catch {
                    #if DEBUG
                    print("⚠️ [JobRunner] Server job failed: \(error)")
                    #endif
                    try await DeliveryJobRepository.shared.incrementAttempt(
                        messageId: job.messageId,
                        channel: .server,
                        error: error.localizedDescription,
                        retryAfter: 30
                    )
                }
            }
            
        } catch {
            #if DEBUG
            print("❌ [JobRunner] Server processing error: \(error)")
            #endif
        }
    }
    
    // MARK: - Helpers
    
    private func getMessageRow(_ messageId: String) async throws -> [String: Any]? {
        let sql = "SELECT * FROM messages WHERE client_message_id = ? LIMIT 1"
        let rows = try await DatabaseService.shared.query(sql, params: [messageId])
        return rows.first
    }
    
    private func parseMessage(_ row: [String: Any]) -> ChatMessage? {
        // Parse message from DB row
        guard let clientId = row["client_message_id"] as? String,
              let senderId = row["sender_id"] as? String,
              let recipientId = row["recipient_id"] as? String else {
            return nil
        }
        
        let text = row["text"] as? String ?? ""
        let roomId = row["room_id"] as? String ?? recipientId
        let senderName = row["sender_name"] as? String ?? ""
        let timestamp = (row["timestamp"] as? String).flatMap { PerformanceConstants.iso8601.date(from: $0) } ?? Date()
        let typeStr = row["type"] as? String ?? "text"
        let type = MessageType.from(name: typeStr)
        
        return ChatMessage(
            id: clientId,
            serverId: row["server_id"] as? String,
            roomId: roomId,
            senderId: senderId,
            senderName: senderName,
            recipientId: recipientId,
            text: text,
            timestamp: timestamp,
            type: type,
            status: .pending,
            deliveryAuthority: .unknown,
            createdAt: nil,
            deliveredAt: nil,
            readAt: nil,
            hopCount: 0,
            routePath: [],
            sprayCounter: PremiumLimits.meshSprayBudget,  // DTN default: use RAVEN+ limit
            hopLimit: PremiumLimits.meshHopLimit,      // DTN default: use RAVEN+ limit
            originDeviceId: DeviceIdentityService.shared.fingerprint ?? "",
            needsForwarding: true,
            attachmentUrl: row["remote_url"] as? String,
            thumbnailUrl: row["thumbnail_url"] as? String,
            fileName: row["file_name"] as? String,
            mimeType: row["mime_type"] as? String,
            fileSize: (row["file_size"] as? Int64).map { Int($0) },
            audioDurationSeconds: (row["audio_duration_seconds"] as? Int64).map { Int($0) },
            syncState: .synced,
            localPath: row["local_path"] as? String,
            uploadProgress: nil,
            lastError: nil,
            replyToMessageId: row["reply_to_message_id"] as? String,
            replyToTextPreview: row["reply_to_text_preview"] as? String,
            replyToSenderName: row["reply_to_sender_name"] as? String,
            replyToType: (row["reply_to_type"] as? String).map { MessageType.from(name: $0) },
            sendMode: nil,
            scheduledAtUtc: nil
        )
    }
    
    private func sendViaServer(_ row: [String: Any]) async throws -> ServerSendResult {
        guard let clientId = row["client_message_id"] as? String,
              let recipientId = row["recipient_id"] as? String,
              let text = row["text"] as? String else {
            throw JobError.invalidMessage
        }
        
        let roomId = row["room_id"] as? String ?? recipientId
        let isGroup = (try? await DatabaseService.shared.exists(
            "SELECT 1 FROM conversations WHERE room_id = ? AND (is_group = 1 OR is_channel = 1) LIMIT 1",
            params: [roomId]
        )) ?? false
        
        if isGroup {
            // Group message: use group endpoint
            let response: GroupMessageResponse = try await NetworkService.shared.post(
                path: "/api/groups/\(roomId)/messages",
                body: SendGroupMessageRequest(
                    messageId: clientId,
                    content: text,
                    messageType: row["type"] as? String ?? "text",
                    audioUrl: nil,
                    replyToMessageId: row["reply_to_message_id"] as? String,
                    replyToTextPreview: row["reply_to_text_preview"] as? String,
                    replyToSenderName: row["reply_to_sender_name"] as? String,
                    replyToType: row["reply_to_type"] as? String
                ),
                idempotencyKey: clientId
            )
            
            try await MessageRepository.shared.updateServerId(clientMessageId: clientId, serverId: response.id)
            try await MessageRepository.shared.updateStatus(clientMessageId: clientId, status: .sent)
            
            return ServerSendResult(
                messageId: response.id,
                status: "accepted",
                recipientDelivered: false,
                recipientOnline: false
            )
        } else {
            // 1:1 message: use regular endpoint
            let response: SendMessageResponse = try await NetworkService.shared.post(
                path: "/api/messages/send",
                body: SendMessageRequest(
                    messageId: clientId,
                    recipientId: recipientId,
                    content: text,
                    messageType: row["type"] as? String ?? "text",
                    audioUrl: nil,
                    replyToMessageId: row["reply_to_message_id"] as? String
                ),
                idempotencyKey: clientId
            )
            
            // Update message with server ID
            try await MessageRepository.shared.updateServerId(clientMessageId: clientId, serverId: response.id)
            try await MessageRepository.shared.updateStatus(clientMessageId: clientId, status: .sent)
            
            return ServerSendResult(
                messageId: response.id,
                status: response.status ?? "accepted",
                recipientDelivered: response.recipientDelivered ?? false,
                recipientOnline: response.recipientOnline ?? false
            )
        }
    }
}

// MARK: - Server Send Result

struct ServerSendResult {
    let messageId: String
    let status: String  // "accepted", "delivered", "queued_for_push"
    let recipientDelivered: Bool
    let recipientOnline: Bool
}

// MARK: - Errors

enum JobError: Error {
    case invalidMessage
    case timeout
}
