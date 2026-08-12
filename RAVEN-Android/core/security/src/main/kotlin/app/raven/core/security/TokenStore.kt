package app.raven.core.security

import app.raven.core.network.TokenProvider
import dagger.Lazy
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Concrete [TokenProvider] backed by [SecureStore]. This is what the
 * [app.raven.core.network.AuthInterceptor] calls into when it needs
 * a bearer token.
 *
 * Three responsibilities:
 *   1. Hand out the current access token (sync read of the secure store).
 *   2. Refresh that token when it expires, via `POST /api/auth/refresh`.
 *      We hold a [Mutex] so concurrent 401s from different requests
 *      don't fire N parallel refreshes — only one wins, the rest wait
 *      and use its result.
 *   3. Publish auth state via [authState] so the navigation graph can
 *      kick the user to the auth gate when refresh fails.
 *
 * The actual `POST /api/auth/refresh` call lives in
 * [RefreshTokenService] (a Retrofit interface) so this class stays
 * UI-test-friendly — swap in a fake service in tests, skip the network.
 */
@Singleton
class TokenStore @Inject constructor(
    private val secureStore: SecureStore,
    private val refreshService: RefreshTokenService,
    /**
     * Lazy so the graph
     *   TokenStore → TokenProvider → AuthInterceptor → OkHttp →
     *     Retrofit → MeApi → TokenStore
     * doesn't trip Dagger's cycle detector. MeApi is only used
     * inside [bootstrap], which runs after construction.
     */
    private val meApi: Lazy<MeApi>,
    private val identityKeyService: IdentityKeyService,
    private val signOutHooks: Set<@JvmSuppressWildcards SignOutHooks>,
) : TokenProvider {

    private val mutex = Mutex()
    private val _authState = MutableStateFlow(currentState())
    val authState: StateFlow<AuthState> = _authState.asStateFlow()

    /**
     * Booted-up flag — set after the first bootstrap call returns.
     * The auth gate uses this to render the splash instead of the
     * landing screen during the brief window between cold-start and
     * the /users/me round-trip.
     */
    private val _isBootstrapped = MutableStateFlow(false)
    val isBootstrapped: StateFlow<Boolean> = _isBootstrapped.asStateFlow()

    /** Set to true after the bootstrap learns the user needs to
     *  pick a handle. The auth gate routes accordingly. */
    private val _requiresUsername = MutableStateFlow(false)
    val requiresUsername: StateFlow<Boolean> = _requiresUsername.asStateFlow()

    enum class AuthState { SIGNED_OUT, SIGNED_IN, REFRESH_FAILED }

    /** Read of the current access token. Suspending only because the
     *  interface requires it; the underlying read is sync. */
    override suspend fun accessToken(): String? =
        secureStore.getString(SecureStore.KEY_ACCESS_TOKEN)

    /** Force-refresh. The mutex serialises concurrent 401-retry races. */
    override suspend fun refreshAccessToken(): String? = mutex.withLock {
        val refresh = secureStore.getString(SecureStore.KEY_REFRESH_TOKEN)
            ?: run {
                _authState.value = AuthState.SIGNED_OUT
                return@withLock null
            }

        return@withLock try {
            val resp = refreshService.refresh(RefreshRequest(refresh))
            saveTokens(resp.accessToken, resp.refreshToken ?: refresh, resp.userId)
            _authState.value = AuthState.SIGNED_IN
            resp.accessToken
        } catch (t: Throwable) {
            // 401 → refresh token revoked/expired. Anything else
            // (network blip, 5xx) is transient; we don't clear local
            // tokens so the next call can retry.
            if (t is retrofit2.HttpException && t.code() == 401) {
                signOutLocally()
                _authState.value = AuthState.REFRESH_FAILED
            }
            null
        }
    }

    /** Called by the login/OAuth flow to seed the store. */
    fun saveTokens(access: String, refresh: String, userId: String?) {
        secureStore.putString(SecureStore.KEY_ACCESS_TOKEN, access)
        secureStore.putString(SecureStore.KEY_REFRESH_TOKEN, refresh)
        userId?.let { secureStore.putString(SecureStore.KEY_USER_ID, it) }
        _authState.value = AuthState.SIGNED_IN
    }

    /** Sync helper — used by app startup to read user_id without
     *  awaiting a coroutine. */
    fun currentUserId(): String? = secureStore.getString(SecureStore.KEY_USER_ID)

    /**
     * One-shot bootstrap. Called once on app launch — equivalent of
     * the iOS `AuthService.bootstrapFromKeychain()` pass:
     *   • If there's no stored access token, mark bootstrapped and
     *     return; the auth gate shows the landing screen.
     *   • If a token exists, hit `/api/users/me` to confirm it's
     *     still valid. On 200 → stay signed-in. On 401 (the
     *     interceptor will have already tried a refresh on our
     *     behalf and given up) → clear local state.
     *   • Any other error (network blip, 5xx) — keep the stored
     *     state. The user is shown the main shell, and individual
     *     API calls will surface their own errors.
     * Idempotent — repeated calls do nothing after the first.
     */
    suspend fun bootstrap() {
        if (_isBootstrapped.value) return
        val token = secureStore.getString(SecureStore.KEY_ACCESS_TOKEN)
        if (token.isNullOrEmpty()) {
            _isBootstrapped.value = true
            return
        }
        try {
            val me = meApi.get().me()
            if (me.requiresUsername) {
                // Stranded OAuth signup — the user got a session but
                // never picked a handle. Sign them out so the next
                // launch puts them back in the OAuth flow with a
                // fresh temp_token (set-username needs the temp_token
                // from the OAuth response, not the long-lived
                // access token).
                signOutLocally()
                return
            }
            _requiresUsername.value = false
            _authState.value = AuthState.SIGNED_IN
        } catch (http: retrofit2.HttpException) {
            if (http.code() == 401) {
                signOutLocally()
                _authState.value = AuthState.REFRESH_FAILED
            }
            // Other HTTP errors (5xx etc.) — keep the user signed-in
            // optimistically; per-feature calls will surface failures.
        } catch (_: Throwable) {
            // Network unreachable — same posture as iOS. Don't kick
            // the user out just because we're offline at launch.
        } finally {
            _isBootstrapped.value = true
        }
    }

    /** Clear local state (logout). Server-side /auth/logout should
     *  have already revoked the refresh token before this is called;
     *  if not, the token sits in the DB until natural expiry. */
    fun signOutLocally() {
        secureStore.remove(SecureStore.KEY_ACCESS_TOKEN)
        secureStore.remove(SecureStore.KEY_REFRESH_TOKEN)
        secureStore.remove(SecureStore.KEY_USER_ID)
        // 🔒 SECURITY (audit H3 — cross-account key/session reuse):
        // purge ALL E2EE identity + session material on sign-out.
        // Previously only the three token keys were cleared, so a
        // different account signing in on the same device inherited
        // the previous user's Ed25519/X25519 identity keypair, signed
        // prekey, and every live per-peer session — able to read and
        // continue the prior user's conversations under their identity.
        // Wiping identity.* forces fresh keys on next sign-in;
        // removeByPrefix("e2ee.") clears cached sessions
        // (e2ee.session.*), the signed prekey (e2ee.spk.*), the
        // published-bundle flag, and the device id.
        // Also: IdentityKeyService.reset() + SignOutHooks (SessionStore
        // in-process cache) so sign-out→sign-in without process restart
        // cannot reuse prior crypto state. DB cipher key preserved
        // (message-cache wipe tracked separately).
        secureStore.remove(SecureStore.KEY_IDENTITY_ED25519_PRIV)
        secureStore.remove(SecureStore.KEY_IDENTITY_X25519_PRIV)
        secureStore.removeByPrefix("e2ee.")
        identityKeyService.reset()
        for (hook in signOutHooks) {
            runCatching { hook.onLocalSignOut() }
        }
        _authState.value = AuthState.SIGNED_OUT
    }

    private fun currentState(): AuthState =
        if (secureStore.getString(SecureStore.KEY_ACCESS_TOKEN) != null) {
            AuthState.SIGNED_IN
        } else AuthState.SIGNED_OUT
}
