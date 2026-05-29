package app.raven.feature.profile.data

import app.raven.feature.feed.data.PostDto
import okhttp3.MultipartBody
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.Multipart
import retrofit2.http.PATCH
import retrofit2.http.POST
import retrofit2.http.Part
import retrofit2.http.Path

/**
 * Retrofit binding for the user-profile endpoints.
 */
interface ProfileApi {

    /** Full profile + stats. For the signed-in user, pass their own id. */
    @GET("api/users/{userId}/profile")
    suspend fun getProfile(@Path("userId") userId: String): FullProfileDto

    /** A user's own posts — server returns the standard `PostResponse`,
     *  so we reuse the feed's [PostDto]. */
    @GET("api/posts/user/{userId}")
    suspend fun getUserPosts(@Path("userId") userId: String): List<PostDto>

    /** Update the signed-in user's profile. Response body is ignored. */
    @PATCH("api/users/me")
    suspend fun updateProfile(@Body body: ProfileUpdateRequest)

    /** Upload an image — multipart form field `file`. Returns its URL. */
    @Multipart
    @POST("api/uploads/image")
    suspend fun uploadImage(@Part file: MultipartBody.Part): UploadImageResponse

    /** Point the signed-in user's avatar at an already-uploaded image URL. */
    @POST("api/users/profile-picture")
    suspend fun updateProfilePicture(@Body body: ProfilePictureRequest): ProfilePictureResponse
}
