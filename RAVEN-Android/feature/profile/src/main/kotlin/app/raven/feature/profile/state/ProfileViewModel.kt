package app.raven.feature.profile.state

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.raven.feature.feed.data.FeedRepository
import app.raven.feature.feed.data.Post
import app.raven.feature.profile.data.ProfileRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Profile-tab ViewModel. Loads the signed-in user's profile + posts,
 * drives the settings + edit-profile sheets, and handles sign-out.
 * Like / repost on the user's own posts reuse [FeedRepository].
 */
@HiltViewModel
class ProfileViewModel @Inject constructor(
    private val repo: ProfileRepository,
    private val feedRepo: FeedRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(ProfileUiState())
    val state: StateFlow<ProfileUiState> = _state.asStateFlow()

    init {
        load()
        loadPosts()
    }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = it.profile == null, errorMessage = null) }
            runCatching { repo.myProfile() }
                .onSuccess { profile -> _state.update { it.copy(profile = profile, isLoading = false) } }
                .onFailure { error ->
                    _state.update {
                        it.copy(isLoading = false, errorMessage = error.message ?: "Couldn't load your profile.")
                    }
                }
        }
    }

    fun loadPosts() {
        viewModelScope.launch {
            _state.update { it.copy(isLoadingPosts = it.posts.isEmpty()) }
            runCatching { repo.myPosts() }
                .onSuccess { posts -> _state.update { it.copy(posts = posts, isLoadingPosts = false) } }
                .onFailure { _state.update { it.copy(isLoadingPosts = false) } }
        }
    }

    // ─── Settings sheet ──────────────────────────────────────────

    fun openSettings() = _state.update { it.copy(settingsOpen = true) }
    fun closeSettings() = _state.update { it.copy(settingsOpen = false) }

    // ─── Edit-profile sheet ──────────────────────────────────────

    fun openEditor() {
        val profile = _state.value.profile ?: return
        _state.update {
            it.copy(
                settingsOpen = false,
                editor = EditorState(displayName = profile.rawDisplayName, bio = profile.bio),
            )
        }
    }

    fun closeEditor() = _state.update { it.copy(editor = null) }

    /** Upload a freshly-picked photo as the user's avatar. */
    fun updateAvatar(uri: Uri) {
        if (_state.value.editor?.isUploadingAvatar == true) return
        _state.update { s -> s.copy(editor = s.editor?.copy(isUploadingAvatar = true, errorMessage = null)) }
        viewModelScope.launch {
            runCatching { repo.updateAvatar(uri) }
                .onSuccess { newUrl ->
                    _state.update { s ->
                        s.copy(
                            editor = s.editor?.copy(isUploadingAvatar = false),
                            profile = s.profile?.copy(avatarUrl = newUrl),
                        )
                    }
                }
                .onFailure { error ->
                    _state.update { s ->
                        s.copy(
                            editor = s.editor?.copy(
                                isUploadingAvatar = false,
                                errorMessage = error.message ?: "Couldn't update photo.",
                            )
                        )
                    }
                }
        }
    }

    fun setEditorName(value: String) {
        _state.update { s -> s.copy(editor = s.editor?.copy(displayName = value)) }
    }

    fun setEditorBio(value: String) {
        _state.update { s -> s.copy(editor = s.editor?.copy(bio = value)) }
    }

    fun saveProfile() {
        val editor = _state.value.editor ?: return
        if (editor.isSaving) return
        _state.update { s -> s.copy(editor = s.editor?.copy(isSaving = true, errorMessage = null)) }
        viewModelScope.launch {
            runCatching { repo.updateProfile(editor.displayName.trim(), editor.bio.trim()) }
                .onSuccess {
                    _state.update { it.copy(editor = null) }
                    load()
                }
                .onFailure { error ->
                    _state.update { s ->
                        s.copy(editor = s.editor?.copy(isSaving = false, errorMessage = error.message ?: "Couldn't save changes."))
                    }
                }
        }
    }

    // ─── Post interactions ───────────────────────────────────────

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
        _state.update { s -> s.copy(posts = s.posts.map { if (it.id == id) transform(it) else it }) }
    }

    // ─── Sign out ────────────────────────────────────────────────

    fun signOut() = repo.signOut()
}
