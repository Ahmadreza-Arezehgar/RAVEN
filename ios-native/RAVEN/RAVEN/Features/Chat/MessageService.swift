import Foundation
import UIKit

// MARK: - Message Service (Send with Atomic Attachment)
@MainActor // BUG FIX [P3]: Added MainActor isolation to prevent Swift 6 concurrency warnings
@Observable final class MessageService {
    static let shared = MessageService()
    
    private let messageRepo = MessageRepository.shared
    // BUG FIX [P3]: Removed `private let conversationStore = ConversationStore.shared`
    // Use ConversationStore.shared directly to avoid Swift 6 cross-actor stored property warnings
    
    nonisolated private init() {}
    
    // MARK: - Send Text Message
    
    func sendText(
        to recipientId: String,
        text: String,
        isGroup: Bool = false,
        replyTo: ChatMessage? = nil,
        clientMessageId: String? = nil,
        forwardedFromChannelId: String? = nil,
        forwardedFromChannelName: String? = nil
    ) async throws {
        // 1. Generate client_message_id only when the caller didn't supply
        // one. The previous version unconditionally minted a fresh UUID
        // here and SHADOWED the parameter — so retried sends from the
        // OutboxManager arrived at the server with a different
        // `client_message_id` each attempt, breaking the server-side
        // dedup keyed on that field. The comment block below ("the
        // caller-supplied client ID") had been a lie since the shadow
        // was introduced.
        let clientMessageId = clientMessageId ?? UUID().uuidString
        let roomId = isGroup ? recipientId : await makeRoomId(with: recipientId)
        let senderId = await currentUserId()
        let senderName = await currentUsername()
        let deviceId = await deviceIdentifier()
        
        // 2. Build the local message directly with the caller-supplied client
        // ID. (Earlier code built a default factory message and then threw it
        // away, so the factory call was dead.)
        let finalMessage = ChatMessage(
            id: clientMessageId,
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
            hopCount: 0,
            routePath: [deviceId],
            sprayCounter: PremiumLimits.meshSprayBudget,
            hopLimit: PremiumLimits.meshHopLimit,
            originDeviceId: deviceId,
            needsForwarding: false,
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
            scheduledAtUtc: nil,
            forwardedFromChannelId: forwardedFromChannelId,
            forwardedFromChannelName: forwardedFromChannelName
        )
        
        // 3. Upsert to DB (idempotent)
        try await messageRepo.upsert(finalMessage)
        
        // 4. Route through MessageRouter for proper dual-path delivery
        // (server + mesh + persistent outbox for offline scenarios)
        // The old code called NetworkService.shared.post directly, which meant
        // messages sent while offline (e.g., Quick Reply) were silently lost.
        try await MessageRouter.shared.send(
            to: recipientId,
            text: text,
            clientMessageId: clientMessageId
        )
    }
    
    // BUG FIX [P3]: Removed legacy sendAttachment() method.
    // All attachment uploads now go through AttachmentService which handles
    // the full atomic pipeline (persist → upload → send → confirm).
    
    // MARK: - Forward Message (preserves media/voice/file)
    
    func forwardMessage(
        _ originalMsg: ChatMessage,
        to recipientId: String,
        isGroup: Bool = false,
        forwardedFromChannelId: String? = nil,
        forwardedFromChannelName: String? = nil
    ) async throws {
        // 🔴 ROUND 69 (2026-05-23) — hacker-audit VAULT-CRIT-2
        // (HIGH: vault attachment forward gap).
        //
        // PREVIOUSLY: this method blindly passed `originalMsg.attachmentUrl`
        // and `originalMsg.fileName` through to the new message,
        // regardless of whether the original was a Vault-sealed
        // attachment. Two real problems with that path:
        //
        //   1. METADATA LEAK — the original Vault file's `fileName`
        //      (e.g. "passport_2024.pdf") was forwarded in cleartext
        //      to a third party. Server admin / DB compromise sees
        //      another copy of the sensitive name. (Round 69 also
        //      strips this on the original send path; this branch
        //      closes the forward-as-replay loophole.)
        //
        //   2. BROKEN-FILE UX — the .vlt blob on Cloud Storage is
        //      AES-GCM-sealed to the ORIGINAL recipient's X25519
        //      identity key with AAD = original msgId. A new recipient
        //      attempting to decrypt with their key + the forwarded
        //      msgId fails both checks; they get a "couldn't decrypt
        //      vault attachment" error and never see the content.
        //      The Forward action in the UI looks like it worked but
        //      ships a deliberately undecryptable file — confusing
        //      and security-theatre.
        //
        // FIX: refuse to forward vault attachments. The caller's UI
        // catches `forwardingVaultDenied` and surfaces a clear message
        // ("Vault attachments cannot be forwarded"). If the sender
        // really wants to share the content with a third party they
        // must re-send it as a fresh vault message — that triggers a
        // new encryption to the new recipient's verified key. The
        // matching server-side gate is `allow_forward = false` set
        // by AttachmentService when `vault=true` (see round 69 in
        // AttachmentService.swift); this client-side check fires
        // first so the user gets immediate feedback instead of a
        // generic 403.
        //
        // Detection: the upload pipeline writes vault blobs to a path
        // ending in `.vlt`, and the receiver mirrors that suffix
        // through to `attachmentUrl`. Belt-and-suspenders also check
        // `allowForward` — set false by the server on vault sends.
        let isVaultAttachment =
            originalMsg.attachmentUrl?.lowercased().hasSuffix(".vlt") == true ||
            originalMsg.attachmentUrl?.lowercased().contains(".vlt?") == true ||
            originalMsg.allowForward == false
        if isVaultAttachment {
            throw NSError(
                domain: "MessageService",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey:
                    "Vault attachments cannot be forwarded. Send a fresh copy to share with this recipient."]
            )
        }

        let clientMessageId = UUID().uuidString
        let roomId = isGroup ? recipientId : await makeRoomId(with: recipientId)
        let senderId = await currentUserId()
        let senderName = await currentUsername()
        let deviceId = await deviceIdentifier()

        let forwardedMsg = ChatMessage(
            id: clientMessageId,
            serverId: nil,
            roomId: roomId,
            senderId: senderId,
            senderName: senderName,
            recipientId: recipientId,
            text: originalMsg.text,
            timestamp: Date(),
            type: originalMsg.type,
            status: .sending,
            deliveryAuthority: .server,
            createdAt: Date(),
            deliveredAt: nil,
            readAt: nil,
            hopCount: 0,
            routePath: [deviceId],
            sprayCounter: PremiumLimits.meshSprayBudget,
            hopLimit: PremiumLimits.meshHopLimit,
            originDeviceId: deviceId,
            needsForwarding: originalMsg.needsForwarding,
            attachmentUrl: originalMsg.attachmentUrl,
            thumbnailUrl: originalMsg.thumbnailUrl,
            fileName: originalMsg.fileName,
            mimeType: originalMsg.mimeType,
            fileSize: originalMsg.fileSize,
            audioDurationSeconds: originalMsg.audioDurationSeconds,
            syncState: .queued,
            localPath: originalMsg.localPath,
            uploadProgress: nil,
            lastError: nil,
            replyToMessageId: nil,
            replyToTextPreview: nil,
            replyToSenderName: nil,
            replyToType: nil,
            sendMode: nil,
            scheduledAtUtc: nil,
            forwardedFromChannelId: forwardedFromChannelId ?? originalMsg.forwardedFromChannelId,
            forwardedFromChannelName: forwardedFromChannelName ?? originalMsg.forwardedFromChannelName
        )
        
        try await messageRepo.upsert(forwardedMsg)
        await ConversationStore.shared.handleIncomingMessage(forwardedMsg)
        
        try await MessageRouter.shared.send(
            to: recipientId,
            text: originalMsg.text ?? "",
            clientMessageId: clientMessageId,
            roomId: roomId
        )
    }
    
    // MARK: - Send Contact Card

    /// Share a Raven friend's profile into a chat as a postcard. Mirrors
    /// `sendPostShare` but the embedded JSON is a `ContactSharePayload`
    /// and the message type is `.contactCard`. The recipient's client
    /// renders this with `ContactCardMessageView`.
    func sendContactShare(friend: GroupFriendInfo, to recipientId: String, isGroup: Bool = false) async throws {
        let clientMessageId = UUID().uuidString
        let roomId = isGroup ? recipientId : await makeRoomId(with: recipientId)
        let senderId = await currentUserId()
        let senderName = await currentUsername()
        let deviceId = await deviceIdentifier()

        let payload = ContactSharePayload(from: friend)
        guard let payloadJson = payload.encode() else {
            throw NSError(
                domain: "MessageService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode contact-share payload"]
            )
        }

        let message = ChatMessage(
            id: clientMessageId,
            serverId: nil,
            roomId: roomId,
            senderId: senderId,
            senderName: senderName,
            recipientId: recipientId,
            text: payloadJson,
            timestamp: Date(),
            type: .contactCard,
            status: .sending,
            deliveryAuthority: .server,
            createdAt: Date(),
            deliveredAt: nil,
            readAt: nil,
            hopCount: 0,
            routePath: [deviceId],
            sprayCounter: PremiumLimits.meshSprayBudget,
            hopLimit: PremiumLimits.meshHopLimit,
            originDeviceId: deviceId,
            needsForwarding: false,
            attachmentUrl: nil,
            thumbnailUrl: friend.avatarUrl,
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

        try await messageRepo.upsert(message)
        await ConversationStore.shared.handleIncomingMessage(message)
        await MainActor.run {
            NotificationCenter.default.post(
                name: NSNotification.Name("AttachmentService.messageInserted"),
                object: nil
            )
        }

        try await MessageRouter.shared.send(
            to: recipientId,
            text: payloadJson,
            clientMessageId: clientMessageId,
            roomId: roomId
        )
    }

    // MARK: - Helpers

    private func makeRoomId(with peerId: String) async -> String {
        let myId = await currentUserId()
        let sorted = [myId, peerId].sorted()
        return "\(sorted[0])_\(sorted[1])"
    }
    
    private func currentUserId() async -> String {
        await KeychainService.shared.getUserId() ?? ""
    }
    
    private func currentUsername() async -> String {
        await MainActor.run { AuthService.shared.currentUser?.username ?? "" }
    }
    
    private func deviceIdentifier() async -> String {
        // Use vendor identifier as device ID for mesh routing
        await MainActor.run { UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString }
    }
    
    // BUG FIX [P3]: Removed legacy uploadFile(), mimeType(), buildMultipartFile(), fileSize()
    // These were only used by the deleted sendAttachment() method above.
    
    /// Generate a proper text preview for reply based on message type
    /// Filters out encrypted content and provides human-readable fallbacks
    private func generateReplyPreview(for message: ChatMessage?) -> String? {
        guard let message = message else { return nil }
        
        switch message.type {
        case .text:
            // For text messages, use actual text (truncated) - but filter encrypted content
            guard let text = message.text, !text.isEmpty else { return nil }

            // Check if text looks encrypted (Fernet, JWT, or long base64)
            if text.hasPrefix("gAAAA") || text.hasPrefix("eyJ") ||
               (text.count > 100 && text.range(of: "^[A-Za-z0-9+/=_-]+$", options: .regularExpression) != nil) {
                return "Message"
            }
            // Mistyped contact-card stored as text.
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
}

// Note: SendMessageRequest and SendMessageResponse are defined in MessageStore.swift

struct UploadResult {
    let url: String
}
