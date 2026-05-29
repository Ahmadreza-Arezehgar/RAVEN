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
        
        // 🚨 DTN: Protect user-initiated send with a background task. The state
        // is held in a @MainActor-isolated TaskBox so we don't need an NSLock —
        // both the expiration callback (which UIKit fires on the main thread)
        // and our explicit end() calls funnel through the same actor.
        let box = await MainActor.run { SendBackgroundTaskBox() }

        let assignedId = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "raven.send.\(mid.prefix(8))") {
                #if DEBUG
                print("⚠️ [Router] Background task expired for \(mid.prefix(8))")
                #endif
                box.end()
            }
        }

        // 🛡️ If the expiration handler fired before the ID was assigned,
        // setId() will end it for us instead of leaking the assertion.
        await MainActor.run { box.setId(assignedId) }
        
        // NOTE: Do NOT use defer { box.end() } here — the background task must
        // stay alive until the async server send completes. box.end() is called
        // explicitly at each branch's completion point below.
        
        // 1. Persist first (Golden Rule: never lose messages).
        // OutboxEntry.create is now async because the body is
        // sealed through MessageContentSealer (see OutboxEntry.swift).
        let entry = await OutboxEntry.create(
            clientMessageId: mid,
            receiverId: receiverId,
            payload: text,
            serverState: .queued,
            meshState: .idle
        )
        
        do {
            try await outbox.insert(entry)
            
            // Bug #7 fix: Create persistent DeliveryJobs for background processing.
            // Without this, DeliveryJobRunner never picks up messages sent via
            // MessageRouter. MessageRouter only handles text messages, which
            // are always allowed over both server and mesh.
            try await DeliveryJobRepository.shared.createJobs(
                messageId: mid,
                channels: [.server, .mesh]
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
        // AuthService is now @MainActor (2026-05-10) — hop to main once.
        let myName = await MainActor.run { AuthService.shared.currentUser?.displayName ?? "" }
        let deviceId = await getDeviceId()
        
        // Adaptive Spray: use network density-based spray count when enabled
        let sprayCount: Int
        if FeatureFlag.isAdaptiveSprayEnabled {
            sprayCount = await BLEMeshEngine.shared.adaptiveSprayCount()
        } else {
            sprayCount = config.sprayCounter
        }
        
        // Bug 2 fix: Use DB-based group detection instead of string comparison
        let actualRoomId = msgRow?["room_id"] as? String ?? receiverId
        let isGroupMsg = (try? await DatabaseService.shared.exists("SELECT 1 FROM groups WHERE id = ? LIMIT 1", params: [actualRoomId])) ?? false

        // 🔴 ROUND 19 (2026-05-16) — hacker-audit Mesh F1 CRITICAL.
        // Before this fix the 1:1 mesh path shipped `text: payload`
        // straight to the wire — only Ed25519-SIGNED, never
        // ENCRYPTED. A relay node JSON-decoded the
        // `SignedMeshPayload` and read the body in cleartext.
        //
        // For 1:1 messages we now run the body through
        // `MessageContentSealer.seal(...)` which wraps it in the
        // RVNS1 Noise transport envelope (AAD bound to sender +
        // recipient + msgId). For group messages we keep the
        // existing per-group AES-GCM path (non-members can't
        // decrypt; member-on-relay is unavoidable by definition).
        // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — UNCONDITIONAL
        // E2EE. Per security policy, the bridge device in the
        // middle MUST NOT be able to decode the body. The pre-fix
        // code had TWO bypass paths that violated this:
        //
        //   1. `peerVerdict == .legacyClient` short-circuit shipped
        //      RAW PLAINTEXT (the exact "contentPrefix='Gut'"
        //      production log that surfaced this regression). Any
        //      peer that was ever misclassified as legacy started
        //      receiving cleartext on every send.
        //
        //   2. `MessageContentSealer.seal`'s fallback wrapped
        //      plaintext in an `RVNP1` magic prefix and base64-
        //      encoded the result. The body is base64-decodable by
        //      the bridge — still cleartext from the relay's POV.
        //
        // New rule: if we can't produce a Noise-AEAD ciphertext OR
        // a group AES-GCM ciphertext, we REFUSE to ship. The
        // message stays in the outbox; the user sees a "waiting to
        // deliver" status until the peer's prekey bundle / Noise
        // session becomes available. This trades worse latency for
        // strict E2EE — non-negotiable per RAVEN's threat model.
        var sealedTextForWire: String = ""   // empty = "must seal"
        var sealedReason: SealedContent.SealReason = .noRecipientKey
        if !isGroupMsg {
            // No more legacy-plaintext branch — every 1:1 envelope
            // MUST seal via Noise transport. If the sealer can't
            // (no session, no recipient key), we hold the message
            // in the outbox.
            let sealed = await MessageContentSealer.seal(
                plaintext: payload,
                senderUserId: myId,
                recipientUserId: receiverId,
                recipientAgreementPubKey: nil,
                msgId: mid
            )

            // 🔴 ROUND 71 phase 3 follow-up — fail-closed on the
            // plaintext fallback. `sealed.isEncrypted == false`
            // means the sealer returned `RVNP1` (plaintext
            // wrapped in a magic header). For mesh — where the
            // wire is observed by every relay — we treat this as
            // "could not encrypt" and refuse to ship. Sender's
            // outbox keeps the message; a future retry once the
            // peer's prekey lands will succeed. The on-screen
            // bubble badge surfaces `.suspectedLegacy` so the user
            // knows why delivery is pending.
            guard sealed.isEncrypted, !sealed.base64.isEmpty else {
                #if DEBUG
                print("🔒 [Router] REFUSING to ship plaintext for \(mid.prefix(8)) — sealer fell back (reason=\(sealed.reason)). Will retry when peer key/session is available.")
                #endif
                await MessageContentSealer.recordSealVerdict(sealed.reason, for: mid)
                await PeerProtocolCapabilityStore.shared
                    .record(.suspectedLegacy, for: receiverId)
                // Keep the outbox row pending so a later retry can
                // attempt the seal again. Do NOT broadcast a
                // plaintext envelope to the mesh.
                try? await outbox.updateMeshState(clientMessageId: mid, state: .queued)
                return
            }

            sealedTextForWire = sealed.base64
            sealedReason = sealed.reason
            // Tag our own bubble with the verdict so the sender's
            // lock badge reflects what we put on the wire.
            await MessageContentSealer.recordSealVerdict(sealed.reason, for: mid)
            // Successful Noise-transport seal means the peer is on
            // a modern (round-26+) build that understands RVNS1.
            await PeerProtocolCapabilityStore.shared.record(.modernATSAM, for: receiverId)
        }

        // 🔴 ROUND 21 — hacker-audit Mesh F4.
        //
        // The previous envelope shipped `senderName` in plaintext on
        // every spray-and-wait broadcast. Every relay node saw it
        // — a relay along the path could build a (senderId, real-
        // display-name) graph with zero effort. The receiver
        // already knows the sender via `senderId`, and any honest
        // contact UI looks the display-name up from the local
        // ContactStore / ConversationStore by senderId. We can
        // drop the name from the wire.
        //
        // For groups we keep `senderName` because non-recipients
        // in the group may not have the sender in their contacts
        // yet (e.g. fresh group join). Trade-off accepted.
        let outboundSenderName = isGroupMsg ? myName : ""

        var envelope = MeshEnvelope(
            clientMessageId: mid,
            roomId: msgRow?["room_id"] as? String ?? receiverId,
            senderId: myId,
            senderName: outboundSenderName,
            recipientId: receiverId,
            type: msgType.index,
            text: sealedTextForWire,
            timestamp: Date().timeIntervalSince1970,
            sprayCounter: sprayCount,
            hopCount: 0,
            hopLimit: PremiumLimits.meshHopLimit,
            routePath: [deviceId],
            originDeviceId: deviceId,
            needsForwarding: true
        )
        envelope.ttlSeconds = PremiumLimits.meshTTLSeconds

        // 🔴 ROUND 26 — hacker-audit MESH-CRIT-2.
        //   Always populate the hashed identity tokens so any v1.7
        //   receiver can resolve the envelope without depending on
        //   raw plaintext userIds. When the peer is confirmed
        //   `.modernATSAM` we ALSO null the raw `senderId` /
        //   `recipientId` on the wire — see strict-strip block
        //   further down for the gate. For all other peers (legacy /
        //   unknown) raw IDs remain on the wire for back-compat.
        envelope.senderIdHash = MeshIdentityToken.hash(userId: myId)
        envelope.recipientIdHash = MeshIdentityToken.hash(userId: receiverId)
        // Register both ends with the local resolver so our own
        // receive path can map them back from any incoming envelope
        // that reaches us as a relay (e.g. our own messages echoed
        // back via spray, or replies addressed to us).
        let myIdSnapshot = myId
        let receiverIdSnapshot = receiverId
        Task.detached {
            await MeshIdentityResolver.shared.register(userId: myIdSnapshot)
            await MeshIdentityResolver.shared.register(userId: receiverIdSnapshot)
        }

        // Round 21 — Mesh F4: `geoFence` field used to ride the
        // signed envelope in plaintext, leaking the user's
        // approximate location to every relay along the spray
        // path. The geo-fence enforcement is a SENDER-side hint
        // (we refuse to relay onward when outside the radius);
        // receivers don't need it at all because the server
        // dedups + the geo-restriction is enforced upstream.
        // Strip from outbound 1:1 envelopes.
        envelope.geoFence = nil

        #if DEBUG
        print("📡 [Router] Message \(mid.prefix(8)) created with sprayCount=\(sprayCount) (adaptive=\(FeatureFlag.isAdaptiveSprayEnabled), seal=\(sealedReason))")
        #endif

        envelope.isGroup = isGroupMsg

        // 🔐 Per-group AES-GCM encryption — for group mesh messages we
        // wrap the payload with the group's symmetric key BEFORE broadcast.
        // Outsiders who learn the groupId can no longer flood the cluster
        // with valid envelopes; they'd also need the symmetric key.
        if isGroupMsg {
            if let (cipherB64, version) = await GroupKeyService.shared.encrypt(payload, groupId: actualRoomId) {
                envelope.text = cipherB64
                envelope.groupKeyVersion = version
            } else {
                #if DEBUG
                print("⚠️ [Router] Could not fetch group key for \(actualRoomId.prefix(8)) — REFUSING to send (no plaintext fallback).")
                #endif
                // Round 19 — Mesh F1: fail-closed rather than ship
                // plaintext. The outbox keeps the row pending and a
                // future retry can attempt the key fetch again.
                try? await outbox.updateMeshState(clientMessageId: mid, state: .queued)
                return
            }
        }

        if let replyToId = msgRow?["reply_to_message_id"] as? String {
            envelope.replyToMessageId = replyToId
            // Round 14 + 19 — Mesh F4 / Server F6: never ship the
            // reply preview in cleartext. The receiver looks it up
            // locally from their own DB by replyToMessageId.
            envelope.replyToTextPreview = nil
            // 🔴 ROUND 26 — hacker-audit MESH-MED-10.
            //   `replyToSenderName` was the last attacker-controllable
            //   string still landing in the recipient's chat surface
            //   under a legitimate signature. A sender could choose
            //   any string ("CEO of RAVEN") and have it render as the
            //   quoted reply's author. Drop it on the wire — the
            //   receiver looks up the parent message's senderId in
            //   their own contact directory and resolves a name from
            //   there, same flow as the main message's senderName.
            envelope.replyToSenderName = nil
        }

        // 🔴 ROUND 71 phase 3 (2026-05-24) — sign the message in the
        // server's `msg-v1:sender:recip:msgId:content` canonical
        // format so a bridge upload can be cryptographically
        // attributed back to the original sender. Pre-fix the
        // sender signed only the mesh pipe-delimited transcript,
        // which the server's bridge verifier can't parse — every
        // cross-user bridge fell back to attribution_verified=false
        // (R71 p3 server relax) or was outright rejected (pre-relax).
        // With this signature in the envelope, /api/messages/bridge
        // can run `verify_message_signature(canonical, sig, pub)`
        // and stamp attribution_verified=true.
        //
        // SAFETY: signed BEFORE the modernATSAM strict-strip below
        // so `myId` / `receiverId` are the REAL ids — the receiver
        // (and bridge) will resolve hashed tokens back to the same
        // real ids via MeshIdentityResolver before verifying.
        // Group messages: `receiverId == groupId` (server bridge
        // accepts this shape on the group fanout path).
        let canonicalPayload = "msg-v1:\(myId):\(receiverId):\(mid):\(envelope.text ?? "")"
        if let canonicalData = canonicalPayload.data(using: .utf8),
           let sigBytes = DeviceIdentityService.shared.sign(canonicalData) {
            envelope.originalSignature = sigBytes.base64EncodedString()
            envelope.originalSignerPublicKey = DeviceIdentityService.shared.publicKeyBase64
        } else {
            // Signing failed (no identity key yet?) — leave the
            // signature off and accept that the bridge will degrade
            // to attribution_verified=false on the server. Better
            // than refusing to send.
            #if DEBUG
            print("⚠️ [Router] msg-v1 signing failed for \(mid.prefix(8)) — bridge will fall back to unverified attribution")
            #endif
        }

        // 🔴 ROUND 70 — strict-strip block (the round-26 promise
        // finally implemented). When the peer is confirmed
        // `.modernATSAM` they understand the hashed identity tokens
        // (senderIdHash / recipientIdHash) and can resolve userIds
        // via their local MeshIdentityResolver — so the raw userIds
        // become redundant on the wire AND a passive-listener leak.
        // For non-modern peers (legacy / unknown capability) raw IDs
        // stay on the wire so back-compat doesn't break.
        //
        // Implementation: `MeshEnvelope.senderId` and `.recipientId`
        // are non-optional `let` properties, so we can't literally
        // null them. Instead we set them to the EMPTY string when
        // safe to strip — a modern receiver treats empty as
        // "resolve from hash"; a legacy receiver wouldn't ever see
        // an empty string because we only strip for confirmed
        // modern peers.
        if !isGroupMsg {
            let receiverCapability = await PeerProtocolCapabilityStore.shared.level(for: receiverId)
            if receiverCapability == .modernATSAM {
                // Snapshot the msg-v1 signature + pubkey BEFORE
                // rebuilding the envelope so the new instance
                // preserves them across the strip.
                let preservedOriginalSig = envelope.originalSignature
                let preservedOriginalSigKey = envelope.originalSignerPublicKey
                envelope = MeshEnvelope(
                    protocolVersion: envelope.protocolVersion,
                    clientMessageId: envelope.clientMessageId,
                    roomId: envelope.roomId,
                    senderId: "",
                    senderName: envelope.senderName,
                    recipientId: "",
                    type: envelope.type,
                    text: envelope.text,
                    timestamp: envelope.timestamp,
                    sprayCounter: envelope.sprayCounter,
                    hopCount: envelope.hopCount,
                    hopLimit: envelope.hopLimit,
                    routePath: envelope.routePath,
                    originDeviceId: envelope.originDeviceId,
                    needsForwarding: envelope.needsForwarding
                )
                // Re-stamp the fields that the memberwise init doesn't
                // accept (post-default fields).
                envelope.senderIdHash = MeshIdentityToken.hash(userId: myId)
                envelope.recipientIdHash = MeshIdentityToken.hash(userId: receiverId)
                envelope.ttlSeconds = PremiumLimits.meshTTLSeconds
                envelope.replyToMessageId = msgRow?["reply_to_message_id"] as? String
                envelope.replyToTextPreview = nil
                envelope.replyToSenderName = nil
                envelope.isGroup = false
                // Preserve the msg-v1 signature across the strip.
                envelope.originalSignature = preservedOriginalSig
                envelope.originalSignerPublicKey = preservedOriginalSigKey
                #if DEBUG
                print("📡 [Router] Stripped raw senderId/recipientId for modernATSAM peer — passive listener now sees hashes only.")
                #endif
            }
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

/// Holds the UIKit background-task identifier for an in-flight send. UIKit
/// invokes the expiration handler on the main thread, and our async send
/// path also hops to MainActor whenever it touches this state, so all
/// reads/writes are serialised by the actor without needing an NSLock.
@MainActor
final class SendBackgroundTaskBox {
    private var id: UIBackgroundTaskIdentifier = .invalid
    private(set) var isEnded = false

    func setId(_ newId: UIBackgroundTaskIdentifier) {
        // If end() already fired (because UIKit expired the task before we
        // even got the identifier back), end the freshly-issued one too —
        // otherwise the assertion leaks until the app is suspended.
        if isEnded, newId != .invalid {
            UIApplication.shared.endBackgroundTask(newId)
            id = .invalid
            return
        }
        id = newId
    }

    func end() {
        isEnded = true
        if id != .invalid {
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}
