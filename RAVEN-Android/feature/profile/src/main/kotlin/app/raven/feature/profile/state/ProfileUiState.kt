package app.raven.feature.profile.state

import app.raven.feature.feed.data.Post
import app.raven.feature.profile.data.UserProfile

/** UI model for the Profile tab. */
data class ProfileUiState(
    val profile: UserProfile? = null,
    val isLoading: Boolean = true,
    val errorMessage: String? = null,
    /** The signed-in user's own posts. */
    val posts: List<Post> = emptyList(),
    val isLoadingPosts: Boolean = false,
    /** True while the settings bottom sheet is open. */
    val settingsOpen: Boolean = false,
    /** Non-null while the edit-profile sheet is open. */
    val editor: EditorState? = null,
)

/** State for the edit-profile bottom sheet. */
data class EditorState(
    val displayName: String = "",
    val bio: String = "",
    val isSaving: Boolean = false,
    /** True while a newly-picked avatar is uploading. */
    val isUploadingAvatar: Boolean = false,
    val errorMessage: String? = null,
)
