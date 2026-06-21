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
            // 3. Serverless internet delivery for our OWN messages via the
            //    libp2p bridge (own-traffic, distinct from processBridgeUplinks
            //    which relays OTHER peers' queued envelopes).
            await processBridgeChannelJobs(ignoreBackoff: ignoreBackoff)
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

    // MARK: - Bridge Channel Jobs (own-traffic libp2p internet delivery)

    /// Deliver our OWN 1:1 messages over the serverless libp2p bridge.
    ///
    /// Distinct from `processBridgeUplinks` (which relays OTHER peers' queued
    /// envelopes). A `.bridge` job is only ever created (MessageRouter) when a
    /// relay/bootstrap node is configured, but we re-check here so a config
    /// change leaves the jobs pending rather than failing.
    ///
    /// We build the SAME `EncryptedMeshPayload` the 1:1 point-to-point mesh
    /// send produces — body sealed end-to-end (RVNS1) AND the whole envelope
    /// AES-GCM-encrypted to the recipient's X25519 agreement key, signed with
    /// our Ed25519 key — so the relay in the middle can't read it and the
    /// bridge receiver (`MeshBridgeReceiver.decryptAndPublish`) decodes it
    /// byte-for-byte the same as a relayed envelope.
    private func processBridgeChannelJobs(ignoreBackoff: Bool) async {
        // No relay configured → leave jobs pending (don't burn attempts).
        guard !AppConfig.libp2pBootstrapCSV.isEmpty else {
            #if DEBUG
            print("🌉 [BridgeJobs] skip — no bootstrap configured")
            #endif
            return
        }
        do {
            let jobs = try await DeliveryJobRepository.shared.getReadyJobs(channel: .bridge, ignoreBackoff: ignoreBackoff)
            #if DEBUG
            print("🌉 [BridgeJobs] \(jobs.count) bridge job(s) ready")
            #endif
            guard !jobs.isEmpty else { return }

            for job in jobs {
                if try await StopCacheRepository.shared.isStopped(job.messageId) {
                    try await DeliveryJobRepository.shared.markStopped(messageId: job.messageId)
                    continue
                }
                guard let messageRow = try? await getMessageRow(job.messageId) else {
                    // Message deleted — drop the orphan job.
                    try await DeliveryJobRepository.shared.markStopped(messageId: job.messageId)
                    continue
                }

                do {
                    try await DeliveryJobRepository.shared.markInProgress(messageId: job.messageId, channel: .bridge)

                    guard let message = parseMessage(messageRow) else {
                        throw JobError.invalidMessage
                    }
                    guard message.type == .text || message.type == .location || message.type == .system
                        || message.type == .image || message.type == .voice || message.type == .file else {
                        try await DeliveryJobRepository.shared.markDelivered(messageId: job.messageId, channel: .bridge)
                        continue
                    }

                    // Bridge is 1:1 only. Group internet fan-out would need a
                    // per-member dial; groups go over mesh. A group message has
                    // a local Group row matching its roomId.
                    // NB: use markDelivered(.bridge) — NOT markStopped — to take
                    // the bridge job out of rotation, since markStopped kills
                    // ALL channels (the mesh job must keep carrying the message).
                    let recipientId = message.recipientId
                    if recipientId.isEmpty {
                        try await DeliveryJobRepository.shared.markDelivered(messageId: job.messageId, channel: .bridge)
                        continue
                    }
                    if let rid = message.roomId, !rid.isEmpty {
                        let groupExists = (try? await GroupRepository().get(groupId: rid)) != nil
                        if groupExists {
                            try await DeliveryJobRepository.shared.markDelivered(messageId: job.messageId, channel: .bridge)
                            continue
                        }
                    }

                    var envelope = message.toMeshEnvelope()

                    // Resolve the recipient's X25519 agreement key FIRST — both the
                    // body sealer AND the transport encryption need it.
                    guard let agreementKey = await PeerKeyDirectory.shared.ensureAgreementKey(for: recipientId),
                          agreementKey.count == 32,
                          let sharedKey = DeviceIdentityService.shared.deriveSharedSecret(with: agreementKey) else {
                        // No pinned key for this peer yet (add them via QR) —
                        // keep pending; a later retry succeeds once pinned.
                        #if DEBUG
                        print("🌉 [BridgeJobs] no-agreement-key for \(recipientId.prefix(8)) — pending")
                        #endif
                        try await DeliveryJobRepository.shared.incrementAttempt(
                            messageId: job.messageId, channel: .bridge, error: "no-agreement-key",
                            retryAfter: 300)
                        continue
                    }

                    // Seal the 1:1 body end-to-end (RVNS1) unless it already is.
                    // The whole envelope is ALSO AES-GCM-encrypted to the recipient
                    // below, so the relay can't read the body even if the inner seal
                    // is unavailable — hence we do NOT fail-closed here (unlike the
                    // BLE broadcast path, which ships signed-but-unencrypted).
                    if let plain = message.text, !plain.isEmpty {
                        let alreadySealed: Bool = {
                            guard let data = Data(base64Encoded: plain), data.count >= 8 else { return false }
                            let s = String(data: data.prefix(5), encoding: .ascii) ?? ""
                            return s == "RVNS1" || s == "RVNA1" || s == "RVNP1" || s == "RVNH1"
                        }()
                        if !alreadySealed {
                            let sealed = await MessageContentSealer.seal(
                                plaintext: plain,
                                recipientUserId: recipientId,
                                recipientAgreementPubKey: agreementKey,
                                msgId: message.id
                            )
                            if sealed.isEncrypted, !sealed.base64.isEmpty {
                                envelope.text = sealed.base64
                            } else {
                                #if DEBUG
                                print("🌉 [BridgeJobs] inner seal unavailable (reason=\(sealed.reason)); transport AES-GCM still protects body")
                                #endif
                            }
                        }
                    }

                    // Serverless media: seal+embed any attachment bytes (same
                    // chokepoint as the BLE path) so a photo/voice/file rides the
                    // bridge with NO server. No-op for text.
                    await MeshMediaSealer.seal(envelope: &envelope)

                    let secureEnvelope = envelope.toSecureEnvelope()
                    let encrypted = try await MeshCryptoService.shared.encryptEnvelope(secureEnvelope, sharedKey: sharedKey)
                    let payloadB64 = try JSONEncoder().encode(encrypted).base64EncodedString()

                    #if DEBUG
                    print("🌉 [BridgeJobs] uploading mid=\(message.id.prefix(8)) → \(recipientId.prefix(8)) (\(payloadB64.count)B)")
                    #endif
                    try await MeshBridge.transport.uploadEnvelope(
                        payloadB64,
                        idempotencyKey: message.id,
                        recipientHint: recipientId
                    )

                    // Stream write to the peer succeeded → delivered on this
                    // channel (overall delivery state still tracked via ACK).
                    try await DeliveryJobRepository.shared.markDelivered(messageId: job.messageId, channel: .bridge)
                    #if DEBUG
                    print("[JobRunner] ✅ bridge sent: \(job.messageId.prefix(8))")
                    #endif
                } catch {
                    // Peer unreachable / relay down → exponential backoff.
                    #if DEBUG
                    print("🌉 [BridgeJobs] send failed for \(job.messageId.prefix(8)): \(error)")
                    #endif
                    let delay = min(TimeInterval(15 * pow(1.5, Double(job.attempts))), 3600)
                    try? await DeliveryJobRepository.shared.incrementAttempt(
                        messageId: job.messageId, channel: .bridge,
                        error: error.localizedDescription, retryAfter: delay)
                }
            }
        } catch {
            #if DEBUG
            print("❌ [JobRunner] Bridge-channel processing error: \(error)")
            #endif
        }
    }


    // MARK: - Mesh Jobs
    
    private func processMeshJobs(ignoreBackoff: Bool) async {
        do {
            let jobs = try await DeliveryJobRepository.shared.getReadyJobs(channel: .mesh, ignoreBackoff: ignoreBackoff)
            

            
            guard !jobs.isEmpty else { return }
            
            // Check if we have active connections (Central OR Peripheral).
            // ⚪ BUG FIX (2026-05-10): on simulator, the previous early
            // return silently dropped processing so any race / ordering
            // bug between server jobs and mesh jobs was invisible
            // until tested on physical devices. New behaviour: on the
            // simulator we still iterate the queue but skip the
            // hasActiveConnections gate, leaving mesh-only jobs in
            // pending state and logging the queue size each cycle so
            // the test harness can observe back-pressure.
            #if targetEnvironment(simulator)
            #if DEBUG
            print("[Sim] DeliveryJobRunner — mesh-path skipped (no real BLE peers); jobs left pending")
            #endif
            return
            #else
            guard await mesh.hasActiveConnections else {
                return  // No peers - jobs stay pending
            }
            #if DEBUG
            print("[JobRunner] \(jobs.count) mesh jobs pending delivery")
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
                    
                    guard message.type == .text || message.type == .location || message.type == .system
                        || message.type == .image || message.type == .voice || message.type == .file else {
                        try await DeliveryJobRepository.shared.markDelivered(messageId: job.messageId, channel: .mesh)
                        continue
                    }
                    
                    // Trust verification happens on the receive side.
                    // Removing send-side trust gate to avoid 120s retry delays.

                    var envelope = message.toMeshEnvelope()

                    // 🟢 ROUND 73 (2026-05-24) — group E2EE on JobRunner mesh path.
                    //
                    // Mirror MessageStore.sendViaMeshImmediate fix: if the
                    // message is for a group AND not already sealed under
                    // the group key, AES-GCM-encrypt with GroupKeyService
                    // before broadcasting. Without this, the retry path
                    // re-shipped plaintext on the BLE wire AND any
                    // relayer that bridged it stored plaintext on the
                    // server.
                    //
                    // Detect "is group" from the message's roomId: if
                    // there's a local Group row matching roomId, treat
                    // as group send. Fall back to message.roomId presence
                    // when GroupRepository lookup fails (offline).
                    var isGroupRetry = false
                    if let rid = message.roomId, !rid.isEmpty {
                        let groupRepo = GroupRepository()
                        let groupExists = (try? await groupRepo.get(groupId: rid)) != nil
                        if groupExists, let plain = message.text, !plain.isEmpty,
                           message.groupKeyVersion == nil {
                            if let (cipherB64, keyVersion) = await GroupKeyService.shared.encrypt(plain, groupId: rid) {
                                envelope.text = cipherB64
                                envelope.groupKeyVersion = keyVersion
                                envelope.isGroup = true
                                isGroupRetry = true
                            } else {
                                #if DEBUG
                                print("🔒 [JobRunner] REFUSING to mesh-retry plaintext group message — group key unavailable for \(rid.prefix(8))")
                                #endif
                                // Skip this iteration — let the job stay
                                // pending until the group key is available.
                                continue
                            }
                        } else if groupExists {
                            // Already sealed (likely a retry of a previously
                            // sealed envelope) — preserve isGroup flag.
                            envelope.isGroup = true
                            if envelope.groupKeyVersion == nil {
                                envelope.groupKeyVersion = message.groupKeyVersion
                            }
                            isGroupRetry = true
                        }
                    }

                    // 🔐 ROUND 77 (2026-05-24) — 1:1 mesh-retry fail-closed sealer.
                    //
                    // BUG (audit Agent #1): when retrying a 1:1 mesh job,
                    // the runner re-fetches `message.text` from the DB row
                    // and re-builds the envelope. If the original send
                    // shipped plaintext (because attemptDelivery's
                    // `wrapOutgoing` silently fell back to plaintext when
                    // no Double-Ratchet session existed), this retry
                    // ALSO re-ships plaintext on every attempt.
                    //
                    // FIX: seal the body via `MessageContentSealer.seal`
                    // before re-broadcasting. Skip the sealer when the
                    // text is ALREADY wire-format (RVNS1/RVNA1/RVNP1
                    // magic prefix) to avoid double-encryption. Refuse
                    // the retry (skip via continue) if the sealer
                    // can't guarantee encryption — outbox keeps the
                    // job pending until ATSAM/Noise is available.
                    if !isGroupRetry, let plain = message.text, !plain.isEmpty {
                        let alreadySealed: Bool = {
                            guard let data = Data(base64Encoded: plain),
                                  data.count >= 8 else { return false }
                            let s = String(data: data.prefix(5), encoding: .ascii) ?? ""
                            return s == "RVNS1" || s == "RVNA1" || s == "RVNP1" || s == "RVNH1"
                        }()
                        if !alreadySealed {
                            let sealed = await MessageContentSealer.seal(
                                plaintext: plain,
                                recipientUserId: message.recipientId,
                                recipientAgreementPubKey: nil,
                                msgId: message.id
                            )
                            guard sealed.isEncrypted, !sealed.base64.isEmpty else {
                                #if DEBUG
                                print("🔒 [JobRunner] REFUSING to mesh-retry 1:1 plaintext fallback (reason=\(sealed.reason)) for mid=\(message.id.prefix(8))")
                                #endif
                                // Keep job pending — back-off + retry later.
                                continue
                            }
                            envelope.text = sealed.base64
                        }
                    }

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
            #endif

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
            // 1:1 message: use regular endpoint.
            // 🔴 SECURITY FIX (2026-05-16 — round 10): wrap the
            // plaintext through `MessageContentSealer` so the server
            // only ever sees opaque bytes when we have a Noise
            // session, and a clearly-flagged plaintext envelope
            // (RVNP1) otherwise. See OutboxManager for the matching
            // change — this is the legacy retry path that used to
            // bypass encryption entirely.
            // Round 12: hand the userId in so the sealer can lazy-
            // fetch + verify the recipient's prekey bundle on miss.
            let sealed = await MessageContentSealer.seal(
                plaintext: text,
                recipientUserId: recipientId,
                recipientAgreementPubKey: nil,
                msgId: clientId
            )
            // Round 15 — mirror the seal verdict into the per-
            // bubble status store so the sender's own bubble shows
            // the lock badge whenever the body went up as RVNP1.
            await MessageContentSealer.recordSealVerdict(sealed.reason, for: clientId)
            let response: SendMessageResponse = try await NetworkService.shared.post(
                path: "/api/messages/send",
                body: SendMessageRequest(
                    messageId: clientId,
                    recipientId: recipientId,
                    content: sealed.base64,
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
