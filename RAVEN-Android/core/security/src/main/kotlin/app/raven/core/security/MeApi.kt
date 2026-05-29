package app.raven.core.security

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import retrofit2.http.GET

/**
 * Minimal `/api/users/me` binding — used only by the [TokenStore]
 * bootstrap to verify that a token loaded from disk is still valid.
 *
 * The bigger profile module (Phase 2) will register its own
 * fuller `UsersApi` interface with PATCH /me, /me/posts, etc.; we
 * keep this one tiny so the security module doesn't grow tendrils
 * into UI-state types it doesn't own.
 */
interface MeApi {
    @GET("api/users/me")
    suspend fun me(): MeResponse
}

@Serializable
data class MeResponse(
    val id: String,
    val username: String? = null,
    val email: String? = null,
    @SerialName("first_name") val firstName: String? = null,
    @SerialName("last_name") val lastName: String? = null,
    @SerialName("email_verified") val emailVerified: Boolean = false,
    @SerialName("phone_verified") val phoneVerified: Boolean = false,
    @SerialName("is_premium") val isPremium: Boolean = false,
    @SerialName("is_verified") val isVerified: Boolean = false,
    /**
     * Server sets this to `true` immediately after OAuth signup
     * when the user hasn't picked a handle yet. The bootstrap
     * forwards it to the auth gate.
     */
    @SerialName("requires_username") val requiresUsername: Boolean = false,
)
