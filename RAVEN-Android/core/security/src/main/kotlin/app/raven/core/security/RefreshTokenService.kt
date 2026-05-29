package app.raven.core.security

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import retrofit2.http.Body
import retrofit2.http.Headers
import retrofit2.http.POST

/**
 * Retrofit interface for the refresh-token rotation endpoint on the
 * RAVEN server (`POST /api/auth/refresh`). Lives in this module
 * because the [TokenStore] needs it; everyone else should go through
 * the higher-level auth repository (built in the auth-feature module).
 *
 * The `X-Raven-No-Auth: 1` header tells the [AuthInterceptor] to
 * skip injecting a bearer token on this request — otherwise the
 * interceptor would try to attach the (expired) access token we're
 * trying to refresh, which the server would reject.
 */
interface RefreshTokenService {

    @Headers("X-Raven-No-Auth: 1")
    @POST("api/auth/refresh")
    suspend fun refresh(@Body body: RefreshRequest): RefreshResponse
}

@Serializable
data class RefreshRequest(
    @SerialName("refresh_token") val refreshToken: String,
)

@Serializable
data class RefreshResponse(
    @SerialName("access_token") val accessToken: String,
    @SerialName("refresh_token") val refreshToken: String? = null,
    @SerialName("user_id") val userId: String? = null,
    @SerialName("token_type") val tokenType: String = "bearer",
    @SerialName("expires_in") val expiresIn: Int? = null,
)
