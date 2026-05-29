package app.raven.feature.groups.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Wire DTOs for the /api/groups family.
 *
 * One-to-one with the Pydantic types in `server/routers/groups.py`.
 * Unlike the /api/messages endpoints, the groups router is entirely
 * snake_case on the wire — every field needs an explicit @SerialName.
 */

/** Body for POST /api/groups. `memberIds` may be empty — the server
 *  auto-adds the creator as admin. */
@Serializable
data class CreateGroupRequest(
    val name: String,
    @SerialName("member_ids") val memberIds: List<String>,
    @SerialName("avatar_url") val avatarUrl: String? = null,
    val description: String? = null,
)

/** Response from POST /api/groups and GET /api/groups/{id}. */
@Serializable
data class GroupResponse(
    val id: String,
    val name: String,
    @SerialName("avatar_url") val avatarUrl: String? = null,
    val description: String? = null,
    @SerialName("member_count") val memberCount: Int = 0,
)

/** Item from GET /api/users/friends — the member-picker source. */
@Serializable
data class FriendDto(
    val id: String,
    val username: String,
    @SerialName("display_name") val displayName: String? = null,
    @SerialName("avatar_path") val avatarPath: String? = null,
)

/** Item from GET /api/users/search (`UserProfile`) — picker fallback. */
@Serializable
data class UserSearchDto(
    val id: String,
    val username: String,
    @SerialName("avatar_path") val avatarPath: String? = null,
)
