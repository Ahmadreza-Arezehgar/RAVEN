package app.raven.feature.feed.state

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.raven.feature.feed.data.FeedRepository
import app.raven.feature.feed.data.Post
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Home-feed ViewModel. Network-backed: each tab is fetched fresh
 * from [FeedRepository]; like / repost toggle optimistically; the
 * comments sheet and the new-post composer are driven off the same
 * single state object.
 *
 * Mirror of the iOS `FeedView` + `FeedStateManager` surface.
 */
@HiltViewModel
class FeedViewModel @Inject constructor(
    private val repo: FeedRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(FeedUiState(isLoading = true))
    val state: StateFlow<FeedUiState> = _state.asStateFlow()

    init {
        load(FeedTab.Local)
        loadBookmarks()
    }

    // ─── Feed loading ────────────────────────────────────────────

    fun selectTab(tab: FeedTab) {
        if (_state.value.tab == tab) return
        _state.update { it.copy(tab = tab, posts = emptyList()) }
        load(tab)
    }

    fun refresh() {
        val tab = _state.value.tab
        loadBookmarks()
        viewModelScope.launch {
            _state.update { it.copy(isRefreshing = true, errorMessage = null) }
            runCatching { fetch(tab) }
                .onSuccess { posts ->
                    if (_state.value.tab == tab) {
                        _state.update { it.copy(posts = posts, isRefreshing = false, isLoading = false) }
                    }
                }
                .onFailure {
                    if (_state.value.tab == tab) {
                        _state.update { it.copy(isRefreshing = false, isLoading = false) }
                    }
                }
        }
    }

    private fun load(tab: FeedTab) {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, errorMessage = null) }
            runCatching { fetch(tab) }
                .onSuccess { posts ->
                    if (_state.value.tab == tab) {
                        _state.update { it.copy(posts = posts, isLoading = false) }
                    }
                }
                .onFailure { error ->
                    if (_state.value.tab == tab) {
                        _state.update {
                            it.copy(isLoading = false, errorMessage = error.message ?: "Something went wrong.")
                        }
                    }
                }
        }
    }

    private suspend fun fetch(tab: FeedTab): List<Post> = when (tab) {
        FeedTab.Local -> repo.globalFeed()
        FeedTab.Friends -> repo.friendsFeed()
    }

    // ─── Like / repost ───────────────────────────────────────────

    fun toggleLike(post: Post) {
        val liked = !post.isLiked
        val count = (post.likeCount + if (liked) 1 else -1).coerceAtLeast(0)
        updatePost(post.id) { it.copy(isLiked = liked, likeCount = count) }
        viewModelScope.launch {
            runCatching { repo.toggleLike(post.id) }
                .onSuccess { r -> updatePost(post.id) { it.copy(isLiked = r.isLiked, likeCount = r.likeCount) } }
                .onFailure { updatePost(post.id) { it.copy(isLiked = post.isLiked, likeCount = post.likeCount) } }
        }
    }

    fun toggleRepost(post: Post) {
        val reposted = !post.isReposted
        val count = (post.repostCount + if (reposted) 1 else -1).coerceAtLeast(0)
        updatePost(post.id) { it.copy(isReposted = reposted, repostCount = count) }
        viewModelScope.launch {
            runCatching { repo.toggleRepost(post.id) }
                .onSuccess { r -> updatePost(post.id) { it.copy(isReposted = r.isReposted, repostCount = r.repostCount) } }
                .onFailure { updatePost(post.id) { it.copy(isReposted = post.isReposted, repostCount = post.repostCount) } }
        }
    }

    // ─── Bookmark ────────────────────────────────────────────────

    /** Optimistic bookmark toggle — the set is the source of truth. */
    fun toggleBookmark(post: Post) {
        val nowBookmarked = post.id !in _state.value.bookmarkedIds
        _state.update { s ->
            s.copy(
                bookmarkedIds = if (nowBookmarked) s.bookmarkedIds + post.id
                else s.bookmarkedIds - post.id,
            )
        }
        viewModelScope.launch {
            runCatching { repo.setBookmark(post.id, nowBookmarked) }
                .onFailure {
                    _state.update { s ->
                        s.copy(
                            bookmarkedIds = if (nowBookmarked) s.bookmarkedIds - post.id
                            else s.bookmarkedIds + post.id,
                        )
                    }
                }
        }
    }

    /** Hydrate the bookmarked-IDs set — the feed payload has no flag. */
    private fun loadBookmarks() {
        viewModelScope.launch {
            runCatching { repo.bookmarkedIds() }
                .onSuccess { ids -> _state.update { it.copy(bookmarkedIds = ids) } }
        }
    }

    // ─── Comments sheet ──────────────────────────────────────────

    fun openComments(post: Post) {
        val postId = post.id
        _state.update { it.copy(comments = CommentSheetState(postId = postId)) }
        viewModelScope.launch {
            runCatching { repo.comments(postId) }
                .onSuccess { list ->
                    _state.update { s ->
                        val cur = s.comments
                        if (cur != null && cur.postId == postId) {
                            s.copy(comments = cur.copy(comments = list, isLoading = false))
                        } else {
                            s
                        }
                    }
                }
                .onFailure { e ->
                    _state.update { s ->
                        val cur = s.comments
                        if (cur != null && cur.postId == postId) {
                            s.copy(comments = cur.copy(isLoading = false, errorMessage = e.message ?: "Couldn't load comments."))
                        } else {
                            s
                        }
                    }
                }
        }
    }

    fun closeComments() {
        _state.update { it.copy(comments = null) }
    }

    fun setCommentDraft(text: String) {
        _state.update { s -> s.copy(comments = s.comments?.copy(draft = text)) }
    }

    fun submitComment() {
        val sheet = _state.value.comments ?: return
        val text = sheet.draft.trim()
        if (text.isEmpty() || sheet.isSending) return
        val postId = sheet.postId
        _state.update { s -> s.copy(comments = s.comments?.copy(isSending = true)) }
        viewModelScope.launch {
            runCatching { repo.addComment(postId, text) }
                .onSuccess { comment ->
                    _state.update { s ->
                        val cur = s.comments
                        if (cur != null && cur.postId == postId) {
                            s.copy(
                                comments = cur.copy(
                                    comments = listOf(comment) + cur.comments,
                                    draft = "",
                                    isSending = false,
                                ),
                            )
                        } else {
                            s
                        }
                    }
                    updatePost(postId) { it.copy(commentCount = it.commentCount + 1) }
                }
                .onFailure {
                    _state.update { s -> s.copy(comments = s.comments?.copy(isSending = false)) }
                }
        }
    }

    // ─── New-post composer ───────────────────────────────────────

    fun openComposer() {
        _state.update { it.copy(composer = ComposerState()) }
    }

    fun closeComposer() {
        _state.update { it.copy(composer = null) }
    }

    fun setComposerDraft(text: String) {
        _state.update { s -> s.copy(composer = s.composer?.copy(draft = text)) }
    }

    fun submitPost() {
        val composer = _state.value.composer ?: return
        val text = composer.draft.trim()
        if (text.isEmpty() || composer.isPosting) return
        _state.update { s -> s.copy(composer = s.composer?.copy(isPosting = true, errorMessage = null)) }
        viewModelScope.launch {
            runCatching { repo.createPost(text) }
                .onSuccess { post ->
                    _state.update { s -> s.copy(composer = null, posts = listOf(post) + s.posts) }
                }
                .onFailure { e ->
                    _state.update { s ->
                        s.copy(composer = s.composer?.copy(isPosting = false, errorMessage = e.message ?: "Couldn't post."))
                    }
                }
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────

    /** Replace a single post in the list, leaving the rest untouched. */
    private fun updatePost(id: String, transform: (Post) -> Post) {
        _state.update { s ->
            s.copy(posts = s.posts.map { if (it.id == id) transform(it) else it })
        }
    }
}
