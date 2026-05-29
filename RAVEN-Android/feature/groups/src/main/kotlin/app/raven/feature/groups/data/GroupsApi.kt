package app.raven.feature.groups.data

import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.Query

/**
 * Retrofit binding for group creation + the member-picker sources.
 */
interface GroupsApi {

    /** Create a group. Server auto-adds the creator as admin. */
    @POST("api/groups")
    suspend fun createGroup(@Body body: CreateGroupRequest): GroupResponse

    /** The signed-in user's friends — primary member-picker source. */
    @GET("api/users/friends")
    suspend fun getFriends(): List<FriendDto>

    /** User search — picker fallback. Server requires `q` ≥ 2 chars. */
    @GET("api/users/search")
    suspend fun searchUsers(@Query("q") query: String): List<UserSearchDto>
}
