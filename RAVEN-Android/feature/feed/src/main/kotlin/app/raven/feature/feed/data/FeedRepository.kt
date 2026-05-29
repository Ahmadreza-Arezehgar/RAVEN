package app.raven.feature.feed.data

import javax.inject.Inject
import javax.inject.Singleton

/**
 * Feed repository — a thin wrapper over [FeedApi] that hands the UI
 * decoded [Post] models and the authoritative counts after a like /
 * repost toggle.
 *
 * Unlike `ChatRepository`, the feed is network-backed only for now
 * (no Room cache). The iOS feed keeps an in-memory `FeedStore`
 * rather than a heavy SQLite cache, so this matches the iOS shape;
 * a Room-backed offline cache can layer in later without touching
 * the ViewModel.
 */
@Singleton
class FeedRepository @Inject constructor(
    private val api: FeedApi,
) {

    suspend fun globalFeed(): List<Post> =
        api.globalFeed().map { Post.from(it) }

    suspend fun friendsFeed(): List<Post> =
        api.friendsFeed().items.map { Post.from(it) }

    suspend fun toggleLike(postId: String): LikeResult =
        api.toggleLike(postId).let { LikeResult(likeCount = it.likes, isLiked = it.isLiked) }

    suspend fun toggleRepost(postId: String): RepostResult =
        api.toggleRepost(postId).let { RepostResult(repostCount = it.reposts, isReposted = it.isReposted) }

    suspend fun comments(postId: String): List<Comment> =
        api.getComments(postId).map { Comment.from(it) }

    suspend fun addComment(postId: String, text: String): Comment =
        Comment.from(api.createComment(CreateCommentRequest(postId = postId, content = text)))

    suspend fun createPost(text: String): Post =
        Post.from(api.createPost(CreatePostRequest(content = text)))

    /** The set of post IDs the signed-in user has bookmarked —
     *  `PostResponse` carries no per-post flag, so we hydrate this
     *  separately on feed load. */
    suspend fun bookmarkedIds(): Set<String> =
        api.bookmarks().bookmarks.map { it.postId }.toSet()

    /** Bookmark or un-bookmark a post. Both server routes are idempotent. */
    suspend fun setBookmark(postId: String, bookmarked: Boolean) {
        if (bookmarked) api.bookmark(postId) else api.unbookmark(postId)
    }
}
