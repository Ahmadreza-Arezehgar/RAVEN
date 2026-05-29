package app.raven.feature.feed.state

import app.raven.feature.feed.data.Comment
import app.raven.feature.feed.data.Post

/**
 * Home-feed UI model. Same loading / error / empty / loaded shape
 * the iOS `FeedView` drives off `FeedStateManager`, plus the two
 * modal-sheet sub-states (comments + composer).
 */
data class FeedUiState(
    val tab: FeedTab = FeedTab.Local,
    val posts: List<Post> = emptyList(),
    val isLoading: Boolean = false,
    val isRefreshing: Boolean = false,
    val errorMessage: String? = null,
    /** Non-null while the comments bottom sheet is open. */
    val comments: CommentSheetState? = null,
    /** Non-null while the new-post composer sheet is open. */
    val composer: ComposerState? = null,
    /** Post IDs the user has bookmarked — the feed payload has no
     *  per-post `is_bookmarked`, so this is hydrated separately. */
    val bookmarkedIds: Set<String> = emptySet(),
) {
    /** True when there are no posts AND we're idle (not loading / errored). */
    val isEmpty: Boolean
        get() = !isLoading && errorMessage == null && posts.isEmpty()
}

/** State for the per-post comments bottom sheet. */
data class CommentSheetState(
    val postId: String,
    val comments: List<Comment> = emptyList(),
    val isLoading: Boolean = true,
    val errorMessage: String? = null,
    val draft: String = "",
    val isSending: Boolean = false,
)

/** State for the new-post composer bottom sheet. */
data class ComposerState(
    val draft: String = "",
    val isPosting: Boolean = false,
    val errorMessage: String? = null,
)
