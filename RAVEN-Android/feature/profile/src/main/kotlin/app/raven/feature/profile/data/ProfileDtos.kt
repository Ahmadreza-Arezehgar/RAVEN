package app.raven.feature.profile.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Wire DTOs for the /api/users profile endpoints.
 *
 * `GET /api/users/{id}/profile` returns a camelCase JSON object (see
 * the hand-built dict in `get_user_full_profile`, server/routers/users.py),
 * so the field names map straight through with no @SerialName.
 */
@Serializable
data class FullProfileDto(
    val id: String,
    val username: String,
    val displayName: String? = null,
    val avatarUrl: String? = null,
    val bio: String? = null,
    val joinedAt: String? = null,
    val isVerified: Boolean = false,
    val isPremium: Boolean = false,
    val postsCount: Int = 0,
    val friendsCount: Int = 0,
)

/** Body for PATCH /api/users/me — the server's `ProfileUpdate` model
 *  is snake_case. Null fields are dropped (Json `explicitNulls=false`). */
@Serializable
data class ProfileUpdateRequest(
    @SerialName("display_name") val displayName: String? = null,
    val bio: String? = null,
)

/** Response from POST /api/uploads/image — `{image_url, filename}`. */
@Serializable
data class UploadImageResponse(
    @SerialName("image_url") val imageUrl: String,
    val filename: String? = null,
)

/** Body for POST /api/users/profile-picture. */
@Serializable
data class ProfilePictureRequest(
    @SerialName("image_url") val imageUrl: String,
)

/** Response from POST /api/users/profile-picture — server returns the
 *  `UserProfile` shape; we only need the stored avatar path back. */
@Serializable
data class ProfilePictureResponse(
    @SerialName("avatar_path") val avatarPath: String? = null,
)
