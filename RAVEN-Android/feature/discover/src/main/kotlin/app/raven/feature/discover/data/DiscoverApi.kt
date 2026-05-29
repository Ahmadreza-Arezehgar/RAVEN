package app.raven.feature.discover.data

import app.raven.feature.feed.data.PostDto
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.Query

/**
 * Retrofit binding for the Discover endpoints.
 */
interface DiscoverApi {

    /** Personalised friend suggestions for the idle state. */
    @GET("api/discovery/suggested")
    suspend fun suggested(@Query("limit") limit: Int = 20): SuggestedFriendsResponse

    /** User search. Server requires `q` to be at least 2 characters. */
    @GET("api/users/search")
    suspend fun searchUsers(@Query("q") query: String): List<UserSearchDto>

    /** Post search — server's `PostSearchResponse` is a subset of the
     *  feed's `PostResponse`, so the feed [PostDto] decodes it. */
    @GET("api/search/posts")
    suspend fun searchPosts(@Query("q") query: String): List<PostDto>

    /** Send a friend request. Body is empty — recipient is a query param. */
    @POST("api/users/friend-request")
    suspend fun sendFriendRequest(@Query("recipient_id") recipientId: String)
}
