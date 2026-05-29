package app.raven.feature.feed.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Wire-format DTOs for the /api/posts feed family.
 *
 * One-to-one with the Pydantic types in `server/routers/posts.py`:
 *   - PostResponse           → items of GET /api/posts/feed
 *   - PaginatedFeedResponse  → GET /api/posts/feed/friends
 *   - the like / repost handlers return loose `{status, action, ...}`
 *     dicts (no declared response_model on the server side)
 *
 * The server is the canonical schema; we copy field-by-field and
 * keep every non-essential field optional so a server-side addition
 * never breaks decoding (`ignoreUnknownKeys` covers the rest).
 */

@Serializable
data class PostDto(
    val id: String,
    @SerialName("author_id") val authorId: String,
    @SerialName("author_username") val authorUsername: String,
    @SerialName("author_avatar") val authorAvatar: String? = null,
    val content: String = "",
    /** Legacy single image — superseded by [media] but still sent. */
    @SerialName("image_url") val imageUrl: String? = null,
    val media: List<PostMediaDto>? = null,
    /** Server stamps a naive UTC datetime, e.g. "2026-05-20T09:30:00". */
    val timestamp: String,
    @SerialName("edited_at") val editedAt: String? = null,
    val likes: Int = 0,
    val comments: Int = 0,
    val reposts: Int = 0,
    @SerialName("view_count") val viewCount: Int = 0,
    @SerialName("is_local") val isLocal: Boolean = false,
    @SerialName("is_liked") val isLiked: Boolean = false,
    @SerialName("is_reposted") val isReposted: Boolean = false,
    val visibility: String = "public",
    @SerialName("distance_m") val distanceM: Int? = null,
    @SerialName("post_type") val postType: String? = null,
    @SerialName("mesh_origin") val meshOrigin: Boolean = false,
    @SerialName("voice_url") val voiceUrl: String? = null,
    @SerialName("voice_duration") val voiceDuration: Int? = null,
    @SerialName("is_verified") val isVerified: Boolean = false,
    @SerialName("is_premium") val isPremium: Boolean = false,
)

@Serializable
data class PostMediaDto(
    val id: String,
    val url: String,
    @SerialName("order_index") val orderIndex: Int = 0,
    @SerialName("media_type") val mediaType: String? = "image",
)

/** Wrapper returned by /feed/friends — `items` + infinite-scroll cursor. */
@Serializable
data class FeedPageDto(
    val items: List<PostDto> = emptyList(),
    val hasMore: Boolean = false,
    val nextOffset: Int = 0,
)

@Serializable
data class LikeResponseDto(
    val status: String = "success",
    val action: String = "",
    val likes: Int = 0,
    @SerialName("is_liked") val isLiked: Boolean = false,
)

@Serializable
data class RepostResponseDto(
    val status: String = "success",
    val action: String = "",
    val reposts: Int = 0,
    @SerialName("is_reposted") val isReposted: Boolean = false,
)

/** Body for POST /{post_id}/repost — `content` is an optional quote. */
@Serializable
data class RepostRequestBody(
    val content: String? = null,
)

/** Response from POST / DELETE /api/posts/{id}/bookmark. */
@Serializable
data class BookmarkResponseDto(
    val status: String = "success",
    @SerialName("is_bookmarked") val isBookmarked: Boolean = false,
)

/** One row of GET /api/posts/me/bookmarks. */
@Serializable
data class BookmarkItemDto(
    @SerialName("post_id") val postId: String,
)

/** Page wrapper for GET /api/posts/me/bookmarks. */
@Serializable
data class BookmarksPageDto(
    val bookmarks: List<BookmarkItemDto> = emptyList(),
    val total: Int = 0,
)

// ── Comments ─────────────────────────────────────────────────────

/** Mirror of `CommentResponse` in `server/routers/comments.py`. */
@Serializable
data class CommentDto(
    val id: String,
    @SerialName("post_id") val postId: String = "",
    @SerialName("author_id") val authorId: String = "",
    @SerialName("author_name") val authorName: String = "",
    @SerialName("author_avatar") val authorAvatar: String? = null,
    @SerialName("is_verified") val isVerified: Boolean = false,
    @SerialName("is_premium") val isPremium: Boolean = false,
    @SerialName("parent_comment_id") val parentCommentId: String? = null,
    val content: String = "",
    val timestamp: String,
    val score: Int = 0,
    @SerialName("my_vote") val myVote: Int = 0,
    @SerialName("is_ai_generated") val isAiGenerated: Boolean = false,
    @SerialName("comment_type") val commentType: String = "text",
    val replies: List<CommentDto> = emptyList(),
)

/** Body for POST /api/comments/create. */
@Serializable
data class CreateCommentRequest(
    @SerialName("post_id") val postId: String,
    val content: String,
    @SerialName("parent_comment_id") val parentCommentId: String? = null,
    @SerialName("comment_type") val commentType: String = "text",
)

// ── Create post ──────────────────────────────────────────────────

/**
 * Body for POST /api/posts/create. A plain public text post:
 * `is_local = false` keeps it out of the geo-scoped local feed and
 * `visibility = "public"` lands it in the global feed.
 */
@Serializable
data class CreatePostRequest(
    val content: String,
    val visibility: String = "public",
    @SerialName("is_local") val isLocal: Boolean = false,
)
