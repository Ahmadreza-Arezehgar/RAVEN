package app.raven.feature.feed.data

import retrofit2.http.Body
import retrofit2.http.DELETE
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.Path
import retrofit2.http.Query

/**
 * Retrofit binding for the feed endpoints. Mirror of the iOS
 * `NetworkService` post methods.
 *
 * Note: the "Local" tab uses [globalFeed] (`/api/posts/feed`) until
 * device location is wired up — `/api/posts/feed/local` returns an
 * empty list without `lat`/`lng`, which would be a dead first tab.
 * Swap to a `localFeed(lat, lng)` call once the location permission
 * flow lands.
 */
interface FeedApi {

    /** Global public feed — chronological, no location required. */
    @GET("api/posts/feed")
    suspend fun globalFeed(
        @Query("limit") limit: Int = 50,
        @Query("offset") offset: Int = 0,
    ): List<PostDto>

    /** Friends-only feed — posts from accepted friends + self. */
    @GET("api/posts/feed/friends")
    suspend fun friendsFeed(
        @Query("limit") limit: Int = 50,
        @Query("offset") offset: Int = 0,
    ): FeedPageDto

    @POST("api/posts/{postId}/like")
    suspend fun toggleLike(@Path("postId") postId: String): LikeResponseDto

    @POST("api/posts/{postId}/repost")
    suspend fun toggleRepost(
        @Path("postId") postId: String,
        @Body body: RepostRequestBody = RepostRequestBody(),
    ): RepostResponseDto

    @GET("api/comments/post/{postId}")
    suspend fun getComments(@Path("postId") postId: String): List<CommentDto>

    @POST("api/comments/create")
    suspend fun createComment(@Body body: CreateCommentRequest): CommentDto

    @POST("api/posts/create")
    suspend fun createPost(@Body body: CreatePostRequest): PostDto

    @POST("api/posts/{postId}/bookmark")
    suspend fun bookmark(@Path("postId") postId: String): BookmarkResponseDto

    @DELETE("api/posts/{postId}/bookmark")
    suspend fun unbookmark(@Path("postId") postId: String): BookmarkResponseDto

    /** Post IDs the signed-in user has bookmarked. */
    @GET("api/posts/me/bookmarks")
    suspend fun bookmarks(@Query("limit") limit: Int = 200): BookmarksPageDto
}
