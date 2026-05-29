package app.raven.feature.profile.data

import android.content.Context
import android.net.Uri
import app.raven.core.security.TokenStore
import app.raven.feature.feed.data.Post
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.RequestBody.Companion.toRequestBody
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Profile repository — network-backed. Resolves the signed-in user
 * via [TokenStore], fetches their profile + posts, handles edit + sign-out.
 */
@Singleton
class ProfileRepository @Inject constructor(
    private val api: ProfileApi,
    private val tokenStore: TokenStore,
    @ApplicationContext private val context: Context,
) {

    /** Load the signed-in user's own profile (+ stats). */
    suspend fun myProfile(): UserProfile {
        val id = tokenStore.currentUserId()
            ?: throw IllegalStateException("Not signed in.")
        return UserProfile.from(api.getProfile(id))
    }

    /** Load the signed-in user's own posts. */
    suspend fun myPosts(): List<Post> {
        val id = tokenStore.currentUserId()
            ?: throw IllegalStateException("Not signed in.")
        return api.getUserPosts(id).map { Post.from(it) }
    }

    suspend fun updateProfile(displayName: String, bio: String) {
        api.updateProfile(ProfileUpdateRequest(displayName = displayName, bio = bio))
    }

    /**
     * Upload [uri] as the signed-in user's new avatar and return the
     * stored URL. Two server hops — `POST /api/uploads/image` to store
     * the bytes, then `POST /api/users/profile-picture` to point the
     * account at the resulting URL. The stream read runs off the main
     * thread.
     */
    suspend fun updateAvatar(uri: Uri): String = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val mime = resolver.getType(uri).orEmpty()
        val bytes = resolver.openInputStream(uri)?.use { it.readBytes() }
            ?: throw IllegalStateException("Couldn't read the selected image.")
        // The server checks the file extension before sniffing the
        // content, so the part needs a name with an allowed suffix.
        val (ext, sendMime) = when {
            mime.contains("png") -> "png" to "image/png"
            mime.contains("webp") -> "webp" to "image/webp"
            else -> "jpg" to "image/jpeg"
        }
        val part = MultipartBody.Part.createFormData(
            name = "file",
            filename = "avatar.$ext",
            body = bytes.toRequestBody(sendMime.toMediaType()),
        )
        val uploaded = api.uploadImage(part)
        val updated = api.updateProfilePicture(ProfilePictureRequest(imageUrl = uploaded.imageUrl))
        updated.avatarPath ?: uploaded.imageUrl
    }

    /** Clear the local session — the nav graph reacts to the auth-state flip. */
    fun signOut() {
        tokenStore.signOutLocally()
    }
}
