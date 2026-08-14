import Foundation
import SwiftUI
import Combine
import UserNotifications

// MARK: - Conversation Store (Source of Truth = DB)
@MainActor
@Observable
class ConversationStore {
    static let shared = ConversationStore()
    
    var conversations: [Conversation] = []
    var isLoading = false
    var error: Error?
    var lastSyncTime: Date?
    
    /// Search query for filtering conversations
    var searchQuery: String = ""
    
    /// Filtered conversations based on search query
    var filteredConversations: [Conversation] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return conversations }
        
        return conversations.filter { c in
            c.peer.displayName.lowercased().contains(q)
            || (c.lastMessage?.content?.lowercased().contains(q) ?? false)
        }
    }
    
    private let conversationRepo = ConversationRepository.shared
    private let messageRepo = MessageRepository.shared
    private var lastFetchedTimestamp: String?
    
    nonisolated private init() {}
    
    // MARK: - Fetch from API (with since parameter)
    
    func fetchConversations(forceFull: Bool = false) async {
        // Offline-first: Skip server if no network
        guard NetworkMonitor.shared.isOnline || forceFull else {
            #if DEBUG
            print("📦 [ConversationStore] Offline - loading from DB only")
            #endif
            await loadFromDB()
            return
        }
        
        isLoading = true
        error = nil
        
        do {
            // Use since parameter for incremental updates
            var queryItems = [URLQueryItem(name: "limit", value: "50")]
            
            if !forceFull, let since = lastFetchedTimestamp {
                queryItems.append(URLQueryItem(name: "since", value: since))
            }
            
            let fetched: [Conversation] = try await NetworkService.shared.get(
                path: "/api/messages/conversations",
                queryItems: queryItems
            )
            
            // DEBUG: Show groups fetched
            let groups = fetched.filter { $0.isGroup }
            #if DEBUG
            print("👥 [ConversationStore] Fetched \(fetched.count) conversations, \(groups.count) groups")
            #endif
            for g in groups {
                #if DEBUG
                print("   GROUP: \(g.groupName ?? "unnamed") roomId:\(g.roomId.prefix(8))")
                #endif
            }
            
            // Update last fetch timestamp
            if let latest = fetched.first?.updatedAt {
                lastFetchedTimestamp = PerformanceConstants.iso8601.string(from: latest)
            }
            
            // Write-through to DB
            for conversation in fetched {
                try? await conversationRepo.upsert(conversation)
            }
            
            // Merge any duplicate conversations at DB level
            try? await conversationRepo.deduplicateByPeerId()
            
            // Hydrate any conversations with missing peer names (shows "User UUID")
            await conversationRepo.hydrateMissingPeerInfo()
            
            // Reload from DB (source of truth)
            await loadFromDB()
            
            lastSyncTime = Date()
            isLoading = false
            
        } catch {
            #if DEBUG
            print("❌ [ConversationStore] fetchConversations failed: \(error)")
            #endif
            if let apiError = error as? APIError {
                #if DEBUG
                print("❌ [ConversationStore] APIError type: \(apiError)")
                #endif
            }
            self.error = error
            isLoading = false
            
            // Still try to load from DB (offline-first)
            await loadFromDB()
        }
    }
    
    // MARK: - Load from DB (Primary data source)
    
    /// Insert (or update) a conversation locally without round-tripping the
    /// database. Used for snappy UI when starting a new chat offline — the
    /// chat appears immediately and the DB is upserted in parallel.
    func addLocally(_ conversation: Conversation) {
        if let idx = conversations.firstIndex(where: { $0.roomId == conversation.roomId }) {
            conversations[idx] = conversation
        } else {
            conversations.append(conversation)
        }
        sortConversations()
    }

    func loadFromDB() async {
        do {
            let rows = try await conversationRepo.getAllSorted()
            
            // DEBUG: Show all conversations in DB
            #if DEBUG
            print("🟡 [ConversationStore] ════ ALL CONVERSATIONS IN DB ════")
            #endif
            for (index, conv) in rows.enumerated() {
                let groupInfo = conv.isGroup ? " [GROUP: \(conv.groupName ?? "unnamed")]" : ""
                #if DEBUG
                print("🟡 [\(index)] roomId:\(conv.roomId.prefix(8)) peerId:\(conv.peer.userId.prefix(8)) name:\(conv.peer.displayName)\(groupInfo)")
                #endif
            }
            #if DEBUG
            print("🟡 [ConversationStore] ════════════════════════════════")
            #endif
            
            // Filter out empty/invalid conversations first
            let validRows = rows.filter { !$0.roomId.isEmpty }
            
            // For groups: dedupe by roomId (group ID)
            // For 1:1: dedupe by peer.userId
            var seenKeys: Set<String> = []
            var dedupedConversations: [Conversation] = []
            
            for conversation in validRows {
                // Groups use roomId as unique key, 1:1 use peerId
                let uniqueKey = conversation.isGroup ? "group:\(conversation.roomId)" : "peer:\(conversation.peer.userId)"
                
                if !seenKeys.contains(uniqueKey) {
                    seenKeys.insert(uniqueKey)
                    
                    // For GROUPS: Keep the original roomId (group ID from server)
                    if conversation.isGroup {
                        dedupedConversations.append(conversation)
                    } else {
                        // For 1:1: Normalize roomId to peer.userId for consistency
                        let peerId = conversation.peer.userId
                        var normalizedConversation = conversation
                        if conversation.roomId != peerId {
                            #if DEBUG
                            print("🔧 [ConversationStore] Normalizing roomId \(conversation.roomId.prefix(8)) -> \(peerId.prefix(8))")
                            #endif
                            normalizedConversation = Conversation(
                                roomId: peerId,  // ← Use peer.userId for 1:1
                                peer: conversation.peer,
                                lastMessage: conversation.lastMessage,
                                unreadCount: conversation.unreadCount,
                                isPinned: conversation.isPinned,
                                isMuted: conversation.isMuted,
                                updatedAt: conversation.updatedAt,
                                isGroup: false,
                                groupName: nil,
                                groupAvatarUrl: nil
                            )
                        }
                        dedupedConversations.append(normalizedConversation)
                    }
                } else {
                    #if DEBUG
                    print("⚠️ Duplicate conversation filtered: \(uniqueKey)")
                    #endif
                }
            }
            
            // CRITICAL: Update conversations on MainActor with animation for smooth transitions
            withAnimation(.default) {
                conversations = dedupedConversations
            }
        } catch {
            #if DEBUG
            print("Failed to load conversations from DB: \(error)")
            #endif
        }
    }
    
    // MARK: - Handle Incoming Message (from poll or push)
    
    func handleIncomingMessage(_ message: ChatMessage) async {
        // 1. CRITICAL: Normalize roomId to peerId before saving
        // This ensures all messages for a peer use consistent roomId
        let currentUserId = await KeychainService.shared.getUserId() ?? ""
        let isOutgoing = message.senderId == currentUserId
        let peerId = isOutgoing ? message.recipientId : message.senderId

        var normalizedMessage = message

        // 🔐 E2EE: decrypt incoming body if it carries the magic
        // prefix. Outgoing copies (e.g. our own sendText updating the
        // inbox preview) hold plaintext already; only peer-authored
        // bodies need unwrapping. On decrypt failure the original
        // text is preserved unchanged so diagnostic info isn't lost.
        if !isOutgoing, let wire = normalizedMessage.text, !wire.isEmpty {
            // 🔴 AUDIT 2026-05-29 — route on groupKeyVersion FIRST, mirroring
            // handleIncomingMessages (the batch path). Group AES-GCM ciphertext
            // has NO RVNS/RVNP magic prefix, so the 1:1 E2EEMessagePipeline
            // branch below never caught it; group messages delivered via this
            // single-message path rendered/stored as raw base64 ciphertext.
            if let version = normalizedMessage.groupKeyVersion,
               let groupId = normalizedMessage.roomId, !groupId.isEmpty {
                if let plain = await GroupKeyService.shared.decrypt(
                    wire, groupId: groupId, version: version
                ) {
                    normalizedMessage.text = plain
                    await MessageEncryptionStatusStore.shared
                        .record(.sealed, for: normalizedMessage.id)
                } else {
                    normalizedMessage.text = "🔒 [Encrypted message — could not decrypt]"
                    await MessageEncryptionStatusStore.shared
                        .record(.sealedButFailed, for: normalizedMessage.id)
                }
            } else if E2EEMessagePipeline.isEncrypted(wire) {
                // 1:1 sealed body — unwrap via the 1:1 pipeline.
                let plaintext = await E2EEMessagePipeline.unwrapIncoming(
                    text: wire,
                    senderUserId: peerId,
                    messageId: normalizedMessage.id
                )
                normalizedMessage.text = plaintext
            }
        }
        // Bug 3 fix: Multi-layer group detection — don't rely solely on in-memory array.
        // 1. Check in-memory conversations (fast path)
        // 2. Fallback: check groups DB table (covers groups not yet loaded into memory)
        // 3. Fallback: check conversations DB table (covers conversations not yet loaded)
        let actualRoomId = message.roomId ?? peerId
        var isGroupMessage = self.conversations.contains(where: { $0.roomId == actualRoomId && ($0.isGroup || $0.isChannel) })
        if !isGroupMessage {
            // DB fallback: check if actualRoomId is a known group or channel
            let groupExists = (try? await DatabaseService.shared.exists(
                "SELECT 1 FROM groups WHERE id = ? LIMIT 1", params: [actualRoomId]
            )) ?? false
            let convIsGroup = (try? await DatabaseService.shared.exists(
                "SELECT 1 FROM conversations WHERE room_id = ? AND (is_group = 1 OR is_channel = 1) LIMIT 1", params: [actualRoomId]
            )) ?? false
            isGroupMessage = groupExists || convIsGroup
        }
        if !isGroupMessage && message.roomId != peerId {
            #if DEBUG
            print("🔧 [ConversationStore] Normalizing message roomId \(message.roomId?.prefix(8) ?? "nil") -> \(peerId.prefix(8))")
            #endif
            normalizedMessage.roomId = peerId
        }
        
        // 2. Insert message to DB ONLY if not already present (idempotent)
        // Exception: location messages bypass duplicate check — live location
        // updates reuse the same clientMessageId with updated GPS coordinates.
        let exists = await messageRepo.exists(clientMessageId: message.id)
        if !exists || message.type == .location {
            try? await messageRepo.upsert(normalizedMessage)
        }
        
        // 3. ALWAYS update conversation in DB (even for own sent messages)
        // This ensures inbox lastMessage/sort order stays current
        try? await conversationRepo.applyMessage(normalizedMessage, currentUserId: currentUserId)
        
        // BRIDGE: If message needs forwarding and we have mesh peers, relay via mesh
        // This enables online devices to forward server messages to offline users
        //
        // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — same fix as
        // the batch handler below: force-bridge incoming GROUP
        // messages to the mesh so offline group members can see
        // them. Without this, an offline (BLE-only) member never
        // receives messages from online senders.
        #if !targetEnvironment(simulator)
        let isFromMe_single = normalizedMessage.senderId == currentUserId
        let shouldGroupBridge_single = isGroupMessage && !isFromMe_single
        // 🟢 ROUND 73 (2026-05-24) — drop the `connectedPeers.isEmpty`
        // gate.
        //
        // USER REPORT: "az C be A toye group nemire" — C→A group
        // messages don't reach BLE-only A even when B (the online
        // member that received the WS push) is supposedly bridging.
        //
        // ROOT CAUSE: this gate refused to enqueue when B had no
        // CURRENTLY-CONNECTED BLE peers. If A was nearby but the
        // BLE session hadn't (re)established yet at the exact
        // moment the WS push arrived, the message was silently
        // dropped from the mesh path. By the time A connected to B
        // (seconds later), B had nothing to forward.
        //
        // FIX: always invoke the forwarder. `enqueueForBroadcast`
        // already has a `!hasActiveConnections` branch that parks
        // the signed envelope in `messageQueue` (capacity-bounded,
        // priority-evicting) for delivery the moment a peer
        // connects. The persisted `RelayQueueRepository` row also
        // survives BLE restarts and app backgrounding. The previous
        // gate was an optimization that became a correctness bug
        // the moment A's connectivity was intermittent.
        if normalizedMessage.needsForwarding || shouldGroupBridge_single {
            let toForward = normalizedMessage
            Task { [weak self] in
                await self?.forwardServerMessageToMesh(toForward)
            }
        }
        #endif

        // 5. P0 FIX: Use group roomId for group messages, peerId for 1:1
        // Previously always used peerId, which routed group messages to DM chats
        let effectiveRoomId = isGroupMessage ? actualRoomId : peerId
        await MainActor.run {
            NotificationCenter.default.post(
                name: MessageStore.meshMessageReceivedNotification,  // Reuse same notification
                object: nil,
                userInfo: ["roomId": effectiveRoomId]
            )
        }
        
        // 6. Reload from DB to update UI
        await loadFromDB()
        
        // 7. Background: cache media attachment for offline access
        let msgForCache = normalizedMessage
        Task.detached(priority: .utility) {
            await MediaCacheService.shared.cacheMedia(for: CacheableMessage(from: msgForCache))
        }
    }
    
    // MARK: - Server-to-Mesh Bridge
    
    /// Forward a server message to mesh peers
    /// Called when we receive a message destined for an offline user
    private func forwardServerMessageToMesh(_ message: ChatMessage) async {
        #if DEBUG
        print("🌉 [Bridge] Forwarding server message to mesh: \(message.id.prefix(8))")
        #endif

        // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — propagate
        // group context across the WS→mesh handoff.
        //
        // PROBLEM (user report 2026-05-24):
        //   "lan bridge A be C toye group dorst dare kar mikone vali
        //    C be A na" — A→C in group works, but C→A doesn't.
        //
        // ROOT CAUSES (compounding):
        //   1. `ChatMessage.toMeshEnvelope()` doesn't carry
        //      `isGroup` / `groupKeyVersion`. → A's mesh receive
        //      treats the envelope as 1:1, fails to AES-GCM-decrypt
        //      the group ciphertext.
        //   2. For group WS pushes the server sets
        //      `recipient_id = uid` (the receiving user, B) and
        //      `room_id = group_id`. `toMeshEnvelope()` copies
        //      `recipientId = message.recipientId` — i.e. B's userId
        //      — so when A receives the mesh re-broadcast it sees
        //      `envelope.recipientId == B`, NOT the group_id. The
        //      bridged-group signature exception in
        //      `MeshCryptoService.verifySignature` checks group
        //      membership of `recipientId`, fails to find the group
        //      under "B" → message REJECTED.
        //
        // FIX: when the room is a known group, override
        // `recipientId` to the group_id and stamp
        // `isGroup` + `groupKeyVersion` on the rebuilt envelope.
        // The receiver routes by group, the signature exception
        // accepts the bridge attestation, and `GroupKeyService.
        // decrypt(version:)` unseals the ciphertext.
        //
        // SECURITY: server only fans group WS pushes to actual
        // members, so the rooId here is genuinely a group we (the
        // bridger) are in. Forwarding it intact is the same trust
        // model as the existing 1:1 bridge-downlink path. The
        // ciphertext stays encrypted under the group AES-GCM key
        // throughout — we (the relay) don't decrypt to forward.
        let isGroupRoom = await isGroupConversation(roomId: message.roomId ?? "") == true

        var envelope: MeshEnvelope
        if isGroupRoom, let gid = message.roomId, !gid.isEmpty {
            // Rebuild with recipientId = group_id so receivers route
            // through the group thread and the signature-exception
            // membership check uses the correct ID.
            envelope = MeshEnvelope(
                clientMessageId: message.id,
                roomId: gid,
                senderId: message.senderId,
                senderName: message.senderName,
                recipientId: gid,
                type: message.type.index,
                text: message.text,
                timestamp: message.timestamp.timeIntervalSince1970,
                sprayCounter: message.sprayCounter,
                hopCount: 1,
                hopLimit: message.hopLimit,
                routePath: message.routePath,
                originDeviceId: message.originDeviceId,
                needsForwarding: message.needsForwarding,
                mediaUrl: message.attachmentUrl,
                thumbnailUrl: message.thumbnailUrl,
                fileName: message.fileName,
                mimeType: message.mimeType,
                fileSize: message.fileSize,
                audioDuration: message.audioDurationSeconds,
                replyToMessageId: message.replyToMessageId,
                replyToTextPreview: nil,
                replyToSenderName: message.replyToSenderName
            )
            envelope.isBridged = true
            envelope.isGroup = true
            envelope.groupKeyVersion = message.groupKeyVersion
        } else {
            envelope = message.toMeshEnvelope()
            envelope.isBridged = true
            envelope.hopCount = 1
        }

        // Broadcast to mesh
        await BLEMeshEngine.shared.enqueueForBroadcast(envelope)

        #if DEBUG
        print("✅ [Bridge] Server message forwarded to \(BLEMeshEngine.shared.connectedPeers.count) mesh peers (isGroup=\(envelope.isGroup.map(String.init) ?? "nil"), gkv=\(message.groupKeyVersion.map(String.init) ?? "nil"))")
        #endif
    }

    /// Returns true if the given roomId is a known group on this device.
    /// Used to stamp `MeshEnvelope.isGroup` on server→mesh bridge handoff
    /// so offline receivers route the message into the group thread.
    private func isGroupConversation(roomId: String) async -> Bool? {
        guard !roomId.isEmpty else { return nil }
        let inMemory = self.conversations.contains(where: { $0.roomId == roomId && ($0.isGroup || $0.isChannel) })
        if inMemory { return true }
        let groupExists = (try? await DatabaseService.shared.exists(
            "SELECT 1 FROM groups WHERE id = ? LIMIT 1", params: [roomId]
        )) ?? false
        if groupExists { return true }
        let convIsGroup = (try? await DatabaseService.shared.exists(
            "SELECT 1 FROM conversations WHERE room_id = ? AND (is_group = 1 OR is_channel = 1) LIMIT 1",
            params: [roomId]
        )) ?? false
        return convIsGroup ? true : nil
    }
    
    // MARK: - Handle Batch Messages (from poll)
    
    func handleIncomingMessages(_ messages: [ChatMessage]) async {
        let currentUserId = await KeychainService.shared.getUserId() ?? ""
        var processedRoomIds: Set<String> = []
        var newMessages: [ChatMessage] = []  // Track actually NEW messages (not duplicates)
        
        #if DEBUG
        print("🔍 [handleIncomingMessages] Processing \(messages.count) messages, currentUserId=\(currentUserId.prefix(8))")
        #endif
        
        for (index, message) in messages.enumerated() {
            // DEBUG: Log message details
            #if DEBUG
            print("📦 [\(index)] Message id=\(message.id.prefix(8))")
            print("   senderId: '\(message.senderId)' (len=\(message.senderId.count))")
            print("   recipientId: '\(message.recipientId)' (len=\(message.recipientId.count))")
            #endif
            
            // Calculate peerId FIRST (needed for notifications regardless of duplicate status)
            let isOutgoing = message.senderId == currentUserId
            let peerId = isOutgoing ? message.recipientId : message.senderId
            
            // Bug 3 fix: Multi-layer group detection (same as handleIncomingMessage)
            let actualRoomId = message.roomId ?? peerId
            var isGroupMessage = self.conversations.contains(where: { $0.roomId == actualRoomId && ($0.isGroup || $0.isChannel) })
            if !isGroupMessage {
                let groupExists = (try? await DatabaseService.shared.exists(
                    "SELECT 1 FROM groups WHERE id = ? LIMIT 1", params: [actualRoomId]
                )) ?? false
                let convIsGroup = (try? await DatabaseService.shared.exists(
                    "SELECT 1 FROM conversations WHERE room_id = ? AND (is_group = 1 OR is_channel = 1) LIMIT 1", params: [actualRoomId]
                )) ?? false
                isGroupMessage = groupExists || convIsGroup
            }
            
            // P0 FIX: Use group roomId for groups, peerId for 1:1
            // Previously always used peerId, which routed group messages to DM chats
            let effectiveRoomId = isGroupMessage ? actualRoomId : peerId
            
            #if DEBUG
            print("   isOutgoing: \(isOutgoing), peerId: '\(peerId)', isGroup: \(isGroupMessage), effectiveRoomId: '\(effectiveRoomId.prefix(8))'")
            #endif
            
            // CRITICAL FIX: ALWAYS track this room for notification
            // Even if message is duplicate, UI may need refresh (fixes Dual Polling race)
            processedRoomIds.insert(effectiveRoomId)
            
            // Idempotent insert - skip DB work for existing messages
            // Exception: location messages always pass through so live location
            // coordinate updates are persisted (same clientMessageId, new text).
            let alreadyExists = await messageRepo.exists(clientMessageId: message.id)
            if alreadyExists {
                if message.type != .location { continue }
            }
            
            // This is a NEW message (not duplicate) - add to list for banner
            newMessages.append(message)
            
            // Normalize roomId to peerId — but only for 1:1 messages
            var normalizedMessage = message
            if !isGroupMessage && message.roomId != peerId {
                #if DEBUG
                print("🔧 [ConversationStore] NORMALIZING roomId: \(message.roomId?.prefix(8) ?? "nil") → \(peerId.prefix(8))")
                #endif
                normalizedMessage.roomId = peerId
            } else {
                #if DEBUG
                print("✅ [ConversationStore] roomId already correct (or group): \(message.roomId?.prefix(8) ?? "nil")")
                #endif
            }

            // 🔴 ROUND 26 (2026-05-17) — CRITICAL UNSEAL FIX (audit Q2/Q4).
            //
            // PREVIOUSLY: WebSocket-pushed messages (from /ws/inbox)
            // landed here with `text` set to the raw sealed-Base64
            // wire — because the sender's `MessageStore.sendViaServer`
            // path runs the plaintext through `MessageContentSealer.seal`
            // before POSTing to /api/messages/send (correctly, for
            // E2EE). The server stores + re-pushes the sealed wire
            // verbatim. The receiver's pollInbox path in
            // `RealtimeEngine.processWebSocketData:843-891` unseals
            // correctly, but `ConversationStore.handleIncomingMessages`
            // (this function, also called from the live WS push path)
            // didn't. So users saw bubbles like
            // "UlZOUDEAAABNYWluX1ozb3VzIHRvb2sgYS..." (= RVNP1\0\0\0
            // followed by plaintext, base64'd) instead of the actual
            // message text — exactly the user-reported screenshot.
            //
            // FIX: mirror the unseal logic from RealtimeEngine — try
            // GroupKeyService.decrypt for group messages with a
            // version, fall back to MessageContentSealer.unseal for
            // 1:1. Empty / nil / unsealable bytes get the placeholder
            // so bubbles never render raw base64.
            if let wire = normalizedMessage.text, !wire.isEmpty {
                // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — split the
                // group / 1:1 decrypt branches BEFORE the magic-prefix
                // gate.
                //
                // PROBLEM (pre-fix): the `looksSealed` heuristic only
                // recognised the 1:1 sealer's shared base64 magic
                // prefix "UlZO" (b64 of "RVN", common to RVNS1/RVNP1/
                // RVNA1/RVNH1). Group AES-GCM
                // ciphertext from `GroupKeyService.encrypt` has NO
                // such magic — it's just base64(nonce(12) || ct ||
                // tag(16)). So a group message arriving via WS
                // (server's send_group_message push or the bridge
                // group push) had `groupKeyVersion` set but
                // `looksSealed=false` → the GroupKeyService.decrypt
                // branch was NEVER entered. The bubble rendered the
                // raw base64 ciphertext instead of the decrypted
                // text. (Probably what the user is seeing: "group
                // chat only works via mesh — once we switch to
                // internet, messages are unreadable.")
                //
                // FIX: route on `groupKeyVersion` FIRST (the server
                // contract: presence of the field means the body is
                // group ciphertext). Fall back to the 1:1 magic
                // heuristic only when groupKeyVersion is absent.
                if let version = normalizedMessage.groupKeyVersion,
                   let groupId = normalizedMessage.roomId, !groupId.isEmpty {
                    // Group ciphertext — decrypt with group key.
                    if let plain = await GroupKeyService.shared.decrypt(
                        wire, groupId: groupId, version: version
                    ) {
                        normalizedMessage.text = plain
                        await MessageEncryptionStatusStore.shared
                            .record(.sealed, for: normalizedMessage.id)
                    } else {
                        #if DEBUG
                        print("🔒 [CS] Group decrypt FAILED for mid=\(normalizedMessage.id.prefix(8)) groupId=\(groupId.prefix(8)) v\(version)")
                        #endif
                        normalizedMessage.text = "🔒 [Encrypted message — could not decrypt]"
                        await MessageEncryptionStatusStore.shared
                            .record(.sealedButFailed, for: normalizedMessage.id)
                    }
                } else if wire.hasPrefix("UlZO") {
                    // 1:1 sealed message — heuristic: every RAVEN seal
                    // magic (RVNS1 / RVNP1 / RVNA1 / RVNH1) shares the
                    // first 3 bytes "RVN", which base64-encode to the
                    // shared 4-char prefix "UlZO". Plain text doesn't.
                    // MessageContentSealer.unseal does the authoritative
                    // 8-byte magic dispatch; this is just a cheap gate.
                    let unsealResult = await MessageContentSealer.unseal(
                        encoded: wire,
                        senderUserId: normalizedMessage.senderId,
                        senderAgreementPubKey: nil,
                        msgId: normalizedMessage.id
                    )
                    #if DEBUG
                    let wirePrefix = String(wire.prefix(16))
                    let resultStr: String
                    if let r = unsealResult {
                        resultStr = "plaintext.count=\(r.plaintext.count) reason=\(r.reason)"
                    } else {
                        resultStr = "nil (unknown magic / bad base64 / too large)"
                    }
                    print("🔍 [CS.unseal] mid=\(normalizedMessage.id.prefix(8)) sender=\(normalizedMessage.senderId.prefix(8)) wirePrefix='\(wirePrefix)' wireLen=\(wire.count) → \(resultStr)")
                    #endif
                    if let result = unsealResult, !result.plaintext.isEmpty {
                        normalizedMessage.text = result.plaintext
                        switch result.reason {
                        case .noiseTransport, .atsamHybrid:
                            await MessageEncryptionStatusStore.shared
                                .record(.sealed, for: normalizedMessage.id)
                        case .explicitPlaintext:
                            await MessageEncryptionStatusStore.shared
                                .record(.plaintextExplicit, for: normalizedMessage.id)
                        case .legacy:
                            await MessageEncryptionStatusStore.shared
                                .record(.plaintextLegacy, for: normalizedMessage.id)
                        case .decryptFailed:
                            await MessageEncryptionStatusStore.shared
                                .record(.sealedButFailed, for: normalizedMessage.id)
                        case .noSenderKey:
                            break
                        }
                    } else {
                        #if DEBUG
                        print("🚨 [CS.unseal] PLACEHOLDER SET for mid=\(normalizedMessage.id.prefix(8)) — wire didn't unseal cleanly. Wire prefix='\(String(wire.prefix(32)))'")
                        #endif
                        normalizedMessage.text = "🔒 [Encrypted message — could not decrypt]"
                        await MessageEncryptionStatusStore.shared
                            .record(.sealedButFailed, for: normalizedMessage.id)
                    }
                }
            }

            try? await messageRepo.upsert(normalizedMessage)
            try? await conversationRepo.applyMessage(normalizedMessage, currentUserId: currentUserId)

            // BRIDGE: If message needs forwarding and we have mesh peers, relay via mesh
            // This enables online devices to forward server messages to offline users
            //
            // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — also fire
            // unconditionally for GROUP messages we just received from
            // the server.
            //
            // SCENARIO (user-reported 2026-05-24):
            //   "on device ke faghat be bluetooth vasle... hich
            //    kodom az payam haye group dayfat nemitone bokone"
            //   ≈ device A (BLE-only / offline) can't receive any
            //   group messages.
            //
            // Without this fix the reverse bridge — server → online
            // member (B) → mesh-broadcast → offline member (A) —
            // never fires because `needsForwarding` defaults to
            // false on server-shipped messages. Group chat needs A
            // to see what C says even when C and A can never talk
            // directly (C is online, A is offline). B is the mesh
            // bridge.
            //
            // 🛡️ SECURITY: the broadcast carries the server-
            // delivered ciphertext + group_key_version unchanged.
            // E2EE preserved — B doesn't decrypt to broadcast.
            // `enqueueForBroadcast` signs the new envelope with B's
            // own Ed25519 key (bridge attestation), so other mesh
            // peers can verify the relay's authenticity even though
            // the original sender's signature path is lossy here
            // (server WS push didn't carry it). The
            // `isBridged=true` flag in `forwardServerMessageToMesh`
            // signals receivers to trust the bridge sig instead of
            // requiring an original sender signature.
            //
            // SCOPE: limited to group messages from OTHER senders.
            // Skip:
            //   - our own messages (we already mesh-broadcast on
            //     send, no double-emit)
            //   - 1:1 messages (would create a spam loop with the
            //     direct mesh path)
            #if !targetEnvironment(simulator)
            let isFromMe = normalizedMessage.senderId == currentUserId
            let shouldGroupBridge = isGroupMessage && !isFromMe
            // 🟢 ROUND 73 (2026-05-24) — same fix as the single-
            // message handler above: drop the `connectedPeers.isEmpty`
            // gate. `enqueueForBroadcast` already parks unsendable
            // envelopes in `messageQueue` (and `RelayQueueRepository`
            // for spray-counter envelopes), so the message reaches
            // A as soon as the BLE link comes up — instead of being
            // silently lost because of a momentary disconnect at
            // the exact instant the batch arrived.
            if normalizedMessage.needsForwarding || shouldGroupBridge {
                let toForward = normalizedMessage
                Task { [weak self] in
                    await self?.forwardServerMessageToMesh(toForward)
                }
            }
            #endif
        }
        
        // Notify MessageStore for each room that had new messages
        #if DEBUG
        print("🔔 [ConversationStore] About to post notifications for \(processedRoomIds.count) rooms: \(processedRoomIds.map { $0.prefix(8) })")
        #endif
        
        for roomId in processedRoomIds {
            #if DEBUG
            print("📣 [ConversationStore] Posting notification for roomId: \(roomId.prefix(8))")
            #endif
            NotificationCenter.default.post(
                name: MessageStore.meshMessageReceivedNotification,
                object: nil,
                userInfo: ["roomId": roomId]
            )
        }
        
        // NOTE: In-app banners are NOT shown here to avoid duplicates.
        // PushNotificationService.handleForegroundPush already shows banners for push-triggered messages.
        // WebSocket messages also arrive via push, so showing banners here double notifications.
        
        if !newMessages.isEmpty {
            let cacheables = newMessages.map { CacheableMessage(from: $0) }
            Task.detached(priority: .utility) {
                await MediaCacheService.shared.cacheMediaBatch(messages: cacheables)
            }
        }
        
        // Single reload after batch
        await loadFromDB()
    }
    
    // MARK: - Actions
    
    func markAsRead(roomId: String) async {
        var lastMsgId: String? = nil
        var hadUnread = false
        
        // 1. Optimistic Update (instant UI)
        if let index = conversations.firstIndex(where: { $0.roomId == roomId }) {
            if conversations[index].unreadCount > 0 {
                hadUnread = true
            }
            conversations[index].unreadCount = 0
            lastMsgId = conversations[index].lastMessage?.id
            // 🔴 AUDIT 2026-05-29 — refresh the app-icon badge on read. Previously
            // only sortConversations() did this, so the badge stayed stale until
            // the next sort/APNs event.
            updateAppBadge()
        }
        
        // 2. Update DB locally ALWAYS to prevent stuck badges
        try? await conversationRepo.markAsRead(roomId: roomId)
        
        guard hadUnread else { return }
        
        // 3. Ghost Mode: suppress server read-receipt for RAVEN+ users
        guard !PremiumLimits.ghostModeEnabled else { return }
        
        // 4. Queue for Server Sync
        await PendingReadService.shared.enqueue(type: "message", targetId: roomId, lastItemId: lastMsgId, isAll: false)
    }
    
    func togglePin(roomId: String) async {
        if let index = conversations.firstIndex(where: { $0.roomId == roomId }) {
            conversations[index].isPinned.toggle()
            try? await conversationRepo.togglePin(roomId: roomId)
            withAnimation {
                sortConversations()
            }
        }
    }
    
    func toggleMute(roomId: String) async {
        guard let index = conversations.firstIndex(where: { $0.roomId == roomId }) else { return }

        let newMutedState = !conversations[index].isMuted
        let isGroup = conversations[index].isGroup
        let peerId = conversations[index].peer.userId

        // 🔴 ROUND 26 — unified user-action telemetry (haptic + bg server log).
        UserActionTelemetry.shared.record(
            newMutedState ? .chatMute : .chatUnmute,
            targetId: roomId,
            targetType: isGroup ? .group : .conversation
        )

        conversations[index].isMuted = newMutedState
        try? await conversationRepo.toggleMute(roomId: roomId)
        
        if isGroup {
            // For groups: use group-specific mute settings API
            let settings = MuteSettings(muteUntil: newMutedState ? .distantFuture : nil, mentionsOnly: false)
            Task { await GroupService.shared.setMuteSettings(groupId: roomId, settings: settings) }
        } else {
            // For 1:1 chats: sync to server
            guard NetworkMonitor.shared.isOnline else { return }
            struct MuteRequest: Codable {
                let peer_id: String
                let muted: Bool
            }
            _ = try? await NetworkService.shared.post(
                path: "/api/messages/conversations/mute",
                body: MuteRequest(peer_id: peerId, muted: newMutedState)
            ) as EmptyResponse
        }
        #if DEBUG
        print("🔕 [ConversationStore] Mute synced: \(newMutedState) isGroup=\(isGroup)")
        #endif
    }
    
    /// Telegram-style archive: hide a chat from the main inbox into
    /// the "Archived" folder. Optimistic — local SQLite is updated
    /// first, server is fire-and-forget for cross-device sync. Idempotent.
    ///
    /// 🟦 ROUND 49 (2026-05-17) — full archive plumbing.
    ///
    /// Two bugs fixed here:
    ///   1. For GROUPS, `peer.userId` is the creator's user_id (set by
    ///      `createGroupConversation`), NOT the group_id. The previous
    ///      server-sync call sent `peer_id = creator_user_id`, which
    ///      the server can't use to identify the thread (and the
    ///      server endpoint was a stub anyway). Switched to `room_id`
    ///      which is the canonical thread identifier — group_id for
    ///      groups, peer_user_id for 1:1.
    ///   2. The previous payload field was `peer_id` (snake_case) on
    ///      a Swift struct sent via JSONEncoder with no key strategy,
    ///      so the wire field was literally `peer_id`. The server
    ///      now expects `room_id` to match the new endpoint shape
    ///      (handler upserts a `UserConversationState` row keyed
    ///      by `(user_id, room_id)`).
    func toggleArchive(roomId: String) async {
        guard let index = conversations.firstIndex(where: { $0.roomId == roomId }) else { return }

        let newArchivedState = !conversations[index].isArchived

        // Optimistic local update.
        if newArchivedState {
            try? await conversationRepo.archive(roomId: roomId)
        } else {
            try? await conversationRepo.unarchive(roomId: roomId)
        }

        // Reload from DB so the in-memory list reflects the new
        // archived/unarchived split (the main filter excludes archived).
        await loadFromDB()

        // Sync to server (best-effort, non-blocking) for cross-device
        // persistence. Local archive state remains the source of truth
        // for this device — server sync is "send my preference up"
        // and "let other devices learn it on their next /conversations
        // poll".
        if NetworkMonitor.shared.isOnline {
            struct ArchiveRequest: Codable {
                let roomId: String
                let archived: Bool
            }
            do {
                _ = try await NetworkService.shared.post(
                    path: "/api/messages/conversations/archive",
                    body: ArchiveRequest(roomId: roomId, archived: newArchivedState)
                ) as EmptyResponse
                #if DEBUG
                print("📥 [ConversationStore] Archive synced to server: \(newArchivedState) for \(roomId.prefix(8))")
                #endif
            } catch {
                // Non-fatal — local is already archived/unarchived.
                // Server sync will retry on next archive toggle.
                #if DEBUG
                print("⚠️ [ConversationStore] Archive server sync failed (local state already updated): \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Snapshot of the current archived bucket. Re-queried each
    /// time `ArchivedConversationsView` opens. Cheap (indexed lookup).
    func loadArchivedConversations() async -> [Conversation] {
        return (try? await conversationRepo.getArchivedSorted()) ?? []
    }

    /// How many chats currently live in the archive — drives the
    /// folder pill at the top of the inbox.
    func archivedCount() async -> Int {
        return (try? await conversationRepo.archivedCount()) ?? 0
    }

    func deleteConversation(roomId: String) async {
        let conversation = conversations.first { $0.roomId == roomId }
        let peerId = conversation?.peer.userId
        let isGroup = conversation?.isGroup ?? false
        
        // Remove from local list (optimistic)
        conversations.removeAll { $0.roomId == roomId }
        
        if isGroup {
            // For groups: leave on server FIRST, then clean up locally
            if NetworkMonitor.shared.isOnline {
                do {
                    try await GroupService.shared.leaveGroup(groupId: roomId)
                    // Server confirmed — safe to delete local DB entry
                    try? await conversationRepo.delete(roomId: roomId)
                } catch {
                    // Server rejected — rollback optimistic delete
                    #if DEBUG
                    print("❌ [ConversationStore] leaveGroup failed, rolling back: \(error)")
                    #endif
                    if let conversation = conversation {
                        conversations.append(conversation)
                        sortConversations()
                    } else {
                        // Conversation wasn't in memory — reload from DB
                        await loadFromDB()
                    }
                    return
                }
            } else {
                // Offline: just delete locally, will re-sync on next fetch
                try? await conversationRepo.delete(roomId: roomId)
            }
        } else {
            // For 1:1 chats: delete from DB first, then sync to server
            try? await conversationRepo.delete(roomId: roomId)
            if let peerId = peerId, NetworkMonitor.shared.isOnline {
                _ = try? await NetworkService.shared.post(
                    path: "/api/messages/conversations/delete",
                    body: ["peer_id": peerId]
                ) as EmptyResponse
            }
        }
        
        #if DEBUG
        print("🗑️ [ConversationStore] Deleted conversation: \(roomId.prefix(8)) isGroup=\(isGroup)")
        #endif
    }
    
    /// Mark all conversations as read
    func markAllAsRead() async {
        let unreadRoomIds = conversations.filter { $0.unreadCount > 0 }.map { $0.roomId }
        
        // 1. Optimistic Update (local copy → 1 UI refresh)
        var updated = conversations
        for index in updated.indices {
            updated[index].unreadCount = 0
        }
        conversations = updated
        // 🔴 AUDIT 2026-05-29 — keep the app-icon badge in sync on mark-all-read.
        updateAppBadge()
        
        // 2. Update Local DB
        for roomId in unreadRoomIds {
            try? await conversationRepo.markAsRead(roomId: roomId)
        }
        
        // 3. Queue for Server Sync
        if !PremiumLimits.ghostModeEnabled && !unreadRoomIds.isEmpty {
            await PendingReadService.shared.enqueue(type: "message", targetId: nil, isAll: true)
        }
    }
    
    // MARK: - Sorting
    
    private func sortConversations() {
        conversations.sort { a, b in
            // Pinned first
            if a.isPinned != b.isPinned {
                return a.isPinned
            }
            // Then by last message timestamp (newest first)
            let aTime = a.lastMessage?.timestamp ?? a.updatedAt
            let bTime = b.lastMessage?.timestamp ?? b.updatedAt
            return aTime > bTime
        }
        updateAppBadge()
    }

    /// Push the total unread count to the iOS app icon badge so it
    /// stays in sync as the user reads / mutes / opens new conversations.
    /// Without this, the badge only updates when an APNs push arrives,
    /// which means it can stay stale for hours after the user actually
    /// catches up. iOS 16+ API; we just early-return on older builds
    /// (the project's deployment target is well above that).
    private func updateAppBadge() {
        let total = totalUnreadCount
        let center = UNUserNotificationCenter.current()
        center.setBadgeCount(total) { _ in
            // Best-effort — we don't surface badge errors to the user.
        }
    }
    
    // MARK: - Stats
    
    var totalUnreadCount: Int {
        conversations.filter { !$0.isMuted }.reduce(0) { $0 + $1.unreadCount }
    }
}

// MARK: - Empty Response
struct EmptyResponse: Decodable {}
