package app.raven.feature.feed.data

import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * UI-facing feed models. The Compose layer talks in these, never the
 * raw DTOs — keeps the wire format decoupled from the screens.
 *
 * Equivalent of the iOS `Post` / `PostMedia` value types in
 * `ios-native/RAVEN/RAVEN/Models/Post.swift`.
 */

data class PostMedia(
    val id: String,
    val url: String,
    val orderIndex: Int,
    val isVideo: Boolean,
)

data class Post(
    val id: String,
    val authorId: String,
    val authorUsername: String,
    val authorAvatar: String?,
    val content: String,
    val media: List<PostMedia>,
    val timestamp: Instant,
    val isEdited: Boolean,
    val likeCount: Int,
    val commentCount: Int,
    val repostCount: Int,
    val viewCount: Int,
    val isLiked: Boolean,
    val isReposted: Boolean,
    val isVerified: Boolean,
    val isPremium: Boolean,
    val isVoicePost: Boolean,
    /** Streamable audio URL for a voice post — null for text posts. */
    val voiceUrl: String? = null,
    val voiceDurationSec: Int = 0,
) {
    companion object {
        fun from(dto: PostDto): Post {
            // Prefer the multi-media list; fall back to the legacy
            // single image so older posts still render an image.
            val media = buildList {
                dto.media
                    ?.sortedBy { it.orderIndex }
                    ?.forEach { add(PostMedia(it.id, it.url, it.orderIndex, isVideo(it.mediaType, it.url))) }
                if (isEmpty() && !dto.imageUrl.isNullOrBlank()) {
                    add(PostMedia(id = "${dto.id}-legacy", url = dto.imageUrl, orderIndex = 0, isVideo = false))
                }
            }
            return Post(
                id = dto.id,
                authorId = dto.authorId,
                authorUsername = dto.authorUsername,
                authorAvatar = dto.authorAvatar,
                content = dto.content,
                media = media,
                timestamp = parseTimestamp(dto.timestamp) ?: Instant.now(),
                isEdited = dto.editedAt != null,
                likeCount = dto.likes,
                commentCount = dto.comments,
                repostCount = dto.reposts,
                viewCount = dto.viewCount,
                isLiked = dto.isLiked,
                isReposted = dto.isReposted,
                isVerified = dto.isVerified,
                isPremium = dto.isPremium,
                isVoicePost = dto.postType == "voice" ||
                    dto.postType == "voice_chain" ||
                    !dto.voiceUrl.isNullOrBlank(),
                voiceUrl = dto.voiceUrl,
                voiceDurationSec = dto.voiceDuration ?: 0,
            )
        }
    }
}

/** Result of a like / repost toggle — the server's authoritative count. */
data class LikeResult(val likeCount: Int, val isLiked: Boolean)
data class RepostResult(val repostCount: Int, val isReposted: Boolean)

/** A comment on a post — equivalent of the iOS `Comment` value type. */
data class Comment(
    val id: String,
    val authorName: String,
    val authorAvatar: String?,
    val isVerified: Boolean,
    val isPremium: Boolean,
    val content: String,
    val timestamp: Instant,
    val score: Int,
    val isAiGenerated: Boolean,
    val replies: List<Comment>,
) {
    companion object {
        fun from(dto: CommentDto): Comment = Comment(
            id = dto.id,
            authorName = dto.authorName,
            authorAvatar = dto.authorAvatar,
            isVerified = dto.isVerified,
            isPremium = dto.isPremium,
            content = dto.content,
            timestamp = parseTimestamp(dto.timestamp) ?: Instant.now(),
            score = dto.score,
            isAiGenerated = dto.isAiGenerated,
            replies = dto.replies.map { from(it) },
        )
    }
}

private fun isVideo(mediaType: String?, url: String): Boolean {
    if (mediaType?.equals("video", ignoreCase = true) == true) return true
    val path = url.substringBefore('?').lowercase()
    return path.endsWith(".mp4") || path.endsWith(".mov") ||
        path.endsWith(".m4v") || path.endsWith(".webm")
}

/**
 * Parse the server timestamp. FastAPI serialises `datetime.utcnow()`
 * as a *naive* ISO string (no `Z`, no offset), so we try the
 * offset-aware parsers first and fall back to [LocalDateTime].
 */
private fun parseTimestamp(raw: String?): Instant? {
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
