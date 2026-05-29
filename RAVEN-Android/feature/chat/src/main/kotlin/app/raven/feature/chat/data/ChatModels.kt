package app.raven.feature.chat.data

import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter

/**
 * UI-facing models. The Compose layer talks in these, not in the
 * raw DTOs — keeps the wire format decoupled from the UI.
 *
 * Equivalent of iOS `Conversation` + `ChatMessage` value types.
 */

data class ChatPeer(
    val userId: String,
    val username: String,
    val displayName: String,
    val avatarUrl: String?,
    val isVerified: Boolean,
    val isPremium: Boolean,
) {
    companion object {
        fun from(dto: PeerDto): ChatPeer = ChatPeer(
            userId = dto.userId,
            username = dto.username,
            displayName = composePeerName(dto.firstName, dto.lastName, dto.username, dto.userId),
            avatarUrl = dto.avatarPath,
            isVerified = dto.isVerified,
            isPremium = dto.isPremium,
        )
    }
}

data class Conversation(
    val roomId: String,
    val peer: ChatPeer,
    val lastMessagePreview: String?,
    val lastMessageTimestamp: Instant?,
    val lastMessageSenderId: String?,
    val unreadCount: Int,
    val isPinned: Boolean,
    val isMuted: Boolean,
    val isGroup: Boolean,
    val groupName: String?,
    val groupAvatarUrl: String?,
    val isArchived: Boolean,
    val updatedAt: Instant,
) {
    /** Visible title — group name for groups, peer display for 1:1. */
    val title: String get() = if (isGroup) groupName ?: peer.displayName else peer.displayName

    companion object {
        fun from(dto: ConversationDto): Conversation = Conversation(
            roomId = dto.roomId,
            peer = ChatPeer.from(dto.peer),
            lastMessagePreview = dto.lastMessage?.content,
            lastMessageTimestamp = dto.lastMessage?.timestamp?.let(::parseIso),
            lastMessageSenderId = dto.lastMessage?.senderId,
            unreadCount = dto.unreadCount,
            isPinned = dto.isPinned,
            isMuted = dto.isMuted,
            isGroup = dto.isGroup,
            groupName = dto.groupName,
            groupAvatarUrl = dto.groupAvatarUrl,
            isArchived = dto.isArchived,
            updatedAt = parseIso(dto.updatedAt) ?: Instant.now(),
        )
    }
}

data class ChatMessage(
    val id: String,
    val senderId: String,
    val recipientId: String,
    val content: String,
    val timestamp: Instant,
    val isFromMe: Boolean,
    val isRead: Boolean,
    val isDelivered: Boolean,
    val senderUsername: String?,
    val senderName: String?,
    val messageType: String,
    val replyToMessageId: String?,
    val replyToPreview: String?,
    val replyToSenderName: String?,
) {
    companion object {
        fun from(dto: MessageDto, currentUserId: String): ChatMessage = ChatMessage(
            id = dto.id,
            senderId = dto.senderId,
            recipientId = dto.recipientId,
            content = dto.content.orEmpty(),
            timestamp = parseIso(dto.timestamp) ?: Instant.now(),
            isFromMe = dto.senderId == currentUserId,
            isRead = dto.readAt != null,
            isDelivered = dto.deliveredAt != null,
            senderUsername = dto.senderUsername,
            senderName = dto.senderName,
            messageType = dto.messageType,
            replyToMessageId = dto.replyToMessageId,
            replyToPreview = dto.replyToTextPreview,
            replyToSenderName = dto.replyToSenderName,
        )
    }
}

/** Best-effort ISO-8601 parser. Server stamps both UTC `Z` and
 *  with-offset variants; OffsetDateTime handles both.  */
private fun parseIso(raw: String?): Instant? {
    if (raw.isNullOrBlank()) return null
    return try {
        OffsetDateTime.parse(raw, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant()
    } catch (_: Throwable) {
        try {
            Instant.parse(raw)
        } catch (_: Throwable) {
            null
        }
    }
}
