package app.raven.feature.auth.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Wire-format DTOs for the /api/auth/X family. Every type maps 1-1 to the
 * Pydantic schema in `server/routers/auth.py`.
 *
 * Field naming: server is snake_case, Kotlin is camelCase, so each
 * `@SerialName` carries the on-the-wire name. We never let the
 * client decide JSON layout — the server is the source of truth.
 */

// ── Register ─────────────────────────────────────────────────────

@Serializable
data class RegisterRequest(
    val username: String,
    /** Already PBKDF2-stretched on the device — see [PasswordStretcher]. */
    val password: String,
    @SerialName("first_name") val firstName: String,
    @SerialName("last_name") val lastName: String,
    @SerialName("birth_year") val birthYear: Int,
    val email: String,
    val phone: String? = null,
)

// ── Login ────────────────────────────────────────────────────────

@Serializable
data class LoginRequest(
    /** Server accepts username OR email here. */
    val username: String,
    /** Stretched (same way as register). */
    val password: String,
)

// ── Token response (shared by register / login / oauth) ──────────

@Serializable
data class AuthTokenResponse(
    /** Server's JSON key is `token` (see `TokenResponse` + the login
     *  handler dict in `server/routers/auth.py`), NOT `access_token`. */
    @SerialName("token") val accessToken: String,
    @SerialName("refresh_token") val refreshToken: String? = null,
    @SerialName("token_type") val tokenType: String = "bearer",
    @SerialName("user_id") val userId: String? = null,
    /** True when an OAuth user has no username yet — the client
     *  must show UsernameSelectionScreen before anything else. */
    @SerialName("requires_username") val requiresUsername: Boolean = false,
    /** Only set when `requires_username == true`; this is the
     *  short-lived token the client passes to `/set-username`. */
    @SerialName("temp_token") val tempToken: String? = null,
)

// ── OTP ──────────────────────────────────────────────────────────

@Serializable
data class SendCodeRequest(
    val email: String,
    /** "register" | "login" | "reset". Server-side enums. */
    val purpose: String = "register",
)

@Serializable
data class VerifyCodeRequest(
    val email: String,
    val code: String,
    val purpose: String = "register",
)

@Serializable
data class ResetPasswordRequest(
    val email: String,
    val code: String,
    @SerialName("new_password") val newPassword: String,
)

// ── OAuth ────────────────────────────────────────────────────────

@Serializable
data class GoogleOAuthRequest(
    @SerialName("id_token") val idToken: String,
)

@Serializable
data class AppleOAuthRequest(
    @SerialName("identity_token") val identityToken: String,
    @SerialName("authorization_code") val authorizationCode: String? = null,
    @SerialName("full_name") val fullName: AppleNameDto? = null,
)

@Serializable
data class AppleNameDto(
    @SerialName("given_name") val givenName: String?,
    @SerialName("family_name") val familyName: String?,
)

// ── Set username (post-OAuth) ────────────────────────────────────

@Serializable
data class SetUsernameRequest(
    val username: String,
    /** The short-lived token from [AuthTokenResponse.tempToken]. */
    @SerialName("temp_token") val tempToken: String,
)

// ── Check username availability ──────────────────────────────────

@Serializable
data class UsernameAvailabilityResponse(
    val available: Boolean,
)
