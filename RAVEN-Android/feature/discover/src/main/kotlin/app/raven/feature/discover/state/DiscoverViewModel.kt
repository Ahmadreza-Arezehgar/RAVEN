package app.raven.feature.discover.state

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.raven.feature.discover.data.DiscoverRepository
import app.raven.feature.discover.data.DiscoverUser
import app.raven.feature.feed.data.FeedRepository
import app.raven.feature.feed.data.Post
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import retrofit2.HttpException
import javax.inject.Inject

/**
 * Discover-tab ViewModel. Loads friend suggestions for the idle
 * state, runs a debounced search across people AND posts, fires
 * friend requests, and likes/reposts post results via [FeedRepository].
 */
@HiltViewModel
class DiscoverViewModel @Inject constructor(
    private val repo: DiscoverRepository,
    private val feedRepo: FeedRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(DiscoverUiState())
    val state: StateFlow<DiscoverUiState> = _state.asStateFlow()

    private var searchJob: Job? = null

    init {
        loadSuggested()
    }

    fun loadSuggested() {
        viewModelScope.launch {
            _state.update { it.copy(isLoadingSuggested = true, errorMessage = null) }
            runCatching { repo.suggested() }
                .onSuccess { list -> _state.update { it.copy(suggested = list, isLoadingSuggested = false) } }
                .onFailure { error ->
                    _state.update {
                        it.copy(isLoadingSuggested = false, errorMessage = error.message ?: "Couldn't load suggestions.")
                    }
                }
        }
    }

    fun setSearchMode(mode: SearchMode) {
        _state.update { it.copy(searchMode = mode) }
    }

    /** Search-as-you-type — 300 ms debounced; searches people + posts in parallel. */
    fun setQuery(query: String) {
        _state.update { it.copy(query = query) }
        searchJob?.cancel()
        if (query.trim().length < 2) {
            _state.update {
                it.copy(
                    results = emptyList(),
                    postResults = emptyList(),
                    isLoadingResults = false,
                    isLoadingPosts = false,
                    errorMessage = null,
                    postErrorMessage = null,
                )
            }
            return
        }
        val q = query.trim()
        searchJob = viewModelScope.launch {
            delay(300)
            _state.update {
                it.copy(
                    isLoadingResults = true,
                    isLoadingPosts = true,
                    errorMessage = null,
                    postErrorMessage = null,
                )
            }
            launch {
                runCatching { repo.searchUsers(q) }
                    .onSuccess { list -> _state.update { it.copy(results = list, isLoadingResults = false) } }
                    .onFailure { error ->
                        _state.update { it.copy(isLoadingResults = false, errorMessage = error.message ?: "Search failed.") }
                    }
            }
            launch {
                runCatching { repo.searchPosts(q) }
                    .onSuccess { list ->
                        _state.update { it.copy(postResults = list, isLoadingPosts = false, postErrorMessage = null) }
                    }
                    .onFailure { error ->
                        _state.update {
                            it.copy(isLoadingPosts = false, postErrorMessage = error.message ?: "Post search failed.")
                        }
                    }
            }
        }
    }

    fun clearQuery() = setQuery("")

    fun sendFriendRequest(user: DiscoverUser) {
        if (user.id in _state.value.sentRequestIds) return
        _state.update { it.copy(sentRequestIds = it.sentRequestIds + user.id) }
        viewModelScope.launch {
            runCatching { repo.sendFriendRequest(user.id) }
                .onFailure { error ->
                    val alreadyExists = error is HttpException && error.code() == 400
                    if (!alreadyExists) {
                        _state.update { s -> s.copy(sentRequestIds = s.sentRequestIds - user.id) }
                    }
                }
        }
    }

    fun toggleLike(post: Post) {
        val liked = !post.isLiked
        val count = (post.likeCount + if (liked) 1 else -1).coerceAtLeast(0)
        updatePost(post.id) { it.copy(isLiked = liked, likeCount = count) }
        viewModelScope.launch {
            runCatching { feedRepo.toggleLike(post.id) }
                .onSuccess { r -> updatePost(post.id) { it.copy(isLiked = r.isLiked, likeCount = r.likeCount) } }
                .onFailure { updatePost(post.id) { it.copy(isLiked = post.isLiked, likeCount = post.likeCount) } }
        }
    }

    fun toggleRepost(post: Post) {
        val reposted = !post.isReposted
        val count = (post.repostCount + if (reposted) 1 else -1).coerceAtLeast(0)
        updatePost(post.id) { it.copy(isReposted = reposted, repostCount = count) }
        viewModelScope.launch {
            runCatching { feedRepo.toggleRepost(post.id) }
                .onSuccess { r -> updatePost(post.id) { it.copy(isReposted = r.isReposted, repostCount = r.repostCount) } }
                .onFailure { updatePost(post.id) { it.copy(isReposted = post.isReposted, repostCount = post.repostCount) } }
        }
    }

    private fun updatePost(id: String, transform: (Post) -> Post) {
        _state.update { s -> s.copy(postResults = s.postResults.map { if (it.id == id) transform(it) else it }) }
    }
}
