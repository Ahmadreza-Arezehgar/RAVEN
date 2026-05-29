package app.raven.feature.notifications.data

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/** The visual category of a notification — drives the row's icon/colour. */
enum class NotificationKind { Like, Comment, Friend, Mention, Repost, Security, Post, Other }

/** UI-facing notification — a resolved line of text + a kind + time. */
data class AppNotification(
    val id: String,
    val kind: NotificationKind,
    val text: String,
    val timestamp: Instant,
    val isRead: Boolean,
) {
    companion object {
        fun from(dto: NotificationDto): AppNotification {
            val actor = dto.data.firstString(
                "actor_username", "liker_username", "commenter_username",
                "requester_username", "sender_username", "from_username", "username",
            )
            val who = actor ?: "Someone"
            val (kind, text) = when (dto.type.lowercase()) {
                "like" -> NotificationKind.Like to "$who liked your post"
                "comment" -> NotificationKind.Comment to "$who commented on your post"
                "mention" -> NotificationKind.Mention to "$who mentioned you"
                "repost" -> NotificationKind.Repost to "$who reposted your post"
                "friend_request" -> NotificationKind.Friend to "$who sent you a friend request"
                "friend_accept", "friend_accepted" ->
                    NotificationKind.Friend to "$who accepted your friend request"
                "post_from_followed", "post" -> NotificationKind.Post to "$who shared a new post"
                "security" -> NotificationKind.Security to securityText(dto.data)
                else -> NotificationKind.Other to
                    (actor?.let { "$it sent you a notification" } ?: "You have a new notification")
            }
            return AppNotification(
                id = dto.id,
                kind = kind,
                text = text,
                timestamp = parseInstant(dto.timestamp) ?: Instant.now(),
                isRead = dto.isRead,
            )
        }
    }
}

private fun securityText(data: JsonObject): String {
    val device = data.firstString("device")
    return when (data.firstString("event")) {
        "new_login" -> if (device != null) "New login from $device" else "New login to your account"
        else -> "Security alert on your account"
    }
}

/** First non-blank string value among [keys] in this JSON object. */
private fun JsonObject.firstString(vararg keys: String): String? {
    for (key in keys) {
        val value = this[key]?.jsonPrimitive?.contentOrNull
        if (!value.isNullOrBlank()) return value
    }
    return null
}

private fun parseInstant(raw: String?): Instant? {
    if (raw.isNullOrBlank()) return null
    return try {
        OffsetDateTime.parse(raw, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant()
    } catch (_: Throwable) {
        try {
            Instant.parse(raw)
        } catch (_: Throwable) {
            try {
                LocalDateTime.parse(raw).toInstant(ZoneOffset.UTC)
            } catch (_: Throwable) {
                null
            }
        }
    }
}
