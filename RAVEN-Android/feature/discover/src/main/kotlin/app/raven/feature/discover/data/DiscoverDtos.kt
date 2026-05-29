package app.raven.feature.discover.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Wire DTOs for the Discover endpoints.
 *
 * - GET /api/discovery/suggested → [SuggestedFriendsResponse]
 * - GET /api/users/search?q=     → List<[UserSearchDto]>
 * Mirrors the Pydantic models in `server/routers/discovery.py` and
 * the `UserSearchResult` model in `server/routers/users.py`.
 */

@Serializable
data class SuggestedUserDto(
    @SerialName("user_id") val userId: String,
    val username: String,
    @SerialName("display_name") val displayName: String = "",
    @SerialName("avatar_url") val avatarUrl: String? = null,
    val source: String = "",
    val reason: String = "",
    @SerialName("mutual_friends_count") val mutualFriendsCount: Int = 0,
)

@Serializable
data class SuggestedFriendsResponse(
    val items: List<SuggestedUserDto> = emptyList(),
)

/** A row from GET /api/users/search — the server's `UserSearchResult`. */
@Serializable
data class UserSearchDto(
    val id: String,
    val username: String,
    @SerialName("display_name") val displayName: String? = null,
    @SerialName("avatar_url") val avatarUrl: String? = null,
    @SerialName("is_verified") val isVerified: Boolean = false,
    @SerialName("is_premium") val isPremium: Boolean = false,
)
