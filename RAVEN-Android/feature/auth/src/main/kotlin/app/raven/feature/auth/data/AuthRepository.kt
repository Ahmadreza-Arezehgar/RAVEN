package app.raven.feature.auth.data

import app.raven.core.security.TokenStore
import retrofit2.HttpException
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Thin layer over [AuthApi] that handles password stretching +
 * persisting tokens via [TokenStore]. ViewModels call into this;
 * they never touch the Retrofit interface directly.
 *
 * Mirror of the iOS `AuthService` async methods — but the local
 * state lives in [app.raven.feature.auth.state.AuthViewModel] rather
 * than this class, so the repo stays stateless and easy to unit-test.
 */
@Singleton
class AuthRepository @Inject constructor(
    private val api: AuthApi,
    private val tokenStore: TokenStore,
) {

    /** Result of any auth call. We collapse "OK" + "needs username"
     *  into one type so callers branch on a single value. */
    sealed interface AuthOutcome {
        /** Done — tokens saved, user is signed in. */
        data class SignedIn(val userId: String?) : AuthOutcome

        /** OAuth user has no username yet. Caller MUST show
         *  UsernameSelectionScreen with the [tempToken]. */
        data class UsernameRequired(val tempToken: String) : AuthOutcome
    }

    suspend fun register(
        username: String,
        password: String,
        firstName: String,
        lastName: String,
        birthYear: Int,
        email: String,
        phone: String?,
    ): AuthOutcome {
        val stretched = PasswordStretcher.stretch(password, username.lowercase())
        val resp = api.register(
            RegisterRequest(
                username = username,
                password = stretched,
                firstName = firstName,
                lastName = lastName,
                birthYear = birthYear,
                email = email,
                phone = phone,
            )
        )
        return persistTokens(resp)
    }

    suspend fun login(usernameOrEmail: String, password: String): AuthOutcome {
        // Primary path: client-side stretched password (matches the
        // iOS PasswordStretcher). App-registered accounts store
        // bcrypt(stretched), so this is what they expect.
        val stretched = PasswordStretcher.stretch(password, usernameOrEmail.lowercase())
        val resp = try {
            api.login(LoginRequest(username = usernameOrEmail, password = stretched))
        } catch (e: HttpException) {
            // A 401 means the stored hash isn't bcrypt(stretched).
            // Legacy / seed-script accounts predate client-side
            // stretching and store bcrypt(raw password) — retry once
            // with the raw value before giving up.
            if (e.code() == 401) {
                api.login(LoginRequest(username = usernameOrEmail, password = password))
            } else {
                throw e
            }
        }
        return persistTokens(resp)
    }

    suspend fun sendOtp(email: String, purpose: String = "register") {
        api.sendCode(SendCodeRequest(email = email, purpose = purpose))
    }

    suspend fun verifyOtp(email: String, code: String, purpose: String = "register"): AuthOutcome {
        val resp = api.verifyCode(VerifyCodeRequest(email = email, code = code, purpose = purpose))
        return persistTokens(resp)
    }

    suspend fun resetPassword(email: String, code: String, newPassword: String) {
        // For reset we don't know the username (the user typed
        // their email), so stretch with the email lowercased — that
        // matches the iOS path for the reset-password endpoint.
        val stretched = PasswordStretcher.stretch(newPassword, email.lowercase())
        api.resetPassword(ResetPasswordRequest(email = email, code = code, newPassword = stretched))
    }

    suspend fun oauthGoogle(idToken: String): AuthOutcome {
        val resp = api.oauthGoogle(GoogleOAuthRequest(idToken = idToken))
        return persistTokens(resp)
    }

    suspend fun oauthApple(
        identityToken: String,
        authorizationCode: String?,
        givenName: String?,
        familyName: String?,
    ): AuthOutcome {
        val name = if (givenName != null || familyName != null) {
            AppleNameDto(givenName = givenName, familyName = familyName)
        } else null
        val resp = api.oauthApple(
            AppleOAuthRequest(
                identityToken = identityToken,
                authorizationCode = authorizationCode,
                fullName = name,
            )
        )
        return persistTokens(resp)
    }

    suspend fun setUsername(username: String, tempToken: String): AuthOutcome {
        val resp = api.setUsername(SetUsernameRequest(username = username, tempToken = tempToken))
        return persistTokens(resp)
    }

    suspend fun checkUsername(username: String): Boolean =
        api.checkUsername(username).available

    fun signOut() {
        tokenStore.signOutLocally()
        // /api/auth/logout server call is a follow-up — the iOS app
        // fires it best-effort. We mirror that in Phase 2 when we
        // have a full settings flow.
    }

    private fun persistTokens(resp: AuthTokenResponse): AuthOutcome {
        return if (resp.requiresUsername && resp.tempToken != null) {
            AuthOutcome.UsernameRequired(resp.tempToken)
        } else {
            tokenStore.saveTokens(
                access = resp.accessToken,
                refresh = resp.refreshToken ?: resp.accessToken,
                userId = resp.userId,
            )
            AuthOutcome.SignedIn(resp.userId)
        }
    }
}
