import Foundation
import Combine
import UIKit
import SwiftUI
import os

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "MessageStore")

// MARK: - Message Store (Observe messages by roomId from DB)
@MainActor
@Observable
class MessageStore {
    /// Cached decoder used for hydrating per-row JSON payloads
    /// (mentions, etc). 🟡 BUG FIX (2026-05-10): was previously
    /// allocated fresh per row in `parseMessage`, costing measurable
    /// time on each scroll-paginate.
    static let cachedJSONDecoder = JSONDecoder()

    var messages: [ChatMessage] = []
    var isLoading = false
    var isSending = false
    var isLoadingMore = false  // 🔴 FIX 3: Guard for pagination
    var error: Error?
    
    /// Dynamic limit for DB query — increases as user scrolls to top (pagination)
    var messageLimit: Int = 100
    private(set) var hasOlderMessages: Bool = true  // Assume yes until proven otherwise
    
    let roomId: String  // Made accessible for debug logging
    let isGroup: Bool   // True for group chats, false for 1:1
    private let messageRepo = MessageRepository.shared
    private var lastFetchedTimestamp: String?
    private var pollTimer: Timer?
    @ObservationIgnored private var meshMessageObserver: NSObjectProtocol?
    @ObservationIgnored private var meshACKObserver: NSObjectProtocol?
    @ObservationIgnored private var mediaDownloadObserver: NSObjectProtocol?
    @ObservationIgnored private var editRemoteObserver: NSObjectProtocol?
    private var ackedMessageIds: Set<String> = []  // Prevent re-sending ACKs within session
    
    // Notification for mesh message received
    static let meshMessageReceivedNotification = Notification.Name("MeshMessageReceived")
    
    init(roomId: String, isGroup: Bool = false) {
        self.roomId = roomId
        self.isGroup = isGroup
        // Bug 4 fix: Observers moved to setupObservers() — called from ChatView .task
        // This prevents zombie observers from SwiftUI re-evaluating State(initialValue:)
    }
    
    // MARK: - Observer Lifecycle (Bug 4 fix)
    
    /// Register mesh message observers — call from ChatView .task (NOT init)
    func setupObservers() {
        // Guard: only register once
        guard meshMessageObserver == nil else { return }
        
        meshMessageObserver = NotificationCenter.default.addObserver(
            forName: Self.meshMessageReceivedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            let messageRoomId = notification.userInfo?["roomId"] as? String ?? "nil"
            if messageRoomId == self.roomId {
                Task {
                    await self.loadFromDB()
                }
            }
        }
        
        meshACKObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("MeshACKReceived"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            let messageId = notification.userInfo?["messageId"] as? String
            let statusRaw = notification.userInfo?["status"] as? String
            
            if let messageId = messageId, let statusRaw = statusRaw, let status = MessageStatus(rawValue: statusRaw) {
                Task { @MainActor in
                    if let idx = self.messages.firstIndex(where: { $0.id == messageId }) {
                        self.messages[idx].status = status
                    }
                }
            }
        }
        
        mediaDownloadObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("MediaDownloadCompleted"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self, let msgId = notification.userInfo?["messageId"] as? String else { return }

            Task { @MainActor in
                if self.messages.contains(where: { $0.id == msgId }) {
                    await self.loadFromDB()
                }
            }
        }

        // 🆕 Remote edit (peer edited a message they sent us). RealtimeEngine
        // posts this when /ws/inbox delivers a `message_edited` event; we
        // patch the bubble in place instead of refetching the whole thread.
        editRemoteObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("MessageEditedRemote"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let info = note.userInfo,
                  let messageId = info["messageId"] as? String,
                  let content = info["content"] as? String else { return }
            let editedAt = info["editedAt"] as? Date ?? Date()
            Task { @MainActor in
                if let idx = self.messages.firstIndex(where: { $0.serverId == messageId || $0.id == messageId }) {
                    self.messages[idx].text = content
                    self.messages[idx].editedAt = editedAt
                    let clientId = self.messages[idx].id
                    try? await self.messageRepo.updateText(clientMessageId: clientId, newText: content)
                }
            }
        }
    }
    
    /// Remove mesh message observers — call from ChatView .onDisappear
    func removeObservers() {
        if let obs = meshMessageObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = meshACKObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = mediaDownloadObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = editRemoteObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        meshMessageObserver = nil
        meshACKObserver = nil
        mediaDownloadObserver = nil
        editRemoteObserver = nil
    }
    
    deinit {
        if let observer = meshMessageObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = meshACKObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = mediaDownloadObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Load from DB (Primary source)
    
    func loadFromDB() async {
        do {
            // 🔴 v1.8 — sweep expired disappearing messages from the
            // on-device cache before loading so they never render.
            try? await messageRepo.purgeExpiredMessages()
            let rows = try await messageRepo.getMessages(roomId: roomId, limit: messageLimit)
            
            // 🚀 Parse + sort in background thread to avoid blocking UI
            let loadedMessages = await Task.detached(priority: .userInitiated) {
                let parsed = rows.compactMap { self.parseMessage(from: $0) }
                return parsed.sorted {
                    if $0.timestamp == $1.timestamp {
                        return $0.id < $1.id  // Deterministic tie-breaker
                    }
                    return $0.timestamp < $1.timestamp
                }
            }.value
            
            // 🚀 UI update on main thread
            await MainActor.run {
                // Skip update if nothing changed (prevents SwiftUI re-diff on every poll)
                let oldIds = self.messages.map { $0.id }
                let newIds = loadedMessages.map { $0.id }
                let oldStatuses = self.messages.map { $0.status.rawValue }
                let newStatuses = loadedMessages.map { $0.status.rawValue }
                let oldSyncs = self.messages.map { $0.syncState.rawValue }
                let newSyncs = loadedMessages.map { $0.syncState.rawValue }
                let oldPaths = self.messages.map { $0.localPath ?? "" }
                let newPaths = loadedMessages.map { $0.localPath ?? "" }
                let oldUrls = self.messages.map { $0.attachmentUrl ?? "" }
                let newUrls = loadedMessages.map { $0.attachmentUrl ?? "" }
                
                let oldTexts = self.messages.map { $0.text ?? "" }
                let newTexts = loadedMessages.map { $0.text ?? "" }
                
                if oldIds == newIds && oldStatuses == newStatuses && oldSyncs == newSyncs && oldPaths == newPaths && oldUrls == newUrls && oldTexts == newTexts {
                    // Still update hasOlderMessages in case limit changed
                    self.hasOlderMessages = loadedMessages.count >= self.messageLimit
                    return  // No change — skip UI update entirely
                }
                
                // ⚡️ Smart animation: only animate for ≤3 new messages (not initial load of 50+)
                let isInitialLoadOrPagination = oldIds.isEmpty || abs(newIds.count - oldIds.count) > 3
                
                if isInitialLoadOrPagination {
                    self.messages = loadedMessages
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        self.messages = loadedMessages
                    }
                }
                // Bug 8: Track if there might be older messages (for load-more UI)
                self.hasOlderMessages = loadedMessages.count >= self.messageLimit
            }
        } catch {
            #if DEBUG
            print("❌ [MessageStore] Failed to load from DB: \(error)")
            #endif
        }
    }
    
    /// Bug 8: Load older messages when user scrolls to top (pagination)
    func loadMore() async {
        // 🔴 FIX 3: Prevent dozens of concurrent loadMore() calls from ProgressView.onAppear
        guard !isLoadingMore else { return }
        isLoadingMore = true
        
        messageLimit += 50
        await loadFromDB()
        
        // Brief pause so UI has time to render before allowing another load
        try? await Task.sleep(nanoseconds: 300_000_000)
        isLoadingMore = false
    }
    
    // sendReadACKsForMeshMessages() removed — mesh read ACKs are now sent
    // inside markAllAsRead() on a background thread to avoid blocking UI.
    
    // MARK: - Repair Voice Message URL (On-demand Fetch)
    
    /// Fetch the audio URL for a voice message that's missing its remote_url in the DB.
    /// Returns the resolved URL string if found, nil otherwise.
    func repairVoiceMessageUrl(messageId: String, serverId: String?) async -> String? {
        guard NetworkMonitor.shared.isOnline else { return nil }
        
        let targetId = serverId ?? messageId
        #if DEBUG
        print("🔧 [MessageStore] repairVoiceMessageUrl for \(targetId.prefix(8))...")
        #endif
        
        do {
            // Try fetching the message from the conversation endpoint (force full, no since filter)
            let queryItems = [URLQueryItem(name: "limit", value: "50")]
            
            if isGroup {
                let groupMessages: [GroupMessageResponse] = try await NetworkService.shared.get(
                    path: "/api/groups/\(roomId)/messages",
                    queryItems: queryItems
                )
                if let gm = groupMessages.first(where: { $0.id == targetId }) {
                    let url = gm.audioUrl ?? gm.mediaUrl ?? gm.fileUrl ?? gm.imageUrl ?? gm.voiceUrl
                    if let url = url {
                        try? await messageRepo.backfillRemoteUrl(serverId: targetId, remoteUrl: url, audioDuration: gm.audioDurationSeconds ?? gm.audioDuration)
                        #if DEBUG
                        print("✅ [MessageStore] Repaired voice URL: \(url.prefix(60))")
                        #endif
                        await loadFromDB()
                        return url
                    }
                }
            } else {
                let apiMessages: MessageFetchResponse = try await NetworkService.shared.get(
                    path: "/api/messages/conversation/\(roomId)",
                    queryItems: queryItems
                )
                if let msg = apiMessages.first(where: { $0.id == targetId }) {
                    let url = msg.audioUrl ?? msg.mediaUrl ?? msg.fileUrl ?? msg.imageUrl ?? msg.voiceUrl
                    if let url = url {
                        try? await messageRepo.backfillRemoteUrl(serverId: targetId, remoteUrl: url, audioDuration: msg.audioDurationSeconds ?? msg.audioDuration)
                        #if DEBUG
                        print("✅ [MessageStore] Repaired voice URL: \(url.prefix(60))")
                        #endif
                        await loadFromDB()
                        return url
                    } else {
                        #if DEBUG
                        // SECURITY (round 11): don't dump content bytes to console.
                        print("⚠️ [MessageStore] Server returned voice msg but ALL url fields are nil. content size: \(msg.content?.count ?? 0)b")
                        #endif
                    }
                } else {
                    #if DEBUG
                    print("⚠️ [MessageStore] Voice msg \(targetId.prefix(8)) not found in conversation response")
                    #endif
                }
            }
        } catch {
            #if DEBUG
            print("❌ [MessageStore] repairVoiceMessageUrl failed: \(error)")
            #endif
        }
        
        return nil
    }
    
    // MARK: - Fetch from Server
    
    func fetchMessages(forceFull: Bool = false) async {
        // Offline-first: Skip server if no network
        guard NetworkMonitor.shared.isOnline else {
            // offline - load from DB only
            await loadFromDB()
            return
        }
        
        isLoading = true
        error = nil
        
        do {
            var queryItems = [URLQueryItem(name: "limit", value: "50")]
            
            if !forceFull, let since = lastFetchedTimestamp {
                queryItems.append(URLQueryItem(name: "since", value: since))
            }
            
            if isGroup {
                // Group chat: fetch from group endpoint
                #if DEBUG
                print("🔄 [MessageStore.fetchMessages] Polling /api/groups/\(roomId.prefix(8))/messages...")
                #endif
                
                let groupMessages: [GroupMessageResponse] = try await NetworkService.shared.get(
                    path: "/api/groups/\(roomId)/messages",
                    queryItems: queryItems
                )
                
                #if DEBUG
                print("📥 [MessageStore.fetchMessages] Received \(groupMessages.count) group messages from server")
                #endif
                
                // Update timestamp
                if let latest = groupMessages.last?.timestamp {
                    lastFetchedTimestamp = PerformanceConstants.iso8601.string(from: latest)
                }
                
                // Convert and upsert to DB — BATCH OPTIMIZED
                // Step 1: Check all server_ids in one query (instead of N queries)
                let allServerIds = groupMessages.map { $0.id }
                let existingIds = await messageRepo.batchExistsByServerIds(allServerIds)
                
                // Step 2: Process backfills for existing messages, collect new ones
                var newMessages: [ChatMessage] = []
                for gm in groupMessages {
                    if existingIds.contains(gm.id) {
                        // Backfill remote_url if existing message is missing it
                        if let incomingUrl = gm.audioUrl ?? gm.mediaUrl ?? gm.fileUrl ?? gm.imageUrl ?? gm.voiceUrl {
                            try? await messageRepo.backfillRemoteUrl(
                                serverId: gm.id,
                                remoteUrl: incomingUrl,
                                audioDuration: gm.audioDurationSeconds ?? gm.audioDuration
                            )
                        }
                        continue
                    }
                    
                    // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — decrypt
                    // the AES-GCM group ciphertext BEFORE persisting.
                    // Pre-fix the row was stored with raw base64
                    // ciphertext in `text` and the bubble rendered
                    // gibberish on scrollback. Use the same
                    // GroupKeyService.decrypt path the WS handler
                    // uses; placeholder when key isn't available.
                    let displayedText: String
                    if let v = gm.groupKeyVersion,
                       !gm.content.isEmpty,
                       let plain = await GroupKeyService.shared.decrypt(
                            gm.content, groupId: roomId, version: v
                       ) {
                        displayedText = plain
                    } else if gm.groupKeyVersion != nil {
                        // Server flagged this as group-sealed but
                        // we couldn't decrypt — placeholder.
                        displayedText = "🔒 [Encrypted message — could not decrypt]"
                    } else {
                        displayedText = gm.content
                    }

                    let chatMessage = ChatMessage(
                        id: gm.id,
                        serverId: gm.id,
                        roomId: roomId,
                        senderId: gm.senderId,
                        senderName: gm.senderName,
                        recipientId: roomId,  // For groups, use roomId
                        text: displayedText,
                        timestamp: gm.timestamp,
                        type: MessageType.from(name: gm.messageType ?? "text"),
                        status: .sent,
                        deliveryAuthority: .server,
                        createdAt: gm.timestamp,
                        deliveredAt: gm.timestamp,
                        readAt: nil,
                        hopCount: 0,
                        routePath: [],
                        sprayCounter: PremiumLimits.meshSprayBudget,
                        hopLimit: PremiumLimits.meshHopLimit,
                        originDeviceId: DeviceIdentityService.shared.fingerprint ?? "",
                        needsForwarding: {
                            let gmType = MessageType.from(name: gm.messageType ?? "text")
                            return gmType == .text || gmType == .location || gmType == .system
                        }(),
                        attachmentUrl: {
                            // Coalesce all URL fields
                            if let url = gm.audioUrl ?? gm.mediaUrl ?? gm.fileUrl ?? gm.imageUrl ?? gm.voiceUrl {
                                return url
                            }
                            // Voice messages: server may send audio URL in content field
                            let gmType = MessageType.from(name: gm.messageType ?? "text")
                            if gmType == .voice, !gm.content.isEmpty,
                               (gm.content.hasPrefix("http") || gm.content.hasPrefix("/uploads/") || gm.content.hasPrefix("/api/uploads/")) {
                                return gm.content
                            }
                            return nil
                        }(),
                        thumbnailUrl: nil,
                        fileName: gm.fileName,
                        mimeType: gm.mimeType,
                        fileSize: gm.fileSize,
                        audioDurationSeconds: gm.audioDurationSeconds ?? gm.audioDuration,
                        syncState: .synced,
                        localPath: nil,
                        uploadProgress: nil,
                        lastError: nil,
                        replyToMessageId: gm.replyToMessageId,
                        replyToTextPreview: gm.replyToTextPreview,
                        replyToSenderName: gm.replyToSenderName,
                        replyToType: gm.replyToType != nil ? MessageType.from(name: gm.replyToType!) : nil,
                        sendMode: nil,
                        scheduledAtUtc: nil
                    )
                    var withPoll = chatMessage
                    withPoll.pollId = gm.pollId
                    newMessages.append(withPoll)
                }
                
                // Step 3: Batch upsert all new messages in single transaction
                if !newMessages.isEmpty {
                    try? await messageRepo.upsertBatch(newMessages)
                }
                
            } else {
                // 1:1 chat: use regular endpoint
                #if DEBUG
                print("🔄 [MessageStore.fetchMessages] Polling /api/messages/conversation/\(roomId.prefix(8))...")
                #endif
                
                let apiMessages: MessageFetchResponse = try await NetworkService.shared.get(
                    path: "/api/messages/conversation/\(roomId)",
                    queryItems: queryItems
                )
                
                #if DEBUG
                print("📥 [MessageStore.fetchMessages] Received \(apiMessages.count) messages from server")
                #endif
                
                // Update timestamp
                if let latest = apiMessages.first?.timestamp {
                    lastFetchedTimestamp = PerformanceConstants.iso8601.string(from: latest)
                }
                
                // Convert and upsert to DB — BATCH OPTIMIZED
                let myId = await KeychainService.shared.getUserId() ?? ""
                
                // Step 1: Check all server_ids in one query (instead of N queries)
                let allServerIds = apiMessages.map { $0.id }
                let existingIds = await messageRepo.batchExistsByServerIds(allServerIds)
                
                // Step 2: Filter and process messages
                var newMessages: [ChatMessage] = []
                for apiMessage in apiMessages {
                    // Fast path: already exists by server_id (most common case)
                    if existingIds.contains(apiMessage.id) {
                        // Backfill remote_url if existing message is missing it
                        if let incomingUrl = apiMessage.audioUrl ?? apiMessage.mediaUrl ?? apiMessage.fileUrl ?? apiMessage.imageUrl ?? apiMessage.voiceUrl {
                            try? await messageRepo.backfillRemoteUrl(
                                serverId: apiMessage.id,
                                remoteUrl: incomingUrl,
                                audioDuration: apiMessage.audioDurationSeconds
                            )
                        }
                        continue
                    }
                    
                    // Check by client_message_id (race condition: sent but no server_id yet)
                    let existsByClientId = await messageRepo.exists(clientMessageId: apiMessage.id)
                    if existsByClientId {
                        try? await messageRepo.updateServerId(clientMessageId: apiMessage.id, serverId: apiMessage.id)
                        if let incomingUrl = apiMessage.audioUrl ?? apiMessage.mediaUrl ?? apiMessage.fileUrl ?? apiMessage.imageUrl ?? apiMessage.voiceUrl {
                            try? await messageRepo.backfillRemoteUrl(
                                serverId: apiMessage.id,
                                remoteUrl: incomingUrl,
                                audioDuration: apiMessage.audioDurationSeconds
                            )
                        }
                        continue
                    }
                    
                    // Prevent duplicate voice/image/file messages during send
                    if apiMessage.senderId == myId {
                        let msgType = apiMessage.messageType ?? "text"
                        if msgType == "voice" || msgType == "image" || msgType == "file" {
                            if let pendingClientId = await messageRepo.findPendingAttachmentClientId(
                                type: msgType,
                                roomId: roomId,
                                senderId: myId
                            ) {
                                try? await messageRepo.updatePendingAttachmentServerId(
                                    clientMessageId: pendingClientId,
                                    serverId: apiMessage.id,
                                    remoteUrl: apiMessage.audioUrl ?? apiMessage.mediaUrl ?? apiMessage.fileUrl ?? apiMessage.imageUrl ?? apiMessage.voiceUrl
                                )
                                continue
                            }
                        }
                        // Prevent duplicate text messages during send
                        else if msgType == "text", let content = apiMessage.content {
                            if let pendingClientId = await messageRepo.findPendingTextClientId(
                                content: content,
                                roomId: roomId,
                                senderId: myId
                            ) {
                                try? await messageRepo.updatePendingAttachmentServerId(
                                    clientMessageId: pendingClientId,
                                    serverId: apiMessage.id,
                                    remoteUrl: nil
                                )
                                continue
                            }
                        }
                    }
                    
                    // 🔴 SECURITY FIX (2026-05-16 — round 11): unseal
                    // the server-shipped `content` before storing it
                    // as `text`. Pre-round-10 messages have no magic
                    // header — those land via `.legacy` and are
                    // surfaced unchanged (we can't retroactively
                    // encrypt). Round-10+ messages arrive as a
                    // Base64 envelope and we either decrypt with the
                    // Noise session or fall back with an explicit
                    // "not E2EE" marker that the bubble can render.
                    var converted = apiMessage.toChatMessage(roomId: roomId)
                    if let raw = apiMessage.content, !raw.isEmpty {
                        // Round 12 (2026-05-16): pass `senderUserId`
                        // through so the unsealer can lazy-fetch +
                        // verify the sender's prekey bundle when the
                        // directory doesn't have one cached yet. This
                        // closes the "first received DM is always
                        // RVNP1" gap.
                        let unsealedOpt = await MessageContentSealer.unseal(
                            encoded: raw,
                            senderUserId: apiMessage.senderId,
                            senderAgreementPubKey: nil,
                            msgId: apiMessage.id
                        )
                        #if DEBUG
                        let rawPrefix = String(raw.prefix(20))
                        if let u = unsealedOpt {
                            print("🔍 [MS.unseal] mid=\(apiMessage.id.prefix(8)) sender=\(apiMessage.senderId.prefix(8)) rawPrefix='\(rawPrefix)' rawLen=\(raw.count) → plaintext.count=\(u.plaintext.count) reason=\(u.reason) plaintextPrefix='\(u.plaintext.prefix(20))'")
                        } else {
                            print("🔍 [MS.unseal] mid=\(apiMessage.id.prefix(8)) sender=\(apiMessage.senderId.prefix(8)) rawPrefix='\(rawPrefix)' rawLen=\(raw.count) → nil")
                        }
                        #endif
                        if let unsealed = unsealedOpt {
                            // 🔴 ROUND 71 phase 3 follow-up (2026-05-24)
                            //   — placeholder when decrypt failed/no
                            //   sender key. Pre-fix the code assigned
                            //   `unsealed.plaintext` unconditionally;
                            //   for `.decryptFailed` / `.noSenderKey`
                            //   the unsealer returns plaintext=""
                            //   (no body), so the bubble rendered
                            //   EMPTY. This was the "bubble khali az
                            //   A be C" symptom — bridge delivered
                            //   the sealed bytes but the receiver
                            //   couldn't decrypt because they had no
                            //   Noise session with the offline
                            //   sender. Now: surface a clear
                            //   placeholder so the user sees
                            //   "🔒 Sealed message (no key)" instead
                            //   of an empty bubble; the lock badge
                            //   still flags `sealedButFailed`.
                            let placeholderForFailedDecrypt: String?
                            switch unsealed.reason {
                            case .decryptFailed:
                                placeholderForFailedDecrypt = "🔒 Sealed message — couldn't decrypt"
                            case .noSenderKey:
                                placeholderForFailedDecrypt = "🔒 Sealed message — sender key unknown"
                            default:
                                placeholderForFailedDecrypt = nil
                            }
                            if let placeholder = placeholderForFailedDecrypt,
                               unsealed.plaintext.isEmpty {
                                converted.text = placeholder
                            } else {
                                converted.text = unsealed.plaintext
                            }

                            // 2026-05-16 — round 12: feed the protocol-
                            // capability store so the ATSAM mismatch
                            // banner can decide whether to surface for
                            // this peer, AND drop a per-message
                            // verdict into the encryption-status
                            // side-table so each bubble can render its
                            // own lock badge.
                            let peerForVerdict = apiMessage.senderId
                            switch unsealed.reason {
                            case .noiseTransport, .atsamHybrid:
                                await PeerProtocolCapabilityStore.shared
                                    .record(.modernATSAM, for: peerForVerdict)
                                await MessageEncryptionStatusStore.shared
                                    .record(.sealed, for: apiMessage.id)
                            case .explicitPlaintext:
                                // Sender's app is round-10+ and
                                // explicitly admitted no session —
                                // the less-alarming "Not E2EE"
                                // badge. Peer still counts as
                                // downlevel for the chat banner.
                                await PeerProtocolCapabilityStore.shared
                                    .record(.legacyClient, for: peerForVerdict)
                                await MessageEncryptionStatusStore.shared
                                    .record(.plaintextExplicit, for: apiMessage.id)
                            case .legacy:
                                // No magic header at all → sender
                                // is on an older client that never
                                // even attempted the seal. Strongest
                                // warning.
                                await PeerProtocolCapabilityStore.shared
                                    .record(.legacyClient, for: peerForVerdict)
                                await MessageEncryptionStatusStore.shared
                                    .record(.plaintextLegacy, for: apiMessage.id)
                            case .decryptFailed:
                                // We have a sealed envelope but the
                                // session couldn't decrypt — likely
                                // peer rotated keys. Tag the bubble
                                // as `sealedButFailed` so the user
                                // can see the message exists but is
                                // currently unreadable.
                                await MessageEncryptionStatusStore.shared
                                    .record(.sealedButFailed, for: apiMessage.id)
                            case .noSenderKey:
                                // We never got the sender's pubkey —
                                // can't classify cleanly. Leave the
                                // badge unset.
                                break
                            }
                        } else {
                            // 🔴 ROUND 26 (2026-05-17) — empty/raw-base64-
                            //   bubble bug fix. PREVIOUSLY: when
                            //   `MessageContentSealer.unseal` returned
                            //   nil (sender shipped sealed bytes but
                            //   receiver has no Noise session OR
                            //   sender's app version is unknown), we
                            //   fell through WITHOUT touching
                            //   `converted.text`. The default value
                            //   was `apiMessage.content` — i.e., the
                            //   RAW BASE64 WIRE. User saw bubbles like
                            //   "UlZOUDEAAABNYWluX1ozb3VzIHRvb2sgYS..."
                            //   instead of the actual text. Same
                            //   pattern as the mesh-receive bug fixed
                            //   yesterday.
                            //   FIX: explicit placeholder. Never show
                            //   raw wire bytes in a bubble.
                            #if DEBUG
                            let rawPrefix = String((apiMessage.content ?? "").prefix(32))
                            print("🚨 [MS.unsealNil] PLACEHOLDER SET for mid=\(apiMessage.id.prefix(8)) — unseal returned nil. rawContent prefix='\(rawPrefix)'")
                            #endif
                            converted.text = "🔒 [Encrypted message — could not decrypt]"
                            await MessageEncryptionStatusStore.shared
                                .record(.sealedButFailed, for: apiMessage.id)
                        }
                    }
                    // 🔴 ROUND 26 — also defend against the BASE64-but-
                    //   sealer-succeeded-with-empty edge case: if
                    //   `text` ended up empty/nil/raw-base64-looking
                    //   after all paths, replace with placeholder.
                    let isBase64Looking = (converted.text ?? "").hasPrefix("UlZO") ||
                                          (converted.text ?? "").hasPrefix("UlZT")
                    if (converted.text ?? "").isEmpty || isBase64Looking {
                        #if DEBUG
                        print("🚨 [MS.postCheck] PLACEHOLDER SET for mid=\(apiMessage.id.prefix(8)) — text='\((converted.text ?? "").prefix(32))' isEmpty=\((converted.text ?? "").isEmpty) isBase64=\(isBase64Looking)")
                        #endif
                        converted.text = "🔒 [Encrypted message — could not decrypt]"
                    }
                    newMessages.append(converted)
                }
                
                // Step 3: Batch upsert all new messages in single transaction
                if !newMessages.isEmpty {
                    try? await messageRepo.upsertBatch(newMessages)
                }
            }
            
            // Reload from DB
            await loadFromDB()
            
            // Background: cache media attachments for offline access
            let messagesToCache = self.messages
            Task.detached(priority: .utility) {
                let cacheables = messagesToCache.map { CacheableMessage(from: $0) }
                await MediaCacheService.shared.cacheMediaBatch(messages: cacheables)
            }
            
            isLoading = false
            
        } catch {
            self.error = error
            isLoading = false
            #if DEBUG
            print("❌ [MessageStore] fetchMessages error: \(error)")
            #endif
            
            // Still load from DB (offline-first)
            await loadFromDB()
        }
    }
    
    // MARK: - Send Text Message
    
    /// Schedule a text message for delivery at `scheduledAt`. The server
    /// stores it with `send_mode = "scheduled"` and the background
    /// worker flips it to instant + pushes it to the recipient when the
    /// time arrives. Skips the local outbox path because the message
    /// shouldn't appear in the open chat until delivery; the next inbox
    /// poll after the worker fires will surface it on both ends.
    func sendScheduledText(_ text: String, scheduledAt: Date) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isGroup else {
            #if DEBUG
            print("⏰ [Schedule] Group scheduling not supported")
            #endif
            return
        }
        let recipientId = extractRecipientId()
        let clientId = UUID().uuidString
        do {
            // 🔴 ROUND 19 — hacker-audit Server F2 CRITICAL.
            // Scheduled sends used to ship `trimmed` plaintext as
            // the request `content`. Now we run it through the
            // sealer first so the server only ever stores opaque
            // bytes for the scheduled-delivery row.
            let sealed = await MessageContentSealer.seal(
                plaintext: trimmed,
                recipientUserId: recipientId,
                recipientAgreementPubKey: nil,
                msgId: clientId
            )
            await MessageContentSealer.recordSealVerdict(sealed.reason, for: clientId)
            let _: SendMessageResponse = try await NetworkService.shared.post(
                path: "/api/messages/send",
                body: SendMessageRequest(
                    messageId: clientId,
                    recipientId: recipientId,
                    content: sealed.base64,
                    messageType: "text",
                    sendMode: "scheduled",
                    scheduledAtUtc: scheduledAt
                ),
                idempotencyKey: clientId
            )
            logger.debug("Schedule queued for \(scheduledAt, privacy: .public) → \(recipientId, privacy: .private)")
        } catch {
            logger.debug("Schedule failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func sendText(_ text: String, replyTo: ChatMessage? = nil, entities: [MentionEntity]? = nil, clientMessageId: String? = nil) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        // Block check: prevent sending to blocked users
        let recipientId = extractRecipientId()
        if BlockService.shared.isBlocked(recipientId) {
            logger.debug("Blocked: cannot send to \(recipientId, privacy: .private)")
            return
        }
        
        // Fire-and-forget: no isSending toggle — UI stays free
        
        // 1. Generate client_message_id (UUID v4) — or reuse existing ID on retry
        let clientId = clientMessageId ?? UUID().uuidString
        let myId = await KeychainService.shared.getUserId() ?? ""
        let myName = AuthService.shared.currentUser?.displayName ?? ""
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        
        // 2. Create message with status = .pending

        let message = ChatMessage(
            id: clientId,
            serverId: nil,
            roomId: roomId,
            senderId: myId,
            senderName: myName,
            recipientId: extractRecipientId(),
            text: text,
            timestamp: Date(),
            type: .text,
            status: .pending,  // Golden Rule: Always starts as pending
            deliveryAuthority: .unknown,  // Will be set by OutboxManager
            createdAt: Date(),
            deliveredAt: nil,
            readAt: nil,
            hopCount: 0,
            routePath: [deviceId],
            sprayCounter: PremiumLimits.meshSprayBudget,
            hopLimit: PremiumLimits.meshHopLimit,
            originDeviceId: deviceId,
            needsForwarding: true,  // Always enable mesh bridging — STOP command halts relay once delivered
            attachmentUrl: nil,
            thumbnailUrl: nil,
            fileName: nil,
            mimeType: nil,
            fileSize: nil,
            audioDurationSeconds: nil,
            syncState: .queued,
            localPath: nil,
            uploadProgress: nil,
            lastError: nil,
            replyToMessageId: replyTo?.id,
            replyToTextPreview: generateReplyPreview(for: replyTo),
            replyToSenderName: replyTo?.senderName,
            replyToType: replyTo?.type,
            sendMode: nil,
            scheduledAtUtc: nil
        )
        
        // 2b. Attach mention entities if provided (for group messages)
        var mutableMessage = message
        if let entities = entities, !entities.isEmpty {
            mutableMessage.entities = entities
        }
        
        // 3. Insert to Local DB FIRST (Source of Truth)
        try await messageRepo.upsert(mutableMessage)
        
        // 4. Optimistic UI — append directly without DB re-read (⚡ saves ~10-50ms)
        await MainActor.run {
            // Fix: Replace existing message (retry/live-location) instead of appending duplicates
            if let idx = self.messages.firstIndex(where: { $0.id == mutableMessage.id }) {
                self.messages[idx] = mutableMessage
            } else {
                self.messages.append(mutableMessage)
            }
            self.sortMessages()
        }
        
        // 5. Update conversation preview immediately
        await ConversationStore.shared.handleIncomingMessage(mutableMessage)
        
        // 6. Transport Decision: FIRE AND FORGET
        // Run delivery in background so the Send button is freed instantly
        Task {
            await self.attemptDelivery(mutableMessage)
            // Reload DB to reflect status changes (.sent, .delivered) on the message bubble
            await self.loadFromDB()
        }
    }
    
    // MARK: - Send System Message (Screenshot alerts, etc.)
    
    /// Send a system notification message (e.g., "User took a screenshot")
    /// This is visible in the chat but styled differently
    func sendSystemMessage(_ text: String) async throws {
        guard !text.isEmpty else { return }
        
        let clientId = UUID().uuidString
        let myId = await KeychainService.shared.getUserId() ?? ""
        let myName = AuthService.shared.currentUser?.displayName ?? ""
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        
        let message = ChatMessage(
            id: clientId,
            serverId: nil,
            roomId: roomId,
            senderId: myId,
            senderName: myName,
            recipientId: extractRecipientId(),
            text: text,
            timestamp: Date(),
            type: .system,  // System message type
            status: .pending,
            deliveryAuthority: .unknown,
            createdAt: Date(),
            deliveredAt: nil,
            readAt: nil,
            hopCount: 0,
            routePath: [deviceId],
            sprayCounter: PremiumLimits.meshSprayBudget,
            hopLimit: PremiumLimits.meshHopLimit,
            originDeviceId: deviceId,
            needsForwarding: true,
            attachmentUrl: nil,
            thumbnailUrl: nil,
            fileName: nil,
            mimeType: nil,
            fileSize: nil,
            audioDurationSeconds: nil,
            syncState: .queued,
            localPath: nil,
            uploadProgress: nil,
            lastError: nil,
            replyToMessageId: nil,
            replyToTextPreview: nil,
            replyToSenderName: nil,
            replyToType: nil,
            sendMode: nil,
            scheduledAtUtc: nil
        )
        
        // Insert and deliver
        try await messageRepo.upsert(message)
        await loadFromDB()
        await attemptDelivery(message)
        await loadFromDB()
        await ConversationStore.shared.handleIncomingMessage(message)
        
        logger.debug("System message sent: \(text, privacy: .private)")
    }
    
    // MARK: - Send Location Message
    
    func sendLocation(_ payload: LocationPayload, clientMessageId: String? = nil) async throws {
        // Fire-and-forget: no isSending toggle — UI stays free
        
        // 1. Generate IDs (or reuse existing for live location updates)
        let isUpdate = clientMessageId != nil
        let clientId = clientMessageId ?? UUID().uuidString
        let myId = await KeychainService.shared.getUserId() ?? ""
        let myName = AuthService.shared.currentUser?.displayName ?? ""
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        
        // 2. Convert payload to JSON string for content
        guard let contentJson = payload.toJSONString() else {
            throw NSError(domain: "LocationError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode location"])
        }
        
        // 3. Create location message
        let message = ChatMessage(
            id: clientId,
            serverId: nil,
            roomId: roomId,
            senderId: myId,
            senderName: myName,
            recipientId: extractRecipientId(),
            text: contentJson,  // Location JSON stored in text field
            timestamp: Date(),
            type: .location,
            status: .pending,
            deliveryAuthority: .unknown,
            createdAt: Date(),
            deliveredAt: nil,
            readAt: nil,
            hopCount: 0,
            routePath: [deviceId],
            sprayCounter: PremiumLimits.meshSprayBudget,
            hopLimit: PremiumLimits.meshHopLimit,
            originDeviceId: deviceId,
            needsForwarding: true,
            attachmentUrl: nil,
            thumbnailUrl: nil,
            fileName: nil,
            mimeType: nil,
            fileSize: nil,
            audioDurationSeconds: nil,
            syncState: .queued,
            localPath: nil,
            uploadProgress: nil,
            lastError: nil,
            replyToMessageId: nil,
            replyToTextPreview: nil,
            replyToSenderName: nil,
            replyToType: nil,
            sendMode: nil,
            scheduledAtUtc: nil
        )
        
        // 4. Insert to DB and optimistic UI
        try await messageRepo.upsert(message)
        
        // FIX 11: Clear stop cache for live location updates so delivery re-activates
        if isUpdate {
            try? await StopCacheRepository.shared.remove(messageId: clientId)
        }
        
        await MainActor.run {
            if let idx = self.messages.firstIndex(where: { $0.id == message.id }) {
                self.messages[idx] = message
            } else {
                self.messages.append(message)
                self.sortMessages()
            }
        }
        
        // Skip inbox refresh on updates to prevent UI spam
        if !isUpdate {
            await ConversationStore.shared.handleIncomingMessage(message)
        }
        
        Task {
            await self.attemptDelivery(message)
            if !isUpdate {
                await self.loadFromDB()
            }
        }
    }
    
    // MARK: - Smart Delivery (Internet-First + Mesh-Assist v2.0)
    
    /// Attempt to deliver message using Internet-First strategy
    /// Rule: "همیشه اولویت ارسال با اینترنت است"
    /// v2.0: Uses persistent jobs + timeout-based mesh fallback
    private func attemptDelivery(_ message: ChatMessage) async {
        var message = message  // mutable local copy so E2EE can rewrite the body
        let clientId = message.id
        let recipientId = message.recipientId

        // 🔐 E2EE: wrap plaintext into a Double-Ratchet ciphertext for
        // transport. Local DB + UI already hold the plaintext (set
        // during sendText); we only swap it out on the wire copy so
        // both the server and mesh paths carry the encrypted body.
        // No-ops when feature flag is off, in groups, or when wrap
        // throws — in those cases the original plaintext is sent.
        //
        // 🟥 ROUND 36 (2026-05-17) — skip wrap when offline.
        //
        // Bug from user log: device with NO INTERNET tried to send
        // via mesh.  `E2EEMessagePipeline.wrapOutgoing` doesn't have
        // an existing Double-Ratchet session for the recipient, so
        // it tries to fetch the X3DH prekey bundle from the server
        // (`E2EEService.encryptInternal` line 198–201 calls
        // `bundleProvider.fetchBundle`).  That HTTP call fails with
        // NSURLErrorDomain -1009 (not connected), the wrap throws,
        // and the pipeline silently falls back to plaintext —
        // visible in the log as:
        //   `wrap failed for E76770F3: ... -1009 ... sending plaintext`
        //
        // Plaintext at the E2EE layer isn't a total security
        // disaster because the inner NoiseIK seal in MessageRouter
        // (line ~371) re-wraps with the cached recipient pubkey,
        // BUT only if PeerKeyDirectory / FriendDeviceRepository has
        // a pubkey cached for the recipient.  If neither does
        // (common after a fresh install before first online sync),
        // the message ships RVNP1 plaintext on the mesh wire —
        // exactly what the user is reporting.
        //
        // Defense: don't even ATTEMPT Double-Ratchet wrap when we
        // know it'll need a network call we can't make.  Two gates:
        //   1. We're offline AND
        //   2. We don't already have a cached session for this peer
        //
        // If both hold, skip the wrap entirely.  The inner NoiseIK
        // seal still runs and produces a properly-encrypted wire IF
        // the recipient's pubkey is cached.  If it isn't, the user
        // sees a "not E2EE" badge on the bubble — accurate, not a
        // silent lie.
        if message.type == .text,
           let plaintextText = message.text,
           !plaintextText.isEmpty,
           !E2EEMessagePipeline.isEncrypted(plaintextText) {

            let isOnline = NetworkMonitor.shared.isOnline
            let hasExistingSession = await E2EEMessagePipeline.hasSession(
                recipientUserId: recipientId
            )
            let canWrap = isOnline || hasExistingSession

            if canWrap {
                let wrapped = await E2EEMessagePipeline.wrapOutgoing(
                    plaintext: plaintextText,
                    recipientUserId: recipientId,
                    messageId: clientId,
                    isGroup: isGroup
                )
                if wrapped != plaintextText {
                    message.text = wrapped
                }
            } else {
                #if DEBUG
                print("🔐 [E2EE] Skip wrap for \(clientId.prefix(8)) — offline + no cached session. Inner NoiseIK seal will handle encryption if recipient pubkey is cached.")
                #endif
            }
        }

        logger.debug("Route deliver mid=\(clientId, privacy: .private) to=\(recipientId, privacy: .private) strategy=parallel")
        
        // 1. Create persistent delivery jobs (server + mesh for TEXT only)
        let allowMesh = (message.type == .text || message.type == .location)  // Text + Location (~100 bytes) go via Mesh
        // Serverless internet path: add a .bridge job (libp2p) for 1:1 text/location
        // ONLY when a relay/bootstrap node is configured — otherwise the libp2p
        // transport can't discover the peer and the job would retry forever
        // (battery). Groups go over mesh; the bridge processor fail-closes on
        // missing keys. Mirrors MessageRouter.send.
        var jobChannels: [JobChannel] = allowMesh ? [.server, .mesh] : [.server]
        if allowMesh && !isGroup && !recipientId.isEmpty && !AppConfig.libp2pBootstrapCSV.isEmpty {
            jobChannels.append(.bridge)
        }
        #if DEBUG
        print("🌉 [Send] mid=\(clientId.prefix(8)) channels=\(jobChannels.map { $0.rawValue }) isGroup=\(isGroup) bootstrap=\(AppConfig.libp2pBootstrapCSV.isEmpty ? "EMPTY" : "set")")
        #endif
        try? await DeliveryJobRepository.shared.createJobs(
            messageId: clientId,
            channels: jobChannels
        )
        
        // 🔴 ROUND 71 phase 3 follow-up #9 (2026-05-24) — track
        // server-send outcome so the group-online branch below can
        // fire a mesh fallback if the server send failed.
        let serverOutcome = ServerSendOutcomeBox()

        // 🟢 ROUND 76 (2026-05-24) — use netState (NWPath + server-probe
        // + flaky detection) instead of the bare NWPath `isOnline`. A
        // device on Wi-Fi with a broken backend (captive portal, Cloud
        // Run cold start, server outage) reads `isOnline=true` but
        // `netState=.degraded`. The previous code STILL fired the
        // server task in that state, burning 3s of timeout before
        // failing — and group + degraded users saw their message
        // visibly stall before the mesh fallback kicked in. With
        // netState, `.degraded` joins `.offline` in skipping the
        // server task so mesh fires immediately as the primary path,
        // and `.online` keeps the server-first behaviour.
        let _r76NetState = NetworkMonitor.shared.netState
        let shouldStartServerTask = (_r76NetState == .online || _r76NetState == .degraded)
        // Start server path immediately so race is truly parallel with mesh enqueue.
        // We still await it later to keep existing status/update semantics.
        let serverTask: Task<Void, Never>? = shouldStartServerTask ? Task { [self] in
            let serverTimeout: TimeInterval = 3.0

            do {
                let result = try await sendViaServerWithTimeout(message, timeout: serverTimeout)
                #if DEBUG
                print("[Route] ✅ server delivered")
                #endif
                await serverOutcome.markSucceeded()

                // Mark server job as delivered
                try? await DeliveryJobRepository.shared.markDelivered(messageId: clientId, channel: .server)
                

                
                // Check if RECIPIENT actually received (not just accepted)
                if result.recipientDelivered {
                    // Stop mesh + broadcast stop
                    try? await DeliveryJobRepository.shared.markStopped(messageId: clientId)
                    try? await StopCacheRepository.shared.persist(clientId)
                    await BLEMeshEngine.shared.broadcastStop(clientId)
                    #if DEBUG
                    print("[Route] recipient confirmed → mesh stopped")
                    #endif
                } else {
                    // server accepted, mesh continues
                }
                
            } catch {
                #if DEBUG
                print("[Route] ❌ server failed: \(error.localizedDescription)")
                #endif
                await serverOutcome.markFailed()
                // Surface user-actionable 403 / 4xx server messages to
                // the open ChatView so the user knows a send was gated
                // (e.g. message-request quota hit, recipient set
                // friends-only privacy). Network / 5xx errors stay
                // silent — the mesh path is already retrying those.
                if case let APIError.httpError(code, detail) = error,
                   code >= 400 && code < 500, !detail.isEmpty {
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: Notification.Name("ChatSendErrorToast"),
                            object: nil,
                            userInfo: ["message": detail]
                        )
                    }
                } else if case APIError.forbidden = error {
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: Notification.Name("ChatSendErrorToast"),
                            object: nil,
                            userInfo: ["message": "Couldn't send: access denied."]
                        )
                    }
                }
            }
        } : nil
        
        // 2. Send via MESH (TEXT ONLY — media/voice/file skip mesh).
        //
        // 🔴 ROUND 71 phase 3 follow-up #9 (2026-05-24) — group
        // mesh-send prioritisation.
        //
        // USER DIRECTIVE:
        //   "olaviat ersal payam ha dar group chat bayad ba internet
        //    bashe agar internet nabod bayad switch kone be mesh va
        //    bridge va mesh relay"
        //   ≈ for group chat, server path takes priority; only fall
        //   back to mesh when offline.
        //
        // RATIONALE:
        //   - Online sender → server fans out to every member via WS
        //     + APNs; offline members get the message through the
        //     reverse-bridge (B receives WS push and re-broadcasts
        //     to mesh — that path stays untouched).
        //   - Mesh broadcast from an ONLINE sender wastes BLE
        //     airtime + battery and produces double-deliveries to
        //     nearby peers who already got it via WS.
        //   - 1:1 keeps the dual-path strategy (server + mesh in
        //     parallel) — works well today and the user only asked
        //     about groups.
        //
        // GATE (updated R76, 2026-05-24):
        //   • Group + .online (server reachable + stable) → skip mesh,
        //     server is primary (saves BLE airtime + battery).
        //   • Group + .degraded (Wi-Fi up but server unreachable /
        //     flaky / captive-portal) → FIRE mesh IN PARALLEL with
        //     the (likely-failing) server task. Whichever path wins
        //     delivers first; user doesn't see a 3-second stall.
        //   • Group + .offline → fire mesh (only available path).
        //   • 1:1 → unchanged dual-path (always fire mesh + server).
        //
        // This matches the user's directive verbatim: "olaviat ersal
        // payam ha dar group chat bayad ba internet bashe agar
        // internet nabod bayad switch kone be mesh va bridge va
        // mesh relay" — server-first when truly online, immediate
        // mesh fallback otherwise.
        let shouldFireMesh: Bool = {
            guard allowMesh else { return false }
            if self.isGroup {
                let state = NetworkMonitor.shared.netState
                if state == .online {
                    #if DEBUG
                    print("[Route] 🟢 Group + .online — skipping mesh broadcast (server primary)")
                    #endif
                    return false
                }
                #if DEBUG
                print("[Route] 🟡 Group + \(state) — firing mesh in parallel with server task")
                #endif
                return true
            }
            return true
        }()

        #if !targetEnvironment(simulator)
        if shouldFireMesh {
            await sendViaMeshImmediate(message)
            // mesh enqueued
        } else {
            // mesh skipped (either non-text, or group + online)
        }
        #else
        // mesh skipped (simulator)
        #endif

        // 3. Await server path result if online
        if let serverTask {
            await serverTask.value
        } else {
            // no internet → mesh only
        }

        // 🔴 ROUND 71 phase 3 follow-up #9 (2026-05-24) — group
        // safety-net mesh fallback. If we SKIPPED mesh above
        // (group + online) but the server send failed (didn't
        // reach success), fire mesh as a last-resort fallback so
        // the message still has a chance to reach BLE-peer members
        // via the bridge chain.
        if self.isGroup && allowMesh && !shouldFireMesh {
            let succeeded = await serverOutcome.succeeded
            if !succeeded {
                #if DEBUG
                print("[Route] ⚠️ Group server send failed — firing mesh fallback")
                #endif
                #if !targetEnvironment(simulator)
                await sendViaMeshImmediate(message)
                #endif
            }
        }
    }

    /// Small actor-isolated outcome tracker so the server-task
    /// can record success/failure that the group-online fallback
    /// branch can read post-await without sharing mutable state.
    private actor ServerSendOutcomeBox {
        private var _succeeded: Bool = false
        var succeeded: Bool { _succeeded }
        func markSucceeded() { _succeeded = true }
        func markFailed() { _succeeded = false }
    }
    
    /// Send via mesh immediately (not waiting for JobRunner)
    private func sendViaMeshImmediate(_ message: ChatMessage) async {
        var envelope = message.toMeshEnvelope()

        // 🟢 ROUND 73 (2026-05-24) — group E2EE on mesh path.
        //
        // CRITICAL E2EE BUG (per audit, agent 3 finding #1):
        // `toMeshEnvelope()` ships `message.text` raw. For 1:1 chats
        // it's already sealed by `E2EEMessagePipeline.wrapOutgoing`
        // upstream. For GROUPS, the wrap pipeline is a Double-Ratchet
        // wrap (1:1 model) and does NOT encrypt under the group's
        // AES-GCM key — so the body shipped on the mesh wire was
        // PLAINTEXT GROUP CONTENT. Worse: when an online relayer
        // bridged this envelope to the server, the server stored
        // plaintext in the GroupMessage row (the bridge handler
        // marks the body opaque ONLY when group_key_version is set;
        // ours wasn't, so it Fernet-wrapped admin-readable plaintext).
        //
        // FIX: when the conversation is a group, AES-GCM-encrypt the
        // body with `GroupKeyService` BEFORE the envelope leaves
        // this device. Also stamp `isGroup = true` and the
        // `groupKeyVersion` so receivers can: (a) route via the
        // group thread, (b) accept the bridge-signature exception
        // for unsynced groups (R73 MeshCryptoService fix), (c) pick
        // the correct key version for decrypt.
        //
        // FAIL-CLOSED: if the group key isn't available locally
        // (offline group never synced yet), refuse to mesh-send —
        // never ship plaintext. The sender's outbox keeps the
        // message pending; a later sync will replay it through the
        // proper path.
        if self.isGroup, let plain = message.text, !plain.isEmpty {
            // Only encrypt if not already AES-GCM-sealed. The
            // envelope's text could already be ciphertext if a
            // higher layer (server WS rebroadcast / DeliveryJob
            // retry) handed us a sealed body; double-encrypting
            // would break receiver decrypt.
            if message.groupKeyVersion == nil {
                guard let (cipherB64, keyVersion) = await GroupKeyService.shared.encrypt(plain, groupId: self.roomId) else {
                    #if DEBUG
                    print("🔒 [MessageStore] REFUSING to mesh-broadcast plaintext group message — group key unavailable for \(self.roomId.prefix(8)). Message stays in outbox.")
                    #endif
                    return
                }
                envelope.text = cipherB64
                envelope.groupKeyVersion = keyVersion
            } else {
                envelope.groupKeyVersion = message.groupKeyVersion
            }
            envelope.isGroup = true
        } else if !self.isGroup, let plain = message.text, !plain.isEmpty {
            // 🔐 ROUND 77 (2026-05-24) — 1:1 mesh fail-closed sealer.
            //
            // BUG (audit Agent #1, post-R76-revert): for 1:1 chats
            // this path used to ship `message.text` straight to the
            // mesh wire, trusting upstream `E2EEMessagePipeline.
            // wrapOutgoing` to have sealed it. BUT `wrapOutgoing`
            // fails-OPEN: when there is NO Double-Ratchet session
            // AND we're offline, it silently returns the raw
            // plaintext (logs "skip wrap"). The mesh broadcast
            // then ships that plaintext SIGNED-BUT-UNSEALED — every
            // BLE relay along the path sees the user's text.
            //
            // The `MessageRouter.broadcast` (Core/Mesh) DOES have
            // the fail-closed gate, but `sendViaMeshImmediate` is
            // called directly from `attemptDelivery` and bypasses
            // MessageRouter entirely.
            //
            // FIX: run the same `MessageContentSealer.seal` the
            // HTTPS sendViaServer paths use. Refuse to broadcast
            // when the sealer returns `isEncrypted=false` (RVNP1
            // fallback). Outbox keeps the message pending; the
            // next sync attempt will re-seal once ATSAM/Noise is
            // available.
            //
            // SAFETY: idempotent if the upstream wrap already
            // sealed the body — the sealer detects existing magic
            // (RVNA1/RVNS1) and short-circuits to passthrough.
            // Detect already-sealed by magic-prefix check so we
            // don't double-encrypt.
            let alreadySealed: Bool = {
                guard let data = Data(base64Encoded: plain),
                      data.count >= 8 else { return false }
                let magic = data.prefix(5)
                // RVNS1 / RVNA1 / RVNP1 — all marked with 5-byte ASCII
                let s = String(data: magic, encoding: .ascii) ?? ""
                return s == "RVNS1" || s == "RVNA1" || s == "RVNP1"
            }()
            if !alreadySealed {
                let sealed = await MessageContentSealer.seal(
                    plaintext: plain,
                    recipientUserId: message.recipientId,
                    recipientAgreementPubKey: nil,
                    msgId: message.id
                )
                await MessageContentSealer.recordSealVerdict(sealed.reason, for: message.id)
                guard sealed.isEncrypted, !sealed.base64.isEmpty else {
                    #if DEBUG
                    print("🔒 [MessageStore] REFUSING to mesh-broadcast 1:1 plaintext fallback (reason=\(sealed.reason)) for mid=\(message.id.prefix(8)). Outbox retains; will retry when ATSAM/Noise is available.")
                    #endif
                    return
                }
                envelope.text = sealed.base64
            }
        }

        // Send immediately via mesh — trust verification happens on the receive side.
        // Blocking on the send side caused 50+ second delays when trusted devices
        // were configured but no trusted peer was directly connected.
        await BLEMeshEngine.shared.enqueueForBroadcast(envelope)
    }
    
    /// Send via server with timeout (returns result for delivery status check)
    private func sendViaServerWithTimeout(_ message: ChatMessage, timeout: TimeInterval) async throws -> ServerSendResult {
        return try await withThrowingTaskGroup(of: ServerSendResult.self) { group in
            // Server send task
            group.addTask {
                // Check if this is a group message
                if self.isGroup {
                    // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) —
                    // E2EE the group content (same fix as
                    // sendViaServer above). Fail-closed on missing
                    // group key — never ship plaintext.

                    // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) —
                    // mirror the offline-group reconcile gate from
                    // sendViaServer. If the roomId is a local UUID
                    // (offline-create), force a sync before
                    // attempting the encrypt (which would otherwise
                    // 404 on /api/groups/local_xxxx/key) and the
                    // POST.
                    if self.roomId.hasPrefix("local_"), NetworkMonitor.shared.isOnline {
                        #if DEBUG
                        print("🔁 [MessageStore-timeout] Group \(self.roomId.prefix(8)) is local-only — syncing to server before send")
                        #endif
                        await GroupService.shared.syncPendingGroups()
                    }

                    let plain = message.text ?? ""
                    guard let (cipherB64, keyVersion) = await GroupKeyService.shared.encrypt(plain, groupId: self.roomId) else {
                        #if DEBUG
                        print("🔒 [MessageStore] REFUSING to ship plaintext group message via timeout-retry — group key unavailable for \(self.roomId.prefix(8))")
                        #endif
                        throw NSError(
                            domain: "MessageStore",
                            code: -1001,
                            userInfo: [NSLocalizedDescriptionKey: "Group key not yet synced; message stays pending."]
                        )
                    }
                    // Group message: use group endpoint
                    let response: GroupMessageResponse = try await NetworkService.shared.post(
                        path: "/api/groups/\(self.roomId)/messages",
                        body: SendGroupMessageRequest(
                            messageId: message.id,
                            content: cipherB64,
                            messageType: message.type.rawValue,
                            replyToMessageId: message.replyToMessageId,
                            // 🔴 ROUND 19 — Server F6: never send the
                            // reply preview to the server in cleartext.
                            replyToTextPreview: nil,
                            replyToSenderName: message.replyToSenderName,
                            replyToType: message.replyToType?.rawValue,
                            entities: message.entities,
                            groupKeyVersion: keyVersion
                        ),
                        idempotencyKey: message.id
                    )
                    
                    // Batch update: server_id + status + authority in single DB round-trip (⚡ saves ~10-30ms)
                    try await self.messageRepo.updateAfterServerSend(
                        clientMessageId: message.id,
                        serverId: response.id
                    )
                    
                    #if DEBUG
                    print("✅ [MessageStore] Group message sent via server: \(message.id.prefix(8))")
                    #endif
                    
                    return ServerSendResult(
                        messageId: response.id,
                        status: "sent",
                        recipientDelivered: true,
                        recipientOnline: true
                    )
                } else {
                    // 1:1 message: use regular endpoint. Pull the
                    // per-thread disappearing-message default the user has
                    // toggled on the chat composer (UserDefaults-keyed by
                    // roomId) and pass it through so the server can stamp
                    // expires_at and enforce the TTL.
                    let expiryMode = ChatExpirySettings.mode(forRoom: self.roomId)?.rawValue

                    // 🔴 ROUND 19 — hacker-audit Server F2 CRITICAL.
                    // This timeout-retry path used to ship `message.text`
                    // straight as `content` (no seal). Run through the
                    // sealer so it matches what `OutboxManager` /
                    // `DeliveryJobRunner` already do.
                    let sealed = await MessageContentSealer.seal(
                        plaintext: message.text ?? "",
                        recipientUserId: message.recipientId,
                        recipientAgreementPubKey: nil,
                        msgId: message.id
                    )
                    await MessageContentSealer.recordSealVerdict(sealed.reason, for: message.id)
                    let response: SendMessageResponse = try await NetworkService.shared.post(
                        path: "/api/messages/send",
                        body: SendMessageRequest(
                            messageId: message.id,
                            recipientId: message.recipientId,
                            content: sealed.base64,
                            messageType: message.type.rawValue,
                            audioUrl: nil,
                            replyToMessageId: nil,
                            expiryMode: expiryMode
                        ),
                        idempotencyKey: message.id
                    )
                    
                    // Batch update: server_id + status + authority in single DB round-trip (⚡ saves ~10-30ms)
                    try await self.messageRepo.updateAfterServerSend(
                        clientMessageId: message.id,
                        serverId: response.id
                    )
                    

                    
                    return ServerSendResult(
                        messageId: response.id,
                        status: response.status ?? "accepted",
                        recipientDelivered: response.recipientDelivered ?? false,
                        recipientOnline: response.recipientOnline ?? false
                    )
                }
            }
            
            // Timeout task
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw JobError.timeout
            }
            
            // Return first to complete
            guard let result = try await group.next() else {
                throw JobError.timeout
            }
            
            group.cancelAll()
            return result
        }
    }
    
    /// Check if recipient is currently reachable via Bluetooth mesh
    private func isRecipientReachableViaBLE(_ recipientId: String) async -> Bool {
        #if targetEnvironment(simulator)
        return false  // No BLE on simulator
        #else
        let peers = await BLEMeshEngine.shared.getConnectedPeers()
        
        if peers.isEmpty {
            #if DEBUG
            print("🎯 [Route] No BLE peers connected")
            #endif
            return false
        }
        
        // Check if any connected peer belongs to the recipient
        // 1. Direct match by userId
        if peers.contains(where: { $0.userId == recipientId }) {
            #if DEBUG
            print("🎯 [Route] Found recipient's device directly connected")
            #endif
            return true
        }
        
        // 2. Check trusted devices for recipient
        let trustedDevices = await FriendDeviceRepository.shared.getTrustedDevices(forUser: recipientId)
        let trustedFingerprints = Set(trustedDevices.map { $0.fingerprint })
        
        let matchingPeers = peers.filter { peer in
            guard let fingerprint = peer.fingerprint else { return false }
            return trustedFingerprints.contains(fingerprint)
        }
        
        if !matchingPeers.isEmpty {
            #if DEBUG
            print("🎯 [Route] Found \(matchingPeers.count) trusted peer(s) for recipient")
            #endif
            return true
        }
        
        // 3. For relay mode: check if we have ANY peers (can relay)
        // In DTN/mesh, any peer can potentially relay to the target
        if !peers.isEmpty {
            #if DEBUG
            print("🎯 [Route] \(peers.count) peers available for relay routing")
            #endif
            return true  // Enable relay mode
        }
        
        return false
        #endif
    }
    
    /// Send message via server API
    private func sendViaServer(_ message: ChatMessage) async throws {
        let clientId = message.id
        
        try await messageRepo.updateStatus(clientMessageId: clientId, status: .sending)
        
        if isGroup {
            // Group message: use group endpoint.
            //
            // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — E2EE the
            // group content. Pre-fix this path shipped `message.text`
            // as plaintext to the server, which violated the
            // bridge-can't-see-content invariant: the server stored
            // the cleartext and any relay/bridge in the future could
            // observe it. Now we wrap via the group's symmetric AES-
            // GCM key (`GroupKeyService.encrypt`) and ship the
            // ciphertext + `group_key_version` so receivers can
            // unwrap locally via `GroupKeyService.decrypt`. If the
            // key isn't available locally (group not yet fully
            // synced after offline-create), fail-closed and stay in
            // outbox for retry — never ship plaintext.

            // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — offline-
            // group reconcile gate.
            //
            // If this is a "local_xxxx" UUID synthesized while the
            // server was unreachable, the server has no record of
            // the group yet. Any attempt to POST
            // `/api/groups/local_xxxx/messages` (or to GET its key
            // via GroupKeyService.encrypt → /api/groups/.../key)
            // would 404. Trigger an explicit syncPendingGroups()
            // here so the server adopts our client_id BEFORE we
            // attempt to encrypt + send. Cheap no-op when there's
            // nothing pending. Skips on offline (sync would throw
            // anyway; mesh path is already firing in parallel).
            //
            // 🛡️ SECURITY: the local UUID is adopted by the server
            // only if the caller is the original creator (see
            // groups.py create_group `client_id` branch). Other
            // members can't claim or impersonate the id.
            if roomId.hasPrefix("local_"), NetworkMonitor.shared.isOnline {
                #if DEBUG
                print("🔁 [MessageStore] Group \(roomId.prefix(8)) is local-only — syncing to server before send")
                #endif
                await GroupService.shared.syncPendingGroups()
            }

            let plain = message.text ?? ""
            guard let (cipherB64, keyVersion) = await GroupKeyService.shared.encrypt(plain, groupId: roomId) else {
                try await messageRepo.updateStatus(clientMessageId: clientId, status: .failed)
                #if DEBUG
                print("🔒 [MessageStore] REFUSING to ship plaintext group message — group key not available for \(roomId.prefix(8)). Outbox will retry once key syncs.")
                #endif
                throw NSError(
                    domain: "MessageStore",
                    code: -1001,
                    userInfo: [NSLocalizedDescriptionKey: "Group key not yet synced; message stays pending."]
                )
            }

            do {
                let response: GroupMessageResponse = try await NetworkService.shared.post(
                    path: "/api/groups/\(roomId)/messages",
                    body: SendGroupMessageRequest(
                        messageId: clientId,
                        content: cipherB64,
                        messageType: message.type.rawValue,
                        replyToMessageId: message.replyToMessageId,
                        replyToTextPreview: nil,   // R19: don't ship reply preview cleartext
                        replyToSenderName: message.replyToSenderName,
                        replyToType: message.replyToType?.rawValue,
                        entities: message.entities,
                        groupKeyVersion: keyVersion
                    ),
                    idempotencyKey: clientId
                )

                // Server ACK - update with server ID
                try await messageRepo.updateServerId(clientMessageId: clientId, serverId: response.id)
                try await messageRepo.updateDeliveryAuthority(clientMessageId: clientId, authority: .server)
                try await messageRepo.updateStatus(clientMessageId: clientId, status: .sent)
                #if DEBUG
                print("✅ [MessageStore] Group message sent via server (sealed v\(keyVersion)): \(clientId)")
                #endif
            } catch APIError.notFound {
                // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — 404
                // recovery for offline-created groups.
                //
                // If the server returns 404 on /api/groups/{id}/messages
                // we likely have a local UUID that hasn't been
                // reconciled yet OR the reconcile briefly raced with
                // the send. Force one more syncPendingGroups() pass
                // and let the outbox retry on its normal cadence
                // (don't recurse here — keeps the failure-mode
                // bounded if the server truly doesn't know the
                // group). Stay in failed so DeliveryJobRunner picks
                // it up. The mesh path already broadcast the same
                // payload so the message isn't lost.
                #if DEBUG
                print("⚠️ [MessageStore] Group send hit 404 for \(roomId.prefix(8)) — triggering syncPendingGroups + leaving in failed for retry")
                #endif
                if NetworkMonitor.shared.isOnline {
                    await GroupService.shared.syncPendingGroups()
                }
                try await messageRepo.updateStatus(clientMessageId: clientId, status: .failed)
                throw APIError.notFound
            }
        } else {
            // 1:1 message: use regular endpoint. Pull the per-thread
            // disappearing-message default for this room and forward it
            // to the server so it can stamp expires_at + enforce the TTL.
            let expiryMode = ChatExpirySettings.mode(forRoom: self.roomId)?.rawValue

            // 🔴 ROUND 19 — hacker-audit Server F2 CRITICAL.
            // sendViaServer used to ship plaintext directly. Seal it
            // first.
            let sealed = await MessageContentSealer.seal(
                plaintext: message.text ?? "",
                recipientUserId: message.recipientId,
                recipientAgreementPubKey: nil,
                msgId: clientId
            )
            await MessageContentSealer.recordSealVerdict(sealed.reason, for: clientId)
            let response: SendMessageResponse = try await NetworkService.shared.post(
                path: "/api/messages/send",
                body: SendMessageRequest(
                    messageId: clientId,
                    recipientId: message.recipientId,
                    content: sealed.base64,
                    messageType: message.type.rawValue,
                    audioUrl: nil,
                    replyToMessageId: message.replyToMessageId,
                    expiryMode: expiryMode
                ),
                idempotencyKey: clientId  // Duplicate prevention
            )

            // Server ACK - update with server ID
            try await messageRepo.updateServerId(clientMessageId: clientId, serverId: response.id)
            try await messageRepo.updateDeliveryAuthority(clientMessageId: clientId, authority: .server)
            try await messageRepo.updateStatus(clientMessageId: clientId, status: .sent)
            #if DEBUG
            print("✅ [MessageStore] Message sent via server: \(clientId)")
            #endif
        }
    }
    
    // MARK: - Send via Bluetooth Mesh
    
    private func sendViaMesh(_ message: ChatMessage) async {
        let clientId = message.id
        
        #if targetEnvironment(simulator)
        try? await messageRepo.updateStatus(clientMessageId: clientId, status: .pending)
        try? await messageRepo.updateDeliveryAuthority(clientMessageId: clientId, authority: .mesh)
        #else
        let peers = await BLEMeshEngine.shared.getConnectedPeers()
        
        if peers.isEmpty {
            try? await messageRepo.updateStatus(clientMessageId: clientId, status: .pending)
            try? await messageRepo.updateDeliveryAuthority(clientMessageId: clientId, authority: .mesh)
            return
        }
        
        // Check trusted devices for recipient
        let trustedDevices = await FriendDeviceRepository.shared.getTrustedDevices(forUser: message.recipientId)
        let trustedPeers = peers.filter { peer in
            guard let fingerprint = peer.fingerprint else { return false }
            return trustedDevices.contains { $0.fingerprint == fingerprint }
        }
        
        let envelope = message.toMeshEnvelope()
        try? await messageRepo.updateStatus(clientMessageId: clientId, status: .forwarding)
        await BLEMeshEngine.shared.enqueueForBroadcast(envelope)
        try? await messageRepo.updateDeliveryAuthority(clientMessageId: clientId, authority: .mesh)
        #if DEBUG
        print("[Mesh] sent mid=\(clientId.prefix(8)) trusted=\(trustedPeers.count)/\(peers.count) peers")
        #endif
        #endif
    }
    
    // MARK: - Retry Failed Message
    
    func retryMessage(_ message: ChatMessage) async throws {
        guard message.status == .failed else { return }
        
        // Reset to pending and try again
        try await messageRepo.updateStatus(clientMessageId: message.id, status: .pending)
        await loadFromDB()
        
        // Re-send based on message type
        switch message.type {
        case .text:
            if let text = message.text {
                try await sendText(text, clientMessageId: message.id)
            }
        case .image:
            if let path = message.localPath {
                // FIX: Resolve filename against active sandbox (documentDirectory/attachments)
                let fileName = URL(fileURLWithPath: path).lastPathComponent
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let resolvedPath = docs.appendingPathComponent("attachments").appendingPathComponent(fileName).path
                let actualPath = FileManager.default.fileExists(atPath: resolvedPath) ? resolvedPath : path
                if FileManager.default.fileExists(atPath: actualPath),
                   let data = FileManager.default.contents(atPath: actualPath),
                   let image = UIImage(data: data) {
                    try await AttachmentService.shared.sendImage(
                        image,
                        roomId: roomId,
                        recipientId: message.recipientId,
                        isGroup: isGroup,
                        clientMessageId: message.id
                    )
                    await loadFromDB()
                } else {
                    #if DEBUG
                    print("❌ [Retry] Image file not found at localPath")
                    #endif
                    try await messageRepo.updateStatus(clientMessageId: message.id, status: .failed)
                }
            }
        case .voice:
            if let path = message.localPath {
                // FIX: Resolve filename against active sandbox (documentDirectory/attachments)
                let fileName = URL(fileURLWithPath: path).lastPathComponent
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let resolvedPath = docs.appendingPathComponent("attachments").appendingPathComponent(fileName).path
                let actualPath = FileManager.default.fileExists(atPath: resolvedPath) ? resolvedPath : path
                if FileManager.default.fileExists(atPath: actualPath) {
                    let url = URL(fileURLWithPath: actualPath)
                    let duration = message.audioDurationSeconds ?? 0
                    try await AttachmentService.shared.sendVoice(
                        audioURL: url,
                        duration: duration,
                        roomId: roomId,
                        recipientId: message.recipientId,
                        isGroup: isGroup,
                        clientMessageId: message.id
                    )
                    await loadFromDB()
                } else {
                    #if DEBUG
                    print("❌ [Retry] Voice file not found at localPath")
                    #endif
                    try await messageRepo.updateStatus(clientMessageId: message.id, status: .failed)
                }
            }
        case .file:
            if let path = message.localPath {
                // FIX: Resolve filename against active sandbox (documentDirectory/attachments)
                let fileName = URL(fileURLWithPath: path).lastPathComponent
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let resolvedPath = docs.appendingPathComponent("attachments").appendingPathComponent(fileName).path
                let actualPath = FileManager.default.fileExists(atPath: resolvedPath) ? resolvedPath : path
                if FileManager.default.fileExists(atPath: actualPath) {
                    let url = URL(fileURLWithPath: actualPath)
                    try await AttachmentService.shared.sendFile(
                        fileURL: url,
                        roomId: roomId,
                        recipientId: message.recipientId,
                        isGroup: isGroup,
                        clientMessageId: message.id
                    )
                    await loadFromDB()
                } else {
                    #if DEBUG
                    print("❌ [Retry] File not found at localPath")
                    #endif
                    try await messageRepo.updateStatus(clientMessageId: message.id, status: .failed)
                }
            }
        default:
            break
        }
    }
    
    // MARK: - Handle Incoming Message (from push/poll)
    
    func handleIncomingMessage(_ message: ChatMessage) async {
        // Check if belongs to this room
        guard message.roomId == roomId else { return }
        
        // Idempotent insert
        guard !(await messageRepo.exists(clientMessageId: message.id)) else { return }
        
        try? await messageRepo.upsert(message)
        await loadFromDB()
    }
    
    // MARK: - Mark as Read
    
    func markAllAsRead() async {
        let myId = await KeychainService.shared.getUserId() ?? ""
        var hasUnread = false
        var newlyReadMeshMessages: [ChatMessage] = []
        
        // 1. Mark locally in memory (local copy to avoid N UI refreshes)
        var updatedMessages = messages
        for i in updatedMessages.indices {
            if updatedMessages[i].status != .read && updatedMessages[i].senderId != myId {
                updatedMessages[i].status = .read
                hasUnread = true
                if updatedMessages[i].deliveryAuthority == .mesh && !isGroup {
                    newlyReadMeshMessages.append(updatedMessages[i])
                }
            }
        }
        
        // 1. ALWAYS clear conversation unread count to prevent stuck badges!
        // (If ghost mode is off, this also queues a server sync)
        await ConversationStore.shared.markAsRead(roomId: roomId)

        guard hasUnread else { return }
        messages = updatedMessages // Single UI refresh instead of N
        
        // 2. Persist to DB
        try? await messageRepo.markAllReadInRoom(roomId: roomId, myUserId: myId)
        
        // 3. ⚡️ Send Mesh Read ACKs immediately in background!
        if !newlyReadMeshMessages.isEmpty && !PremiumLimits.ghostModeEnabled {
            Task.detached(priority: .background) {
                let deviceId = DeviceIdentityService.shared.fingerprint ?? ""
                for msg in newlyReadMeshMessages {
                    let ack = MeshACKEnvelope(
                        originalMessageId: msg.id,
                        senderId: myId,
                        recipientId: msg.senderId,
                        status: .read,
                        pathUsed: "mesh",
                        originDeviceId: deviceId
                    )
                    await BLEMeshEngine.shared.sendACK(ack)
                }
            }
        }
    }
    
    // MARK: - Edit Message

    /// Edit a sent text message. Updates the local copy optimistically and
    /// then PATCHes `/api/messages/{id}` so the change persists across
    /// devices and propagates to the recipient via the inbox WebSocket.
    /// On server failure we roll back to keep the bubble truthful.
    func editMessage(id: String, newText: String) async {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        let oldText = messages[idx].text
        let oldEditedAt = messages[idx].editedAt

        // 1. Optimistic local update
        messages[idx].text = newText
        messages[idx].editedAt = Date()
        try? await messageRepo.updateText(clientMessageId: id, newText: newText)

        // 2. Server edit. The DTO uses snake_case to match NetworkService's
        // global encoder; the response carries the canonical edited_at the
        // server stamped, so we adopt that timestamp on success.
        struct EditBody: Encodable { let content: String }
        struct EditResponse: Decodable { let id: String; let editedAt: Date? }
        do {
            // Server route is PATCH /api/messages/{server_id}, but we send
            // by server_id only — abort silently if we don't have one yet
            // (the message hasn't synced upstream).
            let serverId = messages[idx].serverId ?? id

            // 🔴 ROUND 19 — hacker-audit Server F4 CRITICAL.
            // Edits used to PATCH the new plaintext directly; an
            // on-path attacker (or compromised server) saw the new
            // text in cleartext. Now we run it through the same
            // sealer the original send used, with the ORIGINAL
            // msgId so the receiver's AAD binding matches.
            let recipientForSeal = messages[idx].recipientId
            let sealed = await MessageContentSealer.seal(
                plaintext: newText,
                recipientUserId: recipientForSeal,
                recipientAgreementPubKey: nil,
                msgId: id
            )
            let resp: EditResponse = try await NetworkService.shared.patch(
                path: "/api/messages/\(serverId)",
                body: EditBody(content: sealed.base64)
            )
            if let serverEditedAt = resp.editedAt,
               let idx2 = messages.firstIndex(where: { $0.id == id }) {
                messages[idx2].editedAt = serverEditedAt
            }
            #if DEBUG
            print("✏️ [MessageStore] Edited message \(id.prefix(8)) on server")
            #endif
        } catch {
            // Roll back on failure so the bubble matches reality.
            if let i = messages.firstIndex(where: { $0.id == id }) {
                messages[i].text = oldText
                messages[i].editedAt = oldEditedAt
            }
            try? await messageRepo.updateText(clientMessageId: id, newText: oldText ?? "")
            #if DEBUG
            print("❌ [MessageStore] Edit failed, rolled back: \(error)")
            #endif
        }
    }
    
    // MARK: - Delete Message
    
    func deleteMessage(_ messageId: String) async {
        // 1. Delete physical attachment file if exists (prevent storage leak)
        if let msg = messages.first(where: { $0.id == messageId }),
           let path = msg.localPath {
            // FIX: Resolve filename against active sandbox (iOS changes container UUID on update)
            // Build dynamic path using documentDirectory/attachments (actual storage location)
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let currentLocalURL = docs.appendingPathComponent("attachments").appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: currentLocalURL)
            // Also try the stored path as fallback (may still be valid in same install session)
            try? FileManager.default.removeItem(atPath: path)
            #if DEBUG
            print("🗑️ [MessageStore] Deleted attachment file: \(fileName)")
            #endif
        }
        
        // 2. Remove from local array (optimistic)
        messages.removeAll { $0.id == messageId }
        
        // 3. Delete from local DB
        do {
            try await DatabaseService.shared.execute(
                "DELETE FROM messages WHERE client_message_id = ?",
                params: [messageId]
            )
            #if DEBUG
            print("🗑️ [MessageStore] Deleted message \(messageId.prefix(8)) from local DB")
            #endif
        } catch {
            #if DEBUG
            print("❌ [MessageStore] Failed to delete from local DB: \(error)")
            #endif
        }
        
        // 3. Delete from server (only if online)
        if NetworkMonitor.shared.isOnline {
            Task {
                do {
                    _ = try await NetworkService.shared.delete(
                        path: "/api/messages/\(messageId)"
                    ) as EmptyResponse
                    #if DEBUG
                    print("✅ [MessageStore] Message deleted from server")
                    #endif
                } catch {
                    #if DEBUG
                    print("⚠️ [MessageStore] Failed to delete from server: \(error)")
                    #endif
                }
            }
        }
    }
    
    // MARK: - Polling (for real-time within chat)
    
    @MainActor
    func startPolling() {
        stopPolling()
        // 🔋 BUG FIX (2026-05-10): skip the poll when the WebSocket
        // is delivering messages already. The previous 10s timer
        // fired regardless, duplicating every read of /api/messages
        // for the open chat alongside the WS push. Costs measurable
        // battery + bandwidth on long chat sessions.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if RealtimeEngine.shared.connectionState == .websocket {
                    // WS is live — it pushes deltas; polling is redundant.
                    return
                }
                await self.fetchMessages()
            }
        }
    }
    
    @MainActor
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
    
    // MARK: - Helpers
    
    private func sortMessages() {
        messages.sort {
            if $0.timestamp == $1.timestamp {
                return $0.id < $1.id  // Deterministic tie-breaker
            }
            return $0.timestamp < $1.timestamp
        }
    }
    
    private func extractRecipientId() -> String {
        // SIMPLIFIED: roomId is now always the peer's userId (normalized)
        // Since roomId = peer.userId, we just return it directly
        return roomId
    }
    
    /// Generate a proper text preview for reply based on message type
    private func generateReplyPreview(for message: ChatMessage?) -> String? {
        guard let message = message else { return nil }

        // 🔴 ROUND 69 (2026-05-23) — hacker-audit VAULT-CRIT-3
        // (MEDIUM: vault filename leak via reply preview).
        //
        // The "📎 \(fileName)" branch below used to echo a vault
        // attachment's original filename ("passport_2024.pdf") into
        // the reply-quote bubble. Even with the round-19 / round-26
        // strip that prevents the preview from crossing the server /
        // mesh wire, it still showed up in the local chat surface
        // ABOVE the reply text — including in screenshots, app
        // switcher snapshots, and the recipient's own copy when
        // they later opened the conversation. (The recipient
        // reconstructs the preview locally; with this fix they
        // generate a generic "🔒 Vault attachment" instead.)
        //
        // Detect a vault attachment via the .vlt URL suffix, mirroring
        // `MessageService.forwardMessage`. Belt-and-suspenders also
        // check `allowForward == false` which the round-69
        // AttachmentService sets on every vault send.
        let isVaultAttachment =
            message.attachmentUrl?.lowercased().hasSuffix(".vlt") == true ||
            message.attachmentUrl?.lowercased().contains(".vlt?") == true ||
            message.allowForward == false
        if isVaultAttachment {
            return "🔒 Vault attachment"
        }

        switch message.type {
        case .text:
            // For text messages, use actual text (truncated) - but filter encrypted content
            guard let text = message.text, !text.isEmpty else { return nil }
            let nsRange = NSRange(location: 0, length: text.utf16.count)
            if text.hasPrefix("gAAAA") || text.hasPrefix("eyJ") ||
               (text.count > 100 && PerformanceConstants.base64Regex?.firstMatch(in: text, options: [], range: nsRange) != nil) {
                return "Message"
            }
            // Mistyped contact-card stored as text — see Conversation.preview.
            if ContactSharePayload.looksLikeContactCard(text) {
                return "👤 Shared contact"
            }
            return String(text.prefix(50))
        case .image:
            return "📷 Photo"
        case .video:
            return "🎬 Video"
        case .videoNote:
            return "🎥 Video note"
        case .ephemeralPhoto:
            return "📸 Snap Photo"
        case .voice:
            return "🎤 Voice message"
        case .file:
            // Use filename if available, otherwise generic label
            if let fileName = message.fileName {
                return "📎 \(fileName)"
            }
            return "📎 File"
        case .location:
            return "📍 Location"
        case .postShare:
            return "📬 Shared post"
        case .contactCard:
            return "👤 Shared contact"
        case .poll:
            return "📊 Poll"
        case .system:
            return "📢 Notification"
        }
    }

    nonisolated private func parseMessage(from row: [String: Any]) -> ChatMessage? {
        // Debug: check each required field
        let id = row["client_message_id"] as? String
        let roomIdFromRow = row["room_id"] as? String
        let senderId = row["sender_id"] as? String
        let recipientId = row["recipient_id"] as? String
        let timestampStr = row["timestamp"] as? String
        let timestamp = timestampStr.flatMap { SharedDateFormatters.parseISO8601($0) }
        let typeStr = row["type"] as? String
        let type: MessageType? = typeStr.map { MessageType.from(name: $0) }
        
        // DEBUG: Log which fields are missing
        if id == nil || roomIdFromRow == nil || senderId == nil || recipientId == nil || timestamp == nil || type == nil {
            logger.debug("parseMessage SKIPPING message due to missing fields: id=\(id ?? "NIL", privacy: .private) room=\(roomIdFromRow ?? "NIL", privacy: .private) sender=\(senderId ?? "NIL", privacy: .private) recipient=\(recipientId ?? "NIL", privacy: .private) ts=\(timestampStr ?? "NIL", privacy: .public) type=\(typeStr ?? "NIL", privacy: .public)")
            return nil
        }
        
        guard let id = id,
              let roomIdFromRow = roomIdFromRow,
              let senderId = senderId,
              let recipientId = recipientId,
              let timestamp = timestamp,
              let type = type else {
            return nil
        }
        
        let statusStr = row["status"] as? String ?? "pending"
        let status = MessageStatus(rawValue: statusStr) ?? .pending
        
        let authorityStr = row["delivery_authority"] as? String ?? "server"
        let authority = DeliveryAuthority(rawValue: authorityStr) ?? .server
        
        let syncStr = row["display_state"] as? String ?? "ready"
        let syncState: SyncState = {
            switch syncStr {
            case "uploading": return .uploading
            case "failed": return .failed
            default: return .synced
            }
        }()
        
        var msg = ChatMessage(
            id: id,
            serverId: row["server_id"] as? String,
            roomId: roomIdFromRow,
            senderId: senderId,
            senderName: row["sender_name"] as? String ?? "",
            recipientId: recipientId,
            text: sanitizeText(row["text"] as? String),
            timestamp: timestamp,
            type: type,
            status: status,
            deliveryAuthority: authority,
            createdAt: (row["created_at"] as? String).flatMap { SharedDateFormatters.parseISO8601($0) },
            deliveredAt: (row["delivered_at"] as? String).flatMap { SharedDateFormatters.parseISO8601($0) },
            readAt: (row["read_at"] as? String).flatMap { SharedDateFormatters.parseISO8601($0) },
            hopCount: (row["hop_count"] as? Int64).map { Int($0) } ?? 0,
            routePath: (row["route_path"] as? String)?.components(separatedBy: ",") ?? [],
            sprayCounter: (row["spray_counter"] as? Int64).map { Int($0) } ?? 5,
            hopLimit: (row["hop_limit"] as? Int64).map { Int($0) } ?? 10,
            originDeviceId: row["origin_device_id"] as? String ?? "",
            needsForwarding: (row["needs_forwarding"] as? Int64 ?? 0) == 1,
            attachmentUrl: row["remote_url"] as? String,
            thumbnailUrl: row["thumbnail_url"] as? String,
            fileName: row["file_name"] as? String,
            mimeType: row["mime_type"] as? String,
            fileSize: (row["file_size"] as? Int64).map { Int($0) },
            audioDurationSeconds: (row["audio_duration_seconds"] as? Int64).map { Int($0) },
            syncState: syncState,
            localPath: row["local_path"] as? String,
            uploadProgress: row["upload_progress"] as? Double,
            lastError: row["last_error"] as? String,
            replyToMessageId: row["reply_to_message_id"] as? String,
            replyToTextPreview: sanitizeReplyPreview(row["reply_to_text_preview"] as? String, type: row["reply_to_type"] as? String),
            replyToSenderName: row["reply_to_sender_name"] as? String,
            replyToType: (row["reply_to_type"] as? String).map { MessageType.from(name: $0) },
            sendMode: nil,
            scheduledAtUtc: nil
        )
        // Map edited_at from DB
        msg.editedAt = (row["edited_at"] as? String).flatMap { SharedDateFormatters.parseISO8601($0) }
        
        // Decode @mention entities from DB.
        // 🟡 BUG FIX (2026-05-10): reuse the cached decoder instead
        // of allocating a fresh one per row. On a 50-message page
        // hydration that's 50 throwaway decoder constructions.
        if let entitiesStr = row["entities_json"] as? String,
           let data = entitiesStr.data(using: .utf8) {
            msg.entities = try? Self.cachedJSONDecoder.decode([MentionEntity].self, from: data)
        }
        
        msg.forwardedFromChannelId = row["forwarded_from_channel"] as? String
        msg.forwardedFromChannelName = row["forwarded_from_channel_name"] as? String

        // 🔴 ROUND 26 — Telegram-style media albums.
        // Hydrate the three album-grouping columns. SQLite hands
        // INTEGER columns back as Int64, so we narrow to Int with
        // the same pattern the surrounding rows use.
        msg.albumGroupKey = row["media_group_key"] as? String
        msg.albumIndex = (row["media_group_index"] as? Int64).map { Int($0) }
        msg.albumTotal = (row["media_group_total"] as? Int64).map { Int($0) }

        return msg
    }
    
    // MARK: - Sanitize Text (Filter Encrypted Content)
    
    /// Filter out encrypted/base64 content from text field
    /// Returns nil for encrypted content so message displays as [no text]
    nonisolated private func sanitizeText(_ text: String?) -> String? {
        guard let text = text, !text.isEmpty else { return nil }
        
        // Filter encrypted patterns (Fernet encryption starts with gAAAA)
        if text.hasPrefix("gAAAA") { return nil }
        // Filter base64 JSON (JWT-like tokens start with eyJ)
        if text.hasPrefix("eyJ") { return nil }
        // Filter very long base64-like strings (>100 chars of alphanumeric+special)
        let nsRange = NSRange(location: 0, length: text.utf16.count)
        if text.count > 100 && PerformanceConstants.base64Regex?.firstMatch(in: text, options: [], range: nsRange) != nil {
            return nil
        }
        
        return text
    }
    
    /// Sanitize reply preview text - filter encrypted content and provide fallback
    /// This ensures Reply UI never shows raw encrypted payloads like "gAAAAA..."
    nonisolated private func sanitizeReplyPreview(_ text: String?, type: String?) -> String? {
        guard let text = text, !text.isEmpty else { return nil }
        
        // Check if text looks encrypted (Fernet, JWT, or long base64)
        let nsRange = NSRange(location: 0, length: text.utf16.count)
        let isEncrypted = text.hasPrefix("gAAAA") ||
                          text.hasPrefix("eyJ") ||
                          (text.count > 100 && PerformanceConstants.base64Regex?.firstMatch(in: text, options: [], range: nsRange) != nil)
        
        if isEncrypted {
            // Return type-appropriate fallback instead of encrypted blob
            switch type {
            case "voice": return "🎤 Voice message"
            case "image": return "📷 Photo"
            case "file": return "📎 File"
            case "location": return "📍 Location"
            case "post_share": return "📬 Shared post"
            default: return "Message"  // Generic fallback for text
            }
        }
        
        return text
    }
}

// MARK: - Response Types

// Server response for messages (matches backend MessageResponse)
struct APIMessageResponse: Decodable {
    let id: String
    let senderId: String
    let recipientId: String
    let content: String?
    let timestamp: Date
    let readAt: Date?
    let deliveredAt: Date?
    let isDuplicate: Bool?
    let senderUsername: String?
    let senderName: String?
    let audioUrl: String?
    let mediaUrl: String?
    let fileUrl: String?
    let imageUrl: String?
    let voiceUrl: String?
    let messageType: String?
    // Voice duration
    let audioDurationSeconds: Int?
    let audioDuration: Int?
    // Reply fields
    let replyToMessageId: String?
    let replyToTextPreview: String?
    let replyToSenderName: String?
    let replyToType: String?
    // File metadata
    let fileName: String?
    let fileSize: Int?
    let mimeType: String?
    // Scheduled fields
    let sendMode: String?
    let scheduledAtUtc: Date?
    
    // Convert to ChatMessage
    func toChatMessage(roomId: String) -> ChatMessage {
        let msgType = MessageType.from(name: messageType ?? "text")
        
        // Resolve media URL from whichever key the server provided
        var resolvedUrl = audioUrl ?? mediaUrl ?? fileUrl ?? imageUrl ?? voiceUrl
        
        // 🔴 SECURITY FIX (2026-05-16 — round 11): the previous
        // version printed the raw `content` field (up to 80 chars)
        // to Console.app, which leaks message bodies + voice-URL
        // tokens to anyone with access to the device logs. We now
        // log only NIL/NON-NIL presence, never the value itself.
        if msgType == .voice {
            #if DEBUG
            print("[APIMsg.toChatMessage] VOICE msg id=\(id.prefix(8))")
            print("   audioUrl: \(audioUrl == nil ? "nil" : "present(\(audioUrl?.count ?? 0)b)")")
            print("   mediaUrl: \(mediaUrl == nil ? "nil" : "present(\(mediaUrl?.count ?? 0)b)")")
            print("   fileUrl: \(fileUrl == nil ? "nil" : "present(\(fileUrl?.count ?? 0)b)")")
            print("   imageUrl: \(imageUrl == nil ? "nil" : "present(\(imageUrl?.count ?? 0)b)")")
            print("   voiceUrl: \(voiceUrl == nil ? "nil" : "present(\(voiceUrl?.count ?? 0)b)")")
            print("   content: \(content == nil ? "nil" : "present(\(content?.count ?? 0)b)")")
            print("   → resolvedUrl: \(resolvedUrl == nil ? "nil" : "present")")
            #endif
        }
        
        // Voice messages: server may send audio URL in content field instead of dedicated URL field
        if resolvedUrl == nil && msgType == .voice,
           let c = content, !c.isEmpty,
           (c.hasPrefix("http") || c.hasPrefix("/uploads/") || c.hasPrefix("/api/uploads/")) {
            resolvedUrl = c
        }
        
        let status: MessageStatus = readAt != nil ? .read : (deliveredAt != nil ? .delivered : .sent)
        

        
        return ChatMessage(
            id: id,
            serverId: id,
            roomId: roomId,
            senderId: senderId,
            senderName: senderName ?? senderUsername ?? "",
            recipientId: recipientId,
            text: content,
            timestamp: timestamp,
            type: msgType,
            status: status,
            deliveryAuthority: .server,
            createdAt: timestamp,
            deliveredAt: deliveredAt,
            readAt: readAt,
            hopCount: 0,
            routePath: [],
            sprayCounter: PremiumLimits.meshSprayBudget,
            hopLimit: PremiumLimits.meshHopLimit,
            originDeviceId: DeviceIdentityService.shared.fingerprint ?? "",
            needsForwarding: msgType == .text || msgType == .location || msgType == .system,
            attachmentUrl: resolvedUrl,
            thumbnailUrl: nil,
            fileName: fileName,
            mimeType: mimeType,
            fileSize: fileSize,
            audioDurationSeconds: audioDurationSeconds ?? audioDuration,
            syncState: .synced,
            localPath: nil,
            uploadProgress: nil,
            lastError: nil,
            replyToMessageId: replyToMessageId,
            replyToTextPreview: sanitizedReplyPreview,
            replyToSenderName: replyToSenderName,
            replyToType: replyToType.map { MessageType.from(name: $0) },
            sendMode: sendMode,
            scheduledAtUtc: scheduledAtUtc
        )
    }
    
    /// Sanitize reply preview text - filter encrypted content and provide fallback
    private var sanitizedReplyPreview: String? {
        guard let text = replyToTextPreview, !text.isEmpty else { return nil }
        
        // Check if text looks encrypted (Fernet, JWT, or long base64)
        let nsRange = NSRange(location: 0, length: text.utf16.count)
        let isEncrypted = text.hasPrefix("gAAAA") ||
                          text.hasPrefix("eyJ") ||
                          (text.count > 100 && PerformanceConstants.base64Regex?.firstMatch(in: text, options: [], range: nsRange) != nil)
        
        if isEncrypted {
            // Return type-appropriate fallback instead of encrypted blob
            switch replyToType {
            case "voice": return "🎤 Voice message"
            case "image": return "📷 Photo"
            case "file": return "📎 File"
            case "location": return "📍 Location"
            case "post_share": return "📬 Shared post"
            default: return "Message"  // Generic fallback for text
            }
        }
        
        return text
    }
}

// Server returns array directly
typealias MessageFetchResponse = [APIMessageResponse]

// MARK: - Per-thread disappearing-message default
//
// The chat composer exposes a small Liquid Glass picker that toggles a
// disappearing-message mode on for the whole conversation. The selection
// is local to the device — each user picks their own outgoing-message TTL
// (mirrors WhatsApp/Signal's "default disappearing for this chat" model).
//
// Stored as a single ExpiryMode raw-value string in UserDefaults under a
// key derived from the room id. Returns nil when the user hasn't enabled
// it for this thread.
enum ChatExpirySettings {
    private static func key(forRoom roomId: String) -> String {
        "chat.expiry.\(roomId)"
    }

    static func mode(forRoom roomId: String) -> ExpiryMode? {
        guard let raw = UserDefaults.standard.string(forKey: key(forRoom: roomId)) else { return nil }
        return ExpiryMode(rawValue: raw)
    }

    static func setMode(_ mode: ExpiryMode?, forRoom roomId: String) {
        let k = key(forRoom: roomId)
        if let mode {
            UserDefaults.standard.set(mode.rawValue, forKey: k)
        } else {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }
}

struct SendMessageRequest: Encodable {
    let messageId: String
    let recipientId: String
    let content: String  // Required by server, empty string for non-text messages
    let messageType: String
    var audioUrl: String? = nil
    var audioDurationSeconds: Int? = nil
    var replyToMessageId: String? = nil
    // File attachment metadata
    var fileName: String? = nil
    var fileSize: Int? = nil
    var mimeType: String? = nil
    /// Disappearing-messages mode for this single send. Server-side values:
    /// "deleteAfterRead" | "deleteAfter24h" | "deleteAfter7d" |
    /// "deleteIfScreenshot" | "deleteIfForwarded". Pass nil for "off".
    var expiryMode: String? = nil
    /// "instant" (default) or "scheduled". When "scheduled", the server
    /// stores the message but defers delivery until the background
    /// worker flips it at `scheduled_at_utc`.
    var sendMode: String? = nil
    var scheduledAtUtc: Date? = nil
    /// 🔴 ROUND 26 — Telegram-style album grouping fields. The
    /// picker stamps a shared UUID into `mediaGroupKey` across N
    /// items; the server stores them as siblings and the receiver
    /// renders them as one grouped bubble.
    var mediaGroupKey: String? = nil
    var mediaGroupIndex: Int? = nil
    var mediaGroupTotal: Int? = nil
}

struct SendMessageResponse: Decodable {
    let id: String
    // 🔴 ROUND 22 — LIVE-TEST BUG.
    //
    // `timestamp` used to be `Date?` and decoded via the custom
    // date-parser configured on NetworkService's JSONDecoder.
    // When the server's reply included a `timestamp` field in a
    // format the parser didn't recognize (e.g. a UNIX numeric
    // epoch instead of an ISO-8601 string), the whole response
    // decode threw — even though `timestamp` was optional —
    // surfacing as "Error: cannot parse response" on every
    // image / file / scheduled send.
    //
    // Nothing in the client actually consumes this field. Dropping
    // it makes the response shape robust against any server-side
    // change to the timestamp format.
    let status: String?
    let recipientDelivered: Bool?
    let recipientOnline: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case recipientDelivered = "recipient_delivered"
        case recipientOnline = "recipient_online"
    }
}

// MARK: - Group Message Models

struct SendGroupMessageRequest: Encodable {
    let messageId: String
    let content: String
    let messageType: String
    var audioUrl: String? = nil
    var audioDurationSeconds: Int? = nil
    var fileName: String? = nil
    var fileSize: Int? = nil
    var mimeType: String? = nil
    var replyToMessageId: String? = nil
    var replyToTextPreview: String? = nil
    var replyToSenderName: String? = nil
    var replyToType: String? = nil
    var entities: [MentionEntity]? = nil  // Structured @mention entities
    /// 🔴 ROUND 26 — group album passthrough.
    var mediaGroupKey: String? = nil
    var mediaGroupIndex: Int? = nil
    var mediaGroupTotal: Int? = nil
    /// 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — group key version.
    /// When set, `content` is the AES-GCM ciphertext encrypted under
    /// the group's symmetric key at this version. Server stores +
    /// fans this through unchanged so receivers can decrypt locally.
    /// Pre-fix the online group-send path shipped PLAINTEXT to the
    /// server (matching the user's "bridge sees nothing" directive
    /// violation): server saw cleartext, bridge saw cleartext.
    var groupKeyVersion: Int? = nil
}

struct GroupMessageResponse: Decodable {
    let id: String
    let groupId: String
    let senderId: String
    let senderName: String
    let senderAvatar: String?
    let content: String
    let timestamp: Date
    let messageType: String?
    let audioUrl: String?
    let mediaUrl: String?
    let fileUrl: String?
    let imageUrl: String?
    let voiceUrl: String?
    let audioDurationSeconds: Int?
    let audioDuration: Int?
    let fileName: String?
    let fileSize: Int?
    let mimeType: String?
    let replyToMessageId: String?
    let replyToTextPreview: String?
    let replyToSenderName: String?
    let replyToType: String?
    let entities: String?  // JSON string of mention entities
    /// When `messageType == "poll"`, the GroupPoll row id this message
    /// announces. Clients use it to load the live tally + cast votes.
    let pollId: String?
    let isDuplicate: Bool?
    let status: String?
    // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — server-shipped
    // group-AES-GCM key version so the receiver can decrypt the
    // opaque ciphertext sitting in `content`. Pre-fix this field
    // was missing from the decoder, so REST-fetched group history
    // (offline reconcile, scrollback) rendered raw base64 instead
    // of the decrypted text. WS push + bridge push handlers already
    // honour groupKeyVersion via ChatMessage; this is the REST
    // fetch parity fix.
    let groupKeyVersion: Int?
}

// PendingSyncManager REMOVED — OutboxManager handles pending message sync on network reconnect.
// Having both caused duplicate POST requests (race condition) and 429 Rate Limit errors.
