package app.raven.feature.chat.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Wire-format DTOs for the /api/messages family.
 *
 * One-to-one with the Pydantic types in `server/routers/messages.py`:
 *   - SendMessageRequest    → POST /api/messages/send
 *   - MessageResponse       → response from /send + items in /inbox + /conversation
 *   - ConversationResponse  → items in GET /api/messages/conversations
 *
 * The server is the canonical schema; we copy field-by-field. Phase
 * 2 only wires the fields we actually render — the rest stay as
 * `null` defaults so future renderers can light up without server
 * changes.
 */

// ── Send ─────────────────────────────────────────────────────────

@Serializable
data class SendMessageRequest(
    @SerialName("recipient_id") val recipientId: String,
    val content: String,
    /** Client-generated UUID for idempotency — server dedups. */
    @SerialName("message_id") val messageId: String? = null,
    @SerialName("message_type") val messageType: String = "text",
    @SerialName("reply_to_message_id") val replyToMessageId: String? = null,
    @SerialName("reply_to_text_preview") val replyToTextPreview: String? = null,
    @SerialName("reply_to_sender_name") val replyToSenderName: String? = null,
    @SerialName("reply_to_type") val replyToType: String? = null,
)

// ── Message envelope (response item) ────────────────────────────

@Serializable
data class MessageDto(
    val id: String,
    @SerialName("sender_id") val senderId: String,
    @SerialName("recipient_id") val recipientId: String,
    val content: String? = null,
    /** Server-stamped ISO-8601. Parsed lazily on the Kotlin side. */
    val timestamp: String,
    @SerialName("read_at") val readAt: String? = null,
    @SerialName("delivered_at") val deliveredAt: String? = null,
    @SerialName("sender_username") val senderUsername: String? = null,
    @SerialName("sender_name") val senderName: String? = null,
    @SerialName("message_type") val messageType: String = "text",
    @SerialName("room_id") val roomId: String? = null,
    @SerialName("audio_url") val audioUrl: String? = null,
    @SerialName("audio_duration_seconds") val audioDurationSeconds: Int? = null,
    @SerialName("file_name") val fileName: String? = null,
    @SerialName("file_size") val fileSize: Long? = null,
    @SerialName("mime_type") val mimeType: String? = null,
    @SerialName("reply_to_message_id") val replyToMessageId: String? = null,
    @SerialName("reply_to_text_preview") val replyToTextPreview: String? = null,
    @SerialName("reply_to_sender_name") val replyToSenderName: String? = null,
    @SerialName("reply_to_type") val replyToType: String? = null,
    val status: String = "accepted",
    @SerialName("recipient_delivered") val recipientDelivered: Boolean = false,
    @SerialName("recipient_online") val recipientOnline: Boolean = false,
    @SerialName("attribution_verified") val attributionVerified: Boolean = true,
)

// ── Conversation (inbox row) ───────────────────────────────────

@Serializable
data class PeerDto(
    val userId: String,
    val username: String,
    val firstName: String? = null,
    val lastName: String? = null,
    val avatarPath: String? = null,
    val isVerified: Boolean = false,
    val isPremium: Boolean = false,
)

@Serializable
data class LastMessageDto(
    val id: String,
    val content: String? = null,
    val messageType: String = "text",
    val timestamp: String,
    val senderId: String,
    val deliveryAuthority: String? = null,
)

@Serializable
data class ConversationDto(
    val roomId: String,
    val peer: PeerDto,
    val lastMessage: LastMessageDto? = null,
    val unreadCount: Int = 0,
    val isPinned: Boolean = false,
    val isMuted: Boolean = false,
    val updatedAt: String,
    @SerialName("is_group") val isGroup: Boolean = false,
    @SerialName("group_name") val groupName: String? = null,
    @SerialName("group_avatar_url") val groupAvatarUrl: String? = null,
    @SerialName("is_archived") val isArchived: Boolean = false,
)

// ── Mark-read ──────────────────────────────────────────────────

@Serializable
data class MarkReadRequest(
    @SerialName("message_ids") val messageIds: List<String>,
)
