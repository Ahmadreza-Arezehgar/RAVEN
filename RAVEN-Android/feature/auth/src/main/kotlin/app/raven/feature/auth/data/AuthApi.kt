package app.raven.feature.auth.data

import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.Headers
import retrofit2.http.POST
import retrofit2.http.Query

/**
 * Retrofit binding for the nine /api/auth/X endpoints the iOS app
 * uses. Mirror of `Features/Auth/AuthService.swift` on iOS.
 *
 * Every method here is annotated with `X-Raven-No-Auth: 1` because
 * these are pre-auth flows — the [`AuthInterceptor`] strips that
 * header and skips bearer-token injection. The two endpoints that
 * DO need a token (set-username uses a `temp_token` in the body,
 * not the bearer header) are explicitly noted.
 */
interface AuthApi {

    @Headers("X-Raven-No-Auth: 1")
    @POST("api/auth/register")
    suspend fun register(@Body body: RegisterRequest): AuthTokenResponse

    @Headers("X-Raven-No-Auth: 1")
    @POST("api/auth/login")
    suspend fun login(@Body body: LoginRequest): AuthTokenResponse

    @Headers("X-Raven-No-Auth: 1")
    @POST("api/auth/send-code")
    suspend fun sendCode(@Body body: SendCodeRequest)

    @Headers("X-Raven-No-Auth: 1")
    @POST("api/auth/verify-code")
    suspend fun verifyCode(@Body body: VerifyCodeRequest): AuthTokenResponse

    @Headers("X-Raven-No-Auth: 1")
    @POST("api/auth/reset-password")
    suspend fun resetPassword(@Body body: ResetPasswordRequest)

    @Headers("X-Raven-No-Auth: 1")
    @POST("api/auth/oauth/google")
    suspend fun oauthGoogle(@Body body: GoogleOAuthRequest): AuthTokenResponse

    @Headers("X-Raven-No-Auth: 1")
    @POST("api/auth/oauth/apple")
    suspend fun oauthApple(@Body body: AppleOAuthRequest): AuthTokenResponse

    /** Carries its own `temp_token` in the body — no bearer needed. */
    @Headers("X-Raven-No-Auth: 1")
    @POST("api/auth/set-username")
    suspend fun setUsername(@Body body: SetUsernameRequest): AuthTokenResponse

    /** Server-side rate-limited to 30/min per IP (round-5 fix). */
    @Headers("X-Raven-No-Auth: 1")
    @GET("api/auth/check-username")
    suspend fun checkUsername(@Query("username") username: String): UsernameAvailabilityResponse
}
