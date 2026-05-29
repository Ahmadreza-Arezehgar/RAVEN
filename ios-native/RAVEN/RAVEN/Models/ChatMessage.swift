import Foundation

// MARK: - Enums

enum MessageType: String, Codable {
    case text
    case image
    case video
    case file
    case voice
    case location
    case poll              // Group poll announcement — pairs with `pollId`
    case postShare = "post_share"
    case contactCard = "contact_card"  // Shared Raven friend's profile (postcard with avatar + name + QR)
    case videoNote = "video_note"
    case ephemeralPhoto = "ephemeral_photo"
    case system          // System notifications (screenshot alerts, user actions, etc.)
}

enum MessageStatus: String, Codable {
    case pending       // Queued locally
    case sending       // Upload/send in progress
    case forwarding    // Mesh relay in progress (NEW for DTN)
    case accepted      // Server accepted message (NEW - from server API)
    case sent          // Server confirmed receipt
    case delivered     // Recipient device received
    case read          // Recipient opened chat
    case failed        // Delivery failed
    case scheduled     // Waiting for scheduled time
}

enum DeliveryAuthority: String, Codable {
    case unknown // Not yet routed
    case server  // Blue indicator 🔵
    case mesh    // Purple indicator 🟣
    
    var color: String {
        switch self {
        case .unknown: return "gray"
        case .server: return "blue"
        case .mesh: return "purple"
        }
    }
}

enum SyncState: String, Codable {
    case localOnly   // Never synced to server
    case queued      // Waiting to sync
    case uploading   // Sync in progress
    case synced      // Successfully synced
    case failed      // Sync failed, retry needed
}

enum ExpiryMode: String, Codable {
    case none
    case deleteAfterRead
    case deleteAfter24h
    case deleteAfter7d
    case deleteIfScreenshot
    case deleteIfForwarded
    
    var icon: String {
        switch self {
        case .none: return ""
        case .deleteAfterRead: return "eye.slash"
        case .deleteAfter24h, .deleteAfter7d: return "timer"
        case .deleteIfScreenshot: return "camera.viewfinder"
        case .deleteIfForwarded: return "lock.shield"
        }
    }
    
    var label: String {
        switch self {
        case .none: return "Normal"
        case .deleteAfterRead: return "Delete after read"
        case .deleteAfter24h: return "Delete after 24h"
        case .deleteAfter7d: return "Delete after 7 days"
        case .deleteIfScreenshot: return "Delete if screenshot"
        case .deleteIfForwarded: return "No forwarding"
        }
    }
}

// MARK: - Mention Entity

/// Structured @mention entity stored alongside message text
struct MentionEntity: Codable, Hashable, Identifiable {
    let type: String // always "mention"
    let userId: String
    let username: String
    let rangeStart: Int
    let rangeLength: Int
    
    var id: String { "\(userId)-\(rangeStart)" }
}

// MARK: - Chat Message Model

struct ChatMessage: Identifiable, Codable {
    let id: String  // This is client_message_id (UUID generated locally) — NEVER CHANGES
    var serverId: String?  // Server-assigned ID after confirmation
    var roomId: String?  // Optional - not always returned by server inbox API
    let senderId: String
    let senderName: String
    let recipientId: String
    var text: String?  // Optional for media (var for edit support)
    let timestamp: Date
    let type: MessageType
    var status: MessageStatus
    var deliveryAuthority: DeliveryAuthority
    
    // Timestamps
    let createdAt: Date?
    var deliveredAt: Date?
    var readAt: Date?
    var editedAt: Date?
    
    // MARK: - DTN/Mesh Fields (Required for routing)
    var hopCount: Int
    var routePath: [String]
    var sprayCounter: Int          // Copies remaining (starts at 5)
    var hopLimit: Int              // Max hops allowed (default 10)
    var originDeviceId: String     // Device that created the message
    var needsForwarding: Bool      // Should this be relayed?
    
    // Media
    var attachmentUrl: String?
    var thumbnailUrl: String?
    let fileName: String?
    let mimeType: String?
    let fileSize: Int?
    let audioDurationSeconds: Int?
    
    // Sync state
    var syncState: SyncState
    var localPath: String?
    var uploadProgress: Double?
    var lastError: String?
    
    // Reply
    let replyToMessageId: String?
    let replyToTextPreview: String?
    let replyToSenderName: String?
    let replyToType: MessageType?
    
    // Scheduled
    let sendMode: String?
    let scheduledAtUtc: Date?
    
    // Deletion tracking
    var isDeletedForMe: Bool
    var isDeletedGlobally: Bool
    
    // Smart Message Expiry
    var expiryMode: ExpiryMode?
    var expiresAt: Date?
    var allowForward: Bool
    
    // Mention entities
    var entities: [MentionEntity]?
    
    // Video Note / Clip Chain
    var clipId: String?
    var parentClipId: String?
    var chainId: String?
    
    // Forwarding
    var forwardedFromChannelId: String?
    var forwardedFromChannelName: String?
    
    // Ephemeral Photo (Snap)
    var snapId: String?
    var ttlSeconds: Int?
    var ephemeralStatus: String?  // sent/delivered/opened/expired
    
    // Vault Lock (location-encrypted messages)
    var vaultLock: VaultLock?

    // Poll (group chat only) — set when `type == .poll`. Clients fetch the
    // live tally + cast votes via /api/groups/{group_id}/polls/{poll_id}.
    var pollId: String? = nil

    /// Round 21 (2026-05-16) — hacker-audit Bridge F1 follow-up.
    /// Set when a bridged group message arrives carrying the AES-GCM
    /// ciphertext that the bridge node refused to decrypt. The
    /// receive path runs `GroupKeyService.decrypt(..., version:)` on
    /// `text` when this is non-nil; legacy bridges (round ≤20) that
    /// already decrypt before upload leave this nil, so the existing
    /// "treat content as plaintext" behaviour is preserved for them.
    var groupKeyVersion: Int? = nil

    // MARK: - Album / Media Group (round 26 — Telegram-style)
    //
    // When the user multi-selects photos+videos in the picker and
    // hits "Send N items", each item is sent as its own ChatMessage
    // row (so each gets its own encryption envelope, upload progress,
    // server id, ACK lifecycle — none of that has to change). The
    // three fields below glue them back together at render time:
    //
    //   • `albumGroupKey`  — opaque UUID shared by every item in
    //     the same picker-batch. Two messages with the same key in
    //     the same room render as ONE grouped bubble.
    //   • `albumIndex`     — 0-based position within the album.
    //     Picker preserves selection order, so this is what the grid
    //     iterates by.
    //   • `albumTotal`     — total item count in the album, stamped
    //     by the sender so the receiver can render a "+N" overlay or
    //     a "waiting for sibling N/M" placeholder when one ChatMessage
    //     in the group arrives before the others.
    //
    // All three are server-roundtripped via `media_group_key` /
    // `media_group_index` / `media_group_total` (snake_case decoded
    // automatically by NetworkService). Nil for a regular single
    // media message — chat surface falls back to the existing
    // `ImageMessageView` / `FileMessageView` render in that case.
    var albumGroupKey: String? = nil
    var albumIndex: Int? = nil
    var albumTotal: Int? = nil

    // MARK: - CodingKeys (Handle snake_case from server)
    
    // NOTE: NetworkService uses .convertFromSnakeCase decoder strategy,
    // so we don't need explicit "snake_case" mappings - they cause conflicts!
    // Only map keys that need special handling (like 'content' alias for 'text')
    enum CodingKeys: String, CodingKey {
        case id
        case serverId
        case roomId
        case senderId
        case senderName
        case recipientId
        case text
        case timestamp
        case type
        case status
        case deliveryAuthority
        case createdAt
        case deliveredAt
        case readAt
        case hopCount
        case routePath
        case sprayCounter
        case hopLimit
        case originDeviceId
        case needsForwarding
        case attachmentUrl
        case thumbnailUrl
        case fileName
        case mimeType
        case fileSize
        case audioDurationSeconds
        case syncState
        case localPath
        case uploadProgress
        case lastError
        case replyToMessageId
        case replyToTextPreview
        case replyToSenderName
        case replyToType
        case sendMode
        case scheduledAtUtc
        case isDeletedForMe
        case isDeletedGlobally
        // Smart Message Expiry
        case expiryMode
        case expiresAt
        case allowForward
        case entities
        case editedAt
        // Video Note / Clip Chain
        case clipId
        case parentClipId
        case chainId
        // Forwarding — the explicit raw value `forwarded_from_channel`
        // is needed because the server's field name is shorter than
        // the Swift property `forwardedFromChannelId` would suggest
        // after `convertFromSnakeCase`. Tested 2026-05-10: with the
        // explicit raw value present, the decoder matches the JSON
        // BEFORE applying the snake_case strategy, so the binding
        // works. Removing the raw value would break it.
        case forwardedFromChannelId = "forwarded_from_channel"
        case forwardedFromChannelName = "forwarded_from_channel_name"
        // Ephemeral Photo (Snap)
        case snapId
        case ttlSeconds
        case ephemeralStatus
        // Vault
        case vaultLock
        // Round 21 — Bridge F1: opaque group ciphertext carries
        // the version index the recipient needs to decrypt.
        case groupKeyVersion
        // Round 26 — Telegram-style album grouping. Server emits
        // snake_case `media_group_key` / `media_group_index` /
        // `media_group_total`; NetworkService's convertFromSnakeCase
        // decoder maps them automatically.
        case albumGroupKey = "media_group_key"
        case albumIndex = "media_group_index"
        case albumTotal = "media_group_total"
        // Extra keys only used for decoding (server variations)
        case content
        case messageType
        case audioUrl  // Server sends audio_url for voice messages
        case mediaUrl  // Server may send media_url
        case fileUrl   // Server may send file_url
        case imageUrl  // Server may send image_url
        case voiceUrl  // Server may send voice_url
        case audioDuration // Server may send audio_duration
    }
    
    // MARK: - Custom Encode (skip content/messageType since they're decode-only)
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(serverId, forKey: .serverId)
        try container.encodeIfPresent(roomId, forKey: .roomId)
        try container.encode(senderId, forKey: .senderId)
        try container.encode(senderName, forKey: .senderName)
        try container.encode(recipientId, forKey: .recipientId)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(type, forKey: .type)
        try container.encode(status, forKey: .status)
        try container.encode(deliveryAuthority, forKey: .deliveryAuthority)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(deliveredAt, forKey: .deliveredAt)
        try container.encodeIfPresent(readAt, forKey: .readAt)
        try container.encode(hopCount, forKey: .hopCount)
        try container.encode(routePath, forKey: .routePath)
        try container.encode(sprayCounter, forKey: .sprayCounter)
        try container.encode(hopLimit, forKey: .hopLimit)
        try container.encode(originDeviceId, forKey: .originDeviceId)
        try container.encode(needsForwarding, forKey: .needsForwarding)
        try container.encodeIfPresent(attachmentUrl, forKey: .attachmentUrl)
        try container.encodeIfPresent(thumbnailUrl, forKey: .thumbnailUrl)
        try container.encodeIfPresent(fileName, forKey: .fileName)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(fileSize, forKey: .fileSize)
        try container.encodeIfPresent(audioDurationSeconds, forKey: .audioDurationSeconds)
        try container.encode(syncState, forKey: .syncState)
        try container.encodeIfPresent(localPath, forKey: .localPath)
        try container.encodeIfPresent(uploadProgress, forKey: .uploadProgress)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encodeIfPresent(replyToMessageId, forKey: .replyToMessageId)
        try container.encodeIfPresent(replyToTextPreview, forKey: .replyToTextPreview)
        try container.encodeIfPresent(replyToSenderName, forKey: .replyToSenderName)
        try container.encodeIfPresent(replyToType, forKey: .replyToType)
        try container.encodeIfPresent(sendMode, forKey: .sendMode)
        try container.encodeIfPresent(scheduledAtUtc, forKey: .scheduledAtUtc)
        try container.encode(isDeletedForMe, forKey: .isDeletedForMe)
        try container.encode(isDeletedGlobally, forKey: .isDeletedGlobally)
        // Smart Message Expiry
        try container.encodeIfPresent(expiryMode, forKey: .expiryMode)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encode(allowForward, forKey: .allowForward)
        try container.encodeIfPresent(entities, forKey: .entities)
        try container.encodeIfPresent(editedAt, forKey: .editedAt)
        // Video Note / Clip Chain
        try container.encodeIfPresent(clipId, forKey: .clipId)
        try container.encodeIfPresent(parentClipId, forKey: .parentClipId)
        try container.encodeIfPresent(chainId, forKey: .chainId)
        // Forwarding
        try container.encodeIfPresent(forwardedFromChannelId, forKey: .forwardedFromChannelId)
        try container.encodeIfPresent(forwardedFromChannelName, forKey: .forwardedFromChannelName)
        // Ephemeral Photo (Snap)
        try container.encodeIfPresent(snapId, forKey: .snapId)
        try container.encodeIfPresent(ttlSeconds, forKey: .ttlSeconds)
        try container.encodeIfPresent(ephemeralStatus, forKey: .ephemeralStatus)
        // Vault
        try container.encodeIfPresent(vaultLock, forKey: .vaultLock)
        // Round 26 — Telegram-style album grouping (nil for single-
        // media messages and back-compat with pre-round-26 clients).
        try container.encodeIfPresent(albumGroupKey, forKey: .albumGroupKey)
        try container.encodeIfPresent(albumIndex, forKey: .albumIndex)
        try container.encodeIfPresent(albumTotal, forKey: .albumTotal)
    }

    // MARK: - Custom Decoder (Handle missing/optional fields)
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Required fields
        id = try container.decode(String.self, forKey: .id)
        senderId = try container.decodeIfPresent(String.self, forKey: .senderId) ?? ""
        recipientId = try container.decodeIfPresent(String.self, forKey: .recipientId) ?? ""
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        
        // Optional with defaults
        serverId = try container.decodeIfPresent(String.self, forKey: .serverId)
        roomId = try container.decodeIfPresent(String.self, forKey: .roomId)
        senderName = try container.decodeIfPresent(String.self, forKey: .senderName) ?? ""
        
        // Text may come as "text" or "content"
        text = try container.decodeIfPresent(String.self, forKey: .text) 
            ?? container.decodeIfPresent(String.self, forKey: .content)
        
        // Type may come as "type" or "message_type", default to .text
        if let typeValue = try? container.decode(MessageType.self, forKey: .type) {
            type = typeValue
        } else if let msgTypeStr = try? container.decodeIfPresent(String.self, forKey: .messageType) {
            type = MessageType.from(name: msgTypeStr)
        } else if let typeStr = try? container.decodeIfPresent(String.self, forKey: .type) {
            type = MessageType.from(name: typeStr)
        } else {
            type = .text  // Default to text
        }
        
        status = try container.decodeIfPresent(MessageStatus.self, forKey: .status) ?? .sent
        deliveryAuthority = try container.decodeIfPresent(DeliveryAuthority.self, forKey: .deliveryAuthority) ?? .server
        
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        deliveredAt = try container.decodeIfPresent(Date.self, forKey: .deliveredAt)
        readAt = try container.decodeIfPresent(Date.self, forKey: .readAt)
        editedAt = try container.decodeIfPresent(Date.self, forKey: .editedAt)
        
        // DTN fields with defaults
        hopCount = try container.decodeIfPresent(Int.self, forKey: .hopCount) ?? 0
        routePath = try container.decodeIfPresent([String].self, forKey: .routePath) ?? []
        sprayCounter = try container.decodeIfPresent(Int.self, forKey: .sprayCounter) ?? PremiumLimits.meshSprayBudget
        hopLimit = try container.decodeIfPresent(Int.self, forKey: .hopLimit) ?? PremiumLimits.meshHopLimit
        originDeviceId = try container.decodeIfPresent(String.self, forKey: .originDeviceId) ?? ""
        needsForwarding = try container.decodeIfPresent(Bool.self, forKey: .needsForwarding) ?? false
        
        // Media fields — coalesce all possible URL keys from server
        let urlFromAttachment = try container.decodeIfPresent(String.self, forKey: .attachmentUrl)
        let urlFromAudio = try container.decodeIfPresent(String.self, forKey: .audioUrl)
        let urlFromMedia = try container.decodeIfPresent(String.self, forKey: .mediaUrl)
        let urlFromFile = try container.decodeIfPresent(String.self, forKey: .fileUrl)
        let urlFromImage = try container.decodeIfPresent(String.self, forKey: .imageUrl)
        let urlFromVoice = try container.decodeIfPresent(String.self, forKey: .voiceUrl)
        attachmentUrl = urlFromAttachment ?? urlFromAudio ?? urlFromMedia ?? urlFromFile ?? urlFromImage ?? urlFromVoice
        
        // DEBUG: Log all URL fields for voice messages
        if type == .voice {
            #if DEBUG
            print("🎤 [ChatMessage.decode] VOICE msg id=\(id.prefix(8))")
            print("   attachmentUrl: \(urlFromAttachment ?? "nil")")
            print("   audioUrl: \(urlFromAudio ?? "nil")")  
            print("   mediaUrl: \(urlFromMedia ?? "nil")")
            print("   fileUrl: \(urlFromFile ?? "nil")")
            print("   imageUrl: \(urlFromImage ?? "nil")")
            print("   voiceUrl: \(urlFromVoice ?? "nil")")
            print("   → resolved attachmentUrl: \(attachmentUrl ?? "nil")")
            #endif
            let rawText = try? container.decodeIfPresent(String.self, forKey: .text)
            let rawContent = try? container.decodeIfPresent(String.self, forKey: .content)
            #if DEBUG
            print("   text: \(rawText?.prefix(80) ?? "nil")")
            print("   content: \(rawContent?.prefix(80) ?? "nil")")
            #endif
        }
        
        // Voice messages: server may send audio URL in content field instead of dedicated URL field
        if attachmentUrl == nil && type == .voice {
            let textContent = try container.decodeIfPresent(String.self, forKey: .text)
                           ?? container.decodeIfPresent(String.self, forKey: .content)
            if let tc = textContent, !tc.isEmpty,
               (tc.hasPrefix("http") || tc.hasPrefix("/uploads/") || tc.hasPrefix("/api/uploads/")) {
                attachmentUrl = tc
            }
        }
        
        thumbnailUrl = try container.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        fileSize = try container.decodeIfPresent(Int.self, forKey: .fileSize)
        let durationFromSeconds = try container.decodeIfPresent(Int.self, forKey: .audioDurationSeconds)
        let durationFromDuration = try container.decodeIfPresent(Int.self, forKey: .audioDuration)
        audioDurationSeconds = durationFromSeconds ?? durationFromDuration
        
        // Sync state
        syncState = try container.decodeIfPresent(SyncState.self, forKey: .syncState) ?? .synced
        localPath = try container.decodeIfPresent(String.self, forKey: .localPath)
        uploadProgress = try container.decodeIfPresent(Double.self, forKey: .uploadProgress)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        
        // Reply fields
        replyToMessageId = try container.decodeIfPresent(String.self, forKey: .replyToMessageId)
        replyToTextPreview = try container.decodeIfPresent(String.self, forKey: .replyToTextPreview)
        replyToSenderName = try container.decodeIfPresent(String.self, forKey: .replyToSenderName)
        replyToType = try container.decodeIfPresent(MessageType.self, forKey: .replyToType)
        
        // Scheduled
        sendMode = try container.decodeIfPresent(String.self, forKey: .sendMode)
        scheduledAtUtc = try container.decodeIfPresent(Date.self, forKey: .scheduledAtUtc)
        
        // Deletion tracking
        isDeletedForMe = try container.decodeIfPresent(Bool.self, forKey: .isDeletedForMe) ?? false
        isDeletedGlobally = try container.decodeIfPresent(Bool.self, forKey: .isDeletedGlobally) ?? false
        
        // Smart Message Expiry
        expiryMode = try container.decodeIfPresent(ExpiryMode.self, forKey: .expiryMode)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        allowForward = try container.decodeIfPresent(Bool.self, forKey: .allowForward) ?? true
        
        // Mention entities — may come as JSON string or array
        if let entitiesArray = try? container.decodeIfPresent([MentionEntity].self, forKey: .entities) {
            entities = entitiesArray
        } else if let entitiesString = try? container.decodeIfPresent(String.self, forKey: .entities),
                  let data = entitiesString.data(using: .utf8) {
            entities = try? JSONDecoder().decode([MentionEntity].self, from: data)
        } else {
            entities = nil
        }
        
        // Video Note / Clip Chain
        clipId = try container.decodeIfPresent(String.self, forKey: .clipId)
        parentClipId = try container.decodeIfPresent(String.self, forKey: .parentClipId)
        chainId = try container.decodeIfPresent(String.self, forKey: .chainId)
        
        // Forwarding
        forwardedFromChannelId = try container.decodeIfPresent(String.self, forKey: .forwardedFromChannelId)
        forwardedFromChannelName = try container.decodeIfPresent(String.self, forKey: .forwardedFromChannelName)
        
        // Ephemeral Photo (Snap)
        snapId = try container.decodeIfPresent(String.self, forKey: .snapId)
        ttlSeconds = try container.decodeIfPresent(Int.self, forKey: .ttlSeconds)
        ephemeralStatus = try container.decodeIfPresent(String.self, forKey: .ephemeralStatus)
        
        // Vault
        vaultLock = try container.decodeIfPresent(VaultLock.self, forKey: .vaultLock)
        // Round 26 — Telegram-style album grouping.
        albumGroupKey = try container.decodeIfPresent(String.self, forKey: .albumGroupKey)
        albumIndex = try container.decodeIfPresent(Int.self, forKey: .albumIndex)
        albumTotal = try container.decodeIfPresent(Int.self, forKey: .albumTotal)
    }
    
    // MARK: - Memberwise Initializer (Required since we have custom Decodable init)
    
    init(
        id: String,
        serverId: String?,
        roomId: String?,
        senderId: String,
        senderName: String,
        recipientId: String,
        text: String?,
        timestamp: Date,
        type: MessageType,
        status: MessageStatus,
        deliveryAuthority: DeliveryAuthority,
        createdAt: Date?,
        deliveredAt: Date?,
        readAt: Date?,
        hopCount: Int,
        routePath: [String],
        sprayCounter: Int,
        hopLimit: Int,
        originDeviceId: String,
        needsForwarding: Bool,
        attachmentUrl: String?,
        thumbnailUrl: String?,
        fileName: String?,
        mimeType: String?,
        fileSize: Int?,
        audioDurationSeconds: Int?,
        syncState: SyncState,
        localPath: String?,
        uploadProgress: Double?,
        lastError: String?,
        replyToMessageId: String?,
        replyToTextPreview: String?,
        replyToSenderName: String?,
        replyToType: MessageType?,
        sendMode: String?,
        scheduledAtUtc: Date?,
        isDeletedForMe: Bool = false,
        isDeletedGlobally: Bool = false,
        expiryMode: ExpiryMode? = nil,
        expiresAt: Date? = nil,
        clipId: String? = nil,
        parentClipId: String? = nil,
        chainId: String? = nil,
        forwardedFromChannelId: String? = nil,
        forwardedFromChannelName: String? = nil,
        allowForward: Bool = true,
        snapId: String? = nil,
        ttlSeconds: Int? = nil,
        ephemeralStatus: String? = nil
    ) {
        self.id = id
        self.serverId = serverId
        self.roomId = roomId
        self.senderId = senderId
        self.senderName = senderName
        self.recipientId = recipientId
        self.text = text
        self.timestamp = timestamp
        self.type = type
        self.status = status
        self.deliveryAuthority = deliveryAuthority
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
        self.readAt = readAt
        self.editedAt = nil
        self.hopCount = hopCount
        self.routePath = routePath
        self.sprayCounter = sprayCounter
        self.hopLimit = hopLimit
        self.originDeviceId = originDeviceId
        self.needsForwarding = needsForwarding
        self.attachmentUrl = attachmentUrl
        self.thumbnailUrl = thumbnailUrl
        self.fileName = fileName
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.audioDurationSeconds = audioDurationSeconds
        self.syncState = syncState
        self.localPath = localPath
        self.uploadProgress = uploadProgress
        self.lastError = lastError
        self.replyToMessageId = replyToMessageId
        self.replyToTextPreview = replyToTextPreview
        self.replyToSenderName = replyToSenderName
        self.replyToType = replyToType
        self.sendMode = sendMode
        self.scheduledAtUtc = scheduledAtUtc
        self.isDeletedForMe = isDeletedForMe
        self.isDeletedGlobally = isDeletedGlobally
        self.expiryMode = expiryMode
        self.expiresAt = expiresAt
        self.allowForward = allowForward
        self.entities = nil
        self.clipId = clipId
        self.parentClipId = parentClipId
        self.chainId = chainId
        self.forwardedFromChannelId = forwardedFromChannelId
        self.forwardedFromChannelName = forwardedFromChannelName
        self.snapId = snapId
        self.ttlSeconds = ttlSeconds
        self.ephemeralStatus = ephemeralStatus
        self.vaultLock = nil
        self.pollId = nil
    }
    
    // MARK: - Display State (Computed)
    
    var currentDisplayState: DisplayState {
        switch type {
        case .text:
            guard let text = text, !text.isEmpty else {
                return .hidden
            }
            return .ready
            
        case .video, .videoNote, .ephemeralPhoto:
            return .hidden  // These features have been removed
            
        case .image, .file:
            switch syncState {
            case .synced:
                return .ready
            case .uploading:
                return .uploading
            case .failed:
                return .failed
            case .localOnly, .queued:
                return localPath != nil ? .uploading : .hidden
            }
            
        case .voice:
            guard attachmentUrl != nil || localPath != nil else {
                return .hidden
            }
            return syncState == .synced ? .ready : .uploading
            
        case .location:
            return .ready
            
        case .postShare:
            // PostShare is ready if text (payload JSON) exists
            guard let text = text, !text.isEmpty else {
                return .hidden
            }
            return .ready

        case .contactCard:
            // Same shape as postShare — text holds the JSON payload.
            guard let text = text, !text.isEmpty else {
                return .hidden
            }
            return .ready

        case .poll:
            // Poll bubbles fetch their own data — always ready to render.
            return .ready

        case .system:
            return .ready  // System messages always display
        }
    }

    // MARK: - Validation

    var isValid: Bool {
        switch type {
        case .text:
            return text != nil && !(text?.isEmpty ?? true)
        case .video, .videoNote, .ephemeralPhoto:
            return false  // These features have been removed
        case .image, .file:
            return attachmentUrl != nil || localPath != nil
        case .voice:
            return (attachmentUrl != nil || localPath != nil)
        case .location:
            return true
        case .postShare:
            // PostShare is valid if text (payload JSON) exists
            return text != nil && !(text?.isEmpty ?? true)
        case .contactCard:
            return text != nil && !(text?.isEmpty ?? true)
        case .poll:
            // Valid as soon as the announcement message itself exists; the
            // PollBubbleView handles its own fetch errors.
            return true
        case .system:
            return text != nil && !(text?.isEmpty ?? true)
        }
    }
    
    var shouldDisplay: Bool {
        currentDisplayState != .hidden
    }
    
    // MARK: - Helpers
    
    var isFromMe: Bool {
        // Set dynamically when rendering
        false
    }
    
    var bubbleColor: String {
        deliveryAuthority.color
    }
    
    // MARK: - Safe Display Text (Golden Rule: UI never shows encrypted payload)
    
    /// Generate a safe snippet for when THIS message is being replied to
    /// Use this when the user taps "Reply" on a message
    var safeReplySnippet: String {
        // DEBUG: Log all message fields to find encrypted content source
        #if DEBUG
        print("🔍 [REPLY_SNIPPET] Creating snippet for message:")
        print("🔍 [REPLY_SNIPPET]   type=\(type.rawValue)")
        print("🔍 [REPLY_SNIPPET]   text=\(text?.prefix(50) ?? "nil")...")
        print("🔍 [REPLY_SNIPPET]   fileName=\(fileName ?? "nil")")
        print("🔍 [REPLY_SNIPPET]   attachmentUrl=\(attachmentUrl?.prefix(30) ?? "nil")...")
        #endif
        
        // 1. Try to get readable text from text/caption fields
        let candidate = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        // 2. If candidate is empty, return type-based fallback
        if candidate.isEmpty {
            #if DEBUG
            print("🔍 [REPLY_SNIPPET]   RESULT: (empty text) -> \(typeBasedFallback)")
            #endif
            return typeBasedFallback
        }
        
        // 3. Check if candidate looks encrypted - if so, return fallback
        if candidate.looksEncrypted {
            #if DEBUG
            print("🔍 [REPLY_SNIPPET]   RESULT: (encrypted text) -> \(typeBasedFallback)")
            #endif
            return typeBasedFallback
        }
        // 3b. Mistyped contact-card stored as text — recognise the JSON
        // shape so the reply preview shows "👤 Shared contact" instead
        // of the raw `{"displayName":...}` blob.
        if ContactSharePayload.looksLikeContactCard(candidate) {
            return "👤 Shared contact"
        }

        // 4. Truncate for display (1-2 lines max)
        let result: String
        if candidate.count > 80 {
            result = String(candidate.prefix(80)) + "…"
        } else {
            result = candidate
        }
        
        #if DEBUG
        print("🔍 [REPLY_SNIPPET]   RESULT: \(result)")
        #endif
        return result
    }
    
    /// Sanitize the stored replyToTextPreview field for display
    /// Use this when displaying a message that has a reply attached
    var safeDisplaySnippetForReply: String? {
        guard let preview = replyToTextPreview, !preview.isEmpty else { return nil }
        
        // DEBUG: Log what we're processing
        #if DEBUG
        print("🔍 [REPLY_DEBUG] Processing preview: '\(preview.prefix(50))...' (len=\(preview.count), type=\(replyToType?.rawValue ?? "nil"))")
        #endif
        
        // Check if stored preview looks encrypted
        if preview.looksEncrypted {
            #if DEBUG
            print("🔍 [REPLY_DEBUG] ⚠️ Detected encrypted! Returning fallback for type: \(replyToType?.rawValue ?? "nil")")
            #endif
            // Return type-appropriate fallback based on replyToType
            switch replyToType {
            case .voice: return "🎤 Voice message"
            case .image: return "📷 Photo"
            case .video: return "🎬 Video"
            case .videoNote: return "🎥 Video note"
            case .ephemeralPhoto: return "📸 Snap Photo"
            case .file: return "📎 File"
            case .location: return "📍 Location"
            case .poll: return "📊 Poll"
            case .postShare: return "📬 Shared post"
            case .contactCard: return "👤 Shared contact"
            case .system: return "📢 Notification"
            case .text, .none: return "Message"
            }
        }
        
        // Mistyped contact-card stored as text — return friendly label so
        // the in-bubble reply badge above a quoted contact card doesn't
        // expose the JSON payload.
        if ContactSharePayload.looksLikeContactCard(preview) {
            return "👤 Shared contact"
        }

        #if DEBUG
        print("🔍 [REPLY_DEBUG] ✅ Preview looks clean, using as-is")
        #endif

        // Truncate if needed
        if preview.count > 80 {
            return String(preview.prefix(80)) + "…"
        }

        return preview
    }
    
    /// Type-based fallback for when text is empty or encrypted
    private var typeBasedFallback: String {
        switch type {
        case .voice:
            let s = audioDurationSeconds ?? 0
            return "🎤 Voice message • \(s)s"
        case .file:
            if let name = fileName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return "📎 \(name)"
            }
            let ext = (mimeType?.split(separator: "/").last.map(String.init) ?? "").uppercased()
            return ext.isEmpty ? "📎 File" : "📎 \(ext)"
        case .image:
            return "📷 Photo"
        case .video:
            return "🎬 Video"
        case .videoNote:
            return "🎥 Video note"
        case .ephemeralPhoto:
            return "📸 Snap Photo"
        case .location:
            return "📍 Location"
        case .postShare:
            return "📬 Shared post"
        case .contactCard:
            return "👤 Shared contact"
        case .poll:
            return "📊 Poll"
        case .text:
            return "Message"
        case .system:
            return "📢 Notification"
        }
    }
    

    // MARK: - Factory for New Message
    
    static func newTextMessage(
        to recipientId: String,
        text: String,
        senderId: String,
        senderName: String,
        roomId: String,
        originDeviceId: String
    ) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            serverId: nil,
            roomId: roomId,
            senderId: senderId,
            senderName: senderName,
            recipientId: recipientId,
            text: text,
            timestamp: Date(),
            type: .text,
            status: .sending,
            deliveryAuthority: .server,
            createdAt: Date(),
            deliveredAt: nil,
            readAt: nil,
            // DTN fields with defaults
            hopCount: 0,
            routePath: [originDeviceId],
            sprayCounter: PremiumLimits.meshSprayBudget,
            hopLimit: PremiumLimits.meshHopLimit,
            originDeviceId: originDeviceId,
            needsForwarding: false,
            // Media
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
    }
    
    static func newAttachmentMessage(
        messageId: String = UUID().uuidString,
        to recipientId: String,
        type: MessageType,
        localPath: String,
        fileName: String,
        mimeType: String,
        fileSize: Int?,
        duration: Int?,
        senderId: String,
        senderName: String,
        roomId: String,
        originDeviceId: String,
        // 🔴 ROUND 26 — Telegram-style album grouping.
        // All three default nil so existing single-image / single-
        // file / single-voice call sites are unchanged. The picker's
        // multi-select path stamps them when it builds the batch.
        albumGroupKey: String? = nil,
        albumIndex: Int? = nil,
        albumTotal: Int? = nil
    ) -> ChatMessage {
        var msg = ChatMessage(
            id: messageId,
            serverId: nil,
            roomId: roomId,
            senderId: senderId,
            senderName: senderName,
            recipientId: recipientId,
            text: nil,  // NO placeholder!
            timestamp: Date(),
            type: type,
            status: .sending,
            deliveryAuthority: .server,
            createdAt: Date(),
            deliveredAt: nil,
            readAt: nil,
            // DTN fields with defaults
            hopCount: 0,
            routePath: [originDeviceId],
            sprayCounter: PremiumLimits.meshSprayBudget,
            hopLimit: PremiumLimits.meshHopLimit,
            originDeviceId: originDeviceId,
            needsForwarding: false,
            // Media
            attachmentUrl: nil,
            thumbnailUrl: nil,
            fileName: fileName,
            mimeType: mimeType,
            fileSize: fileSize,
            audioDurationSeconds: duration,
            syncState: .uploading,
            localPath: localPath,
            uploadProgress: 0,
            lastError: nil,
            replyToMessageId: nil,
            replyToTextPreview: nil,
            replyToSenderName: nil,
            replyToType: nil,
            sendMode: nil,
            scheduledAtUtc: nil
        )
        msg.albumGroupKey = albumGroupKey
        msg.albumIndex = albumIndex
        msg.albumTotal = albumTotal
        return msg
    }
}
