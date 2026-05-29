package app.raven.feature.chat.data

import app.raven.core.storage.ConversationEntity
import app.raven.core.storage.MessageEntity
import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * DTO ⇄ Entity ⇄ UI-model conversions for chat.
 *
 * Three layers: the wire DTOs ([ConversationDto] / [MessageDto]),
 * the Room rows ([ConversationEntity] / [MessageEntity]), and the
 * UI types ([Conversation] / [ChatMessage]). Repositories own the
 * funnel — the UI never sees DTOs, the network never sees entities.
 *
 * iOS does the same split in three layers: `ConversationResponse`
 * (network) → `Conversation` (Core Data NSManagedObject) → the
 * SwiftUI view's `Conversation` value type.
 */

// ── DTO → Entity ─────────────────────────────────────────────────

fun ConversationDto.toEntity(): ConversationEntity = ConversationEntity(
    id = roomId,
    peer_user_id = if (!isGroup) peer.userId else null,
    group_id = if (isGroup) roomId else null,
    title = if (isGroup) groupName else null,
    last_message_preview = lastMessage?.content,
    last_message_sender_id = lastMessage?.senderId,
    last_message_timestamp = lastMessage?.timestamp?.toEpochMillis(),
    unread_count = unreadCount,
    updated_at = updatedAt.toEpochMillis() ?: System.currentTimeMillis(),
    is_archived = isArchived,
    is_pinned = isPinned,
    is_muted = isMuted,
    is_group = isGroup,
    group_name = groupName,
    group_avatar_url = groupAvatarUrl,
    peer_username = peer.username,
    peer_display_name = peer.composedDisplayName(),
    peer_avatar_url = peer.avatarPath,
    peer_is_verified = peer.isVerified,
    peer_is_premium = peer.isPremium,
)

/**
 * Convert a wire DTO into a Room entity. [resolvedContent] is the
 * already-decoded message body — Phase 2e moves envelope decoding
 * upstream into [ChatRepository.resolveIncomingContent] so the
 * decrypt path can be `suspend` (it talks to the e2ee module,
 * which may have to fetch a peer bundle on the responder path).
 *
 * Callers MUST resolve content before invoking this helper —
 * leaving the raw wire bytes in `content` would surface RVNS1
 * base64 garbage in the UI.
 */
fun MessageDto.toEntity(currentUserId: String, resolvedContent: String): MessageEntity {
    // For a 1:1 message the conversation_id is the OTHER user. For
    // groups, prefer the server-supplied room_id (which is the
    // group_id).
    val isGroup = roomId != null && roomId != senderId && roomId != recipientId
    val convId = when {
        isGroup -> roomId.orEmpty()
        senderId == currentUserId -> recipientId
        else -> senderId
    }

    return MessageEntity(
        id = id,
        conversation_id = convId,
        sender_id = senderId,
        recipient_id = recipientId,
        group_id = if (isGroup) roomId else null,
        content = resolvedContent,
        message_type = messageType,
        created_at = timestamp.toEpochMillis() ?: System.currentTimeMillis(),
        delivered_at = deliveredAt.toEpochMillis(),
        read_at = readAt.toEpochMillis(),
        attribution_verified = attributionVerified,
        reply_to_message_id = replyToMessageId,
        reply_to_text_preview = replyToTextPreview,
        reply_to_sender_name = replyToSenderName,
        reply_to_type = replyToType,
        sender_username = senderUsername,
        sender_name = senderName,
    )
}

// ── Entity → UI ──────────────────────────────────────────────────

fun ConversationEntity.toModel(): Conversation = Conversation(
    roomId = id,
    peer = ChatPeer(
        userId = peer_user_id ?: id,
        username = peer_username.orEmpty(),
        displayName = peer_display_name ?: peer_username.orEmpty(),
        avatarUrl = peer_avatar_url,
        isVerified = peer_is_verified,
        isPremium = peer_is_premium,
    ),
    lastMessagePreview = last_message_preview,
    lastMessageTimestamp = last_message_timestamp?.let(Instant::ofEpochMilli),
    lastMessageSenderId = last_message_sender_id,
    unreadCount = unread_count,
    isPinned = is_pinned,
    isMuted = is_muted,
    isGroup = is_group,
    groupName = group_name,
    groupAvatarUrl = group_avatar_url,
    isArchived = is_archived,
    updatedAt = Instant.ofEpochMilli(updated_at),
)

fun MessageEntity.toModel(currentUserId: String): ChatMessage = ChatMessage(
    id = id,
    senderId = sender_id,
    recipientId = recipient_id.orEmpty(),
    content = content,
    timestamp = Instant.ofEpochMilli(created_at),
    isFromMe = sender_id == currentUserId,
    isRead = read_at != null,
    isDelivered = delivered_at != null,
    senderUsername = sender_username,
    senderName = sender_name,
    messageType = message_type,
    replyToMessageId = reply_to_message_id,
    replyToPreview = reply_to_text_preview,
    replyToSenderName = reply_to_sender_name,
)

// ── Helpers ──────────────────────────────────────────────────────

private fun PeerDto.composedDisplayName(): String =
    composePeerName(firstName, lastName, username, userId)

/** Best-effort ISO-8601 → epoch-millis. Server sends both `Z` and
 *  `+00:00` flavours; OffsetDateTime handles both. */
private fun String?.toEpochMillis(): Long? {
    if (this.isNullOrBlank()) return null
    return try {
        OffsetDateTime.parse(this, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant().toEpochMilli()
    } catch (_: Throwable) {
        try {
            Instant.parse(this).toEpochMilli()
        } catch (_: Throwable) {
            try {
                // FastAPI stamps naive UTC datetimes (no `Z`, no offset),
                // e.g. "2026-05-21T18:00:59.772588" — treat them as UTC.
                LocalDateTime.parse(this).toInstant(ZoneOffset.UTC).toEpochMilli()
            } catch (_: Throwable) {
                null
            }
        }
    }
}
