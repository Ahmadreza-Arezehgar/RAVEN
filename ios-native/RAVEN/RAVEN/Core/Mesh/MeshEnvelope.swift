//
//  MeshEnvelope.swift
//  RAVEN
//
//  DTN Mesh Implementation - BLE Payload Envelope
//

import Foundation

/// Compact envelope for BLE mesh transmission
/// Optimized for minimum payload size while containing all DTN routing info
struct MeshEnvelope: Codable, Identifiable {
    var id: String { clientMessageId }
    
    // MARK: - Core Identifiers
    
    let clientMessageId: String      // UUID - never changes
    let roomId: String
    let senderId: String
    let senderName: String
    let recipientId: String
    
    // MARK: - Content
    
    let type: Int                    // MessageType raw value
    var text: String?                // Mutable so the per-group encryption layer can swap plaintext → ciphertext before broadcast.
    let timestamp: TimeInterval      // Unix timestamp
    
    // MARK: - DTN Controls
    
    var sprayCounter: Int            // Remaining copies to spray (starts at 5)
    var hopCount: Int                // Current hop number (starts at 0)
    var hopLimit: Int                // Max hops allowed (default 10)
    var routePath: [String]          // Device IDs that handled this message
    let originDeviceId: String       // Device that created the message
    var needsForwarding: Bool        // Should this be relayed?
    var ttlSeconds: Int = PremiumLimits.meshTTLSeconds
    
    // MARK: - Optional Media
    
    var mediaUrl: String?
    var thumbnailUrl: String?
    var fileName: String?
    var mimeType: String?
    var fileSize: Int?
    var audioDuration: Int?
    
    // MARK: - Reply Context
    
    var replyToMessageId: String?
    var replyToTextPreview: String?
    var replyToSenderName: String?
    
    // MARK: - Bridge Flag
    
    var isBridged: Bool? = false  // True when relayed via server→BLE bridge
    
    // MARK: - Security: Relay Signature Chain
    
    var originalSignature: String?         // Original sender's Ed25519 signature (preserved through relay)
    var originalSignerPublicKey: String?   // Original sender's public key (preserved through relay)
    
    // MARK: - Group Flag (Bug 2 fix)
    
    var isGroup: Bool? = false   // True when message targets a group (recipientId = groupId)

    // MARK: - Group Key Version (per-group AES-GCM encryption)
    /// When set, the `text` field has been AES-GCM-encrypted with the group's
    /// symmetric key (version `groupKeyVersion`). Receivers look up the key
    /// via `GroupKeyService` and decrypt before display. Outsiders who learn
    /// the groupId cannot decrypt without the key.
    var groupKeyVersion: Int? = nil
    
    // MARK: - Geo Fence (Feature 3)
    
    var geoFence: GeoFence?  // Optional location restriction for delivery
    
    // MARK: - Encoding Keys (Short for BLE efficiency)
    
    enum CodingKeys: String, CodingKey {
        case clientMessageId = "id"
        case roomId = "rm"
        case senderId = "sid"
        case senderName = "sn"
        case recipientId = "rid"
        case type = "t"
        case text = "txt"
        case timestamp = "ts"
        case sprayCounter = "sc"
        case hopCount = "hc"
        case hopLimit = "hl"
        case routePath = "rp"
        case originDeviceId = "od"
        case needsForwarding = "nf"
        case ttlSeconds = "ttl"
        case mediaUrl = "mu"
        case thumbnailUrl = "tu"
        case fileName = "fn"
        case mimeType = "mt"
        case fileSize = "fs"
        case audioDuration = "ad"
        case replyToMessageId = "rtid"
        case replyToTextPreview = "rttp"
        case replyToSenderName = "rtsn"
        case isBridged = "ib"
        case isGroup = "ig"
        case groupKeyVersion = "gkv"
        case geoFence = "gf"
        case originalSignature = "os"
        case originalSignerPublicKey = "ospk"
    }
}

// MARK: - DTN Validation

extension MeshEnvelope {
    
    /// Check if message has expired based on TTL
    var isExpired: Bool {
        let created = Date(timeIntervalSince1970: timestamp)
        return Date() > created.addingTimeInterval(TimeInterval(ttlSeconds))
    }
    
    /// Check if this envelope should be processed (not expired/exhausted)
    var isValid: Bool {
        return hopCount < hopLimit && sprayCounter > 0 && !isExpired
    }
    
    /// Check if this device has already handled the message
    func hasPassedThrough(deviceId: String) -> Bool {
        return routePath.contains(deviceId)
    }
    
    /// Create a forwarded copy with updated DTN counters.
    /// NOTE: sprayCounter is NOT decremented here — it is managed by
    /// the Binary Spray & Wait logic in processValidatedEnvelope.
    func forwarded(by deviceId: String) -> MeshEnvelope {
        var copy = self
        copy.hopCount += 1
        copy.routePath.append(deviceId)
        return copy
    }
    
    /// Estimated payload size in bytes
    var estimatedSize: Int {
        guard let data = try? JSONEncoder().encode(self) else { return 0 }
        return data.count
    }
    
    // MARK: - Transport Routing
    
    /// Payload size category for transport selection (BLE vs MPC)
    enum PayloadCategory {
        case small   // < 4 KB — BLE optimal
        case medium  // 4 KB – 1 MB — MPC preferred
        case large   // > 1 MB — MPC required
    }
    
    /// Determine the best transport for this envelope based on payload size
    var payloadCategory: PayloadCategory {
        let size = estimatedSize
        // 4 KB threshold — matches MPCTransportService.bulkThreshold
        if size < 4096 { return .small }
        if size < 1_048_576 { return .medium }
        return .large
    }
}

// MARK: - ChatMessage Conversion

extension ChatMessage {
    
    /// Convert ChatMessage to compact MeshEnvelope for BLE transmission
    func toMeshEnvelope() -> MeshEnvelope {
        return MeshEnvelope(
            clientMessageId: id,
            roomId: roomId ?? "",
            senderId: senderId,
            senderName: senderName,
            recipientId: recipientId,
            type: type.index,
            text: text,
            timestamp: timestamp.timeIntervalSince1970,
            sprayCounter: sprayCounter,
            hopCount: hopCount,
            hopLimit: hopLimit,
            routePath: routePath,
            originDeviceId: originDeviceId,
            needsForwarding: needsForwarding,
            mediaUrl: attachmentUrl,
            thumbnailUrl: thumbnailUrl,
            fileName: fileName,
            mimeType: mimeType,
            fileSize: fileSize,
            audioDuration: audioDurationSeconds,
            replyToMessageId: replyToMessageId,
            replyToTextPreview: replyToTextPreview,
            replyToSenderName: replyToSenderName
        )
    }
    
    /// Create ChatMessage from received MeshEnvelope
    static func fromMeshEnvelope(_ env: MeshEnvelope, authority: DeliveryAuthority = .mesh) -> ChatMessage {
        // Sanitize sender name — mesh envelopes may carry encrypted/encoded names
        var safeSenderName = env.senderName
        if safeSenderName.looksEncrypted {
            safeSenderName = ""  // Will be resolved from DB/API downstream
        }
        
        return ChatMessage(
            id: env.clientMessageId,
            serverId: nil,
            roomId: env.roomId,
            senderId: env.senderId,
            senderName: safeSenderName,
            recipientId: env.recipientId,
            text: env.text,
            timestamp: Date(timeIntervalSince1970: env.timestamp),
            type: MessageType.from(index: env.type),
            status: .delivered,
            deliveryAuthority: authority,
            createdAt: Date(timeIntervalSince1970: env.timestamp),
            deliveredAt: Date(),
            readAt: nil,
            // DTN fields
            hopCount: env.hopCount,
            routePath: env.routePath,
            sprayCounter: env.sprayCounter,
            hopLimit: env.hopLimit,
            originDeviceId: env.originDeviceId,
            needsForwarding: env.needsForwarding,
            // Media
            attachmentUrl: env.mediaUrl,
            thumbnailUrl: env.thumbnailUrl,
            fileName: env.fileName,
            mimeType: env.mimeType,
            fileSize: env.fileSize,
            audioDurationSeconds: env.audioDuration,
            syncState: .localOnly,
            localPath: nil,
            uploadProgress: nil,
            lastError: nil,
            replyToMessageId: env.replyToMessageId,
            replyToTextPreview: env.replyToTextPreview,
            replyToSenderName: env.replyToSenderName,
            replyToType: nil,
            sendMode: nil,
            scheduledAtUtc: nil
        )
    }
}

// MARK: - MessageType Helpers

extension MessageType {
    var index: Int {
        switch self {
        case .text: return 0
        case .image: return 1
        case .file: return 2
        case .voice: return 3
        case .location: return 4
        case .postShare: return 5
        case .system: return 6
        case .video: return 7
        case .videoNote: return 8
        case .ephemeralPhoto: return 9
        // Polls are server-only (groups), never relayed via mesh — but the
        // exhaustiveness check still requires a case. Pin to a high index
        // that won't collide with future additions.
        case .poll: return 10
        // Contact-card shares are an online (server-routed) feature — same
        // reason as polls, kept here for exhaustiveness.
        case .contactCard: return 11
        }
    }
    
    static func from(index: Int) -> MessageType {
        switch index {
        case 0: return .text
        case 1: return .image
        case 2: return .file
        case 3: return .voice
        case 4: return .location
        case 5: return .postShare
        case 6: return .system
        case 7: return .video
        case 8: return .videoNote
        case 9: return .ephemeralPhoto
        default: return .text
        }
    }
}
