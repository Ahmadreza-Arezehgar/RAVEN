package app.raven.feature.auth.state

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.raven.core.security.TokenStore
import app.raven.feature.auth.data.AuthRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import retrofit2.HttpException
import javax.inject.Inject

/**
 * Single ViewModel that drives every auth screen. The iOS app uses
 * one `@Observable AuthService.shared` for the same role; this is
 * its Compose-friendly twin.
 *
 * Screen-specific input state stays in the composables (it's
 * lifecycle-scoped to the screen), but the network calls + flow
 * routing live here so we can survive recomposition / process death.
 */
@HiltViewModel
class AuthViewModel @Inject constructor(
    private val repo: AuthRepository,
    private val tokenStore: TokenStore,
) : ViewModel() {

    // ─ Loading flag — for button disabled state ───────────────────
    private val _isWorking = MutableStateFlow(false)
    val isWorking: StateFlow<Boolean> = _isWorking.asStateFlow()

    // ─ One-shot UI events ─────────────────────────────────────────
    private val _events = MutableSharedFlow<AuthFlowEvent>(
        replay = 0,
        extraBufferCapacity = 4,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    val events: SharedFlow<AuthFlowEvent> = _events.asSharedFlow()

    // ─ "Have we seen onboarding?" — flips to true when the user
    //   taps "Get Started" / "Skip". Must be a StateFlow (not a
    //   plain var) so [gateState] downstream re-emits the new
    //   AuthGateState; otherwise the screen stays stuck on
    //   onboarding even after the click registers. iOS uses an
    //   `@AppStorage`-backed `@Published Bool` for the same.
    private val _onboardingSeen = MutableStateFlow(false)
    val hasSeenOnboarding: Boolean
        get() = tokenStore.currentUserId() != null || _onboardingSeen.value

    fun markOnboardingSeen() {
        _onboardingSeen.value = true
    }

    /** Best-effort top-level routing — combine the TokenStore flow
     *  + onboarding flag. The [AuthGate] composable subscribes. */
    val gateState: StateFlow<AuthGateState> = combine(
        tokenStore.authState,
        _onboardingSeen,
    ) { auth, seen ->
        when (auth) {
            TokenStore.AuthState.SIGNED_IN -> AuthGateState.SignedIn
            TokenStore.AuthState.SIGNED_OUT,
            TokenStore.AuthState.REFRESH_FAILED -> {
                val effectivelySeen = seen || tokenStore.currentUserId() != null
                if (!effectivelySeen) AuthGateState.Onboarding
                else AuthGateState.Unauthenticated
            }
        }
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.Eagerly,
        initialValue = initial(tokenStore.authState.value),
    )

    private fun initial(s: TokenStore.AuthState): AuthGateState = when (s) {
        TokenStore.AuthState.SIGNED_IN -> AuthGateState.SignedIn
        else -> if (hasSeenOnboarding) AuthGateState.Unauthenticated else AuthGateState.Onboarding
    }

    // ─────────────────────────────────────────────────────────────
    // Actions
    // ─────────────────────────────────────────────────────────────

    fun login(usernameOrEmail: String, password: String) = run {
        when (val outcome = repo.login(usernameOrEmail.trim(), password)) {
            is AuthRepository.AuthOutcome.SignedIn ->
                _events.tryEmit(AuthFlowEvent.SignedIn)
            is AuthRepository.AuthOutcome.UsernameRequired ->
                _events.tryEmit(AuthFlowEvent.UsernameRequired(outcome.tempToken))
        }
    }

    fun register(
        username: String,
        password: String,
        firstName: String,
        lastName: String,
        birthYear: Int,
        email: String,
        phone: String?,
    ) = run {
        repo.register(
            username = username.trim(),
            password = password,
            firstName = firstName.trim(),
            lastName = lastName.trim(),
            birthYear = birthYear,
            email = email.trim(),
            phone = phone?.trim(),
        )
        // Register returns tokens but email isn't verified yet.
        // Push the user to the OTP screen so they can confirm.
        _events.tryEmit(AuthFlowEvent.OtpSent(email = email.trim()))
    }

    fun sendOtp(email: String, purpose: String = "register") = run {
        repo.sendOtp(email.trim(), purpose)
        _events.tryEmit(AuthFlowEvent.OtpSent(email = email.trim()))
    }

    fun verifyOtp(email: String, code: String, purpose: String = "register") = run {
        when (val outcome = repo.verifyOtp(email.trim(), code.trim(), purpose)) {
            is AuthRepository.AuthOutcome.SignedIn ->
                _events.tryEmit(AuthFlowEvent.SignedIn)
            is AuthRepository.AuthOutcome.UsernameRequired ->
                _events.tryEmit(AuthFlowEvent.UsernameRequired(outcome.tempToken))
        }
    }

    fun setUsername(username: String, tempToken: String) = run {
        when (val outcome = repo.setUsername(username.trim(), tempToken)) {
            is AuthRepository.AuthOutcome.SignedIn ->
                _events.tryEmit(AuthFlowEvent.SignedIn)
            is AuthRepository.AuthOutcome.UsernameRequired ->
                _events.tryEmit(AuthFlowEvent.Error("Username still required — please try again."))
        }
    }

    fun oauthGoogle(idToken: String) = run {
        when (val outcome = repo.oauthGoogle(idToken)) {
            is AuthRepository.AuthOutcome.SignedIn ->
                _events.tryEmit(AuthFlowEvent.SignedIn)
            is AuthRepository.AuthOutcome.UsernameRequired ->
                _events.tryEmit(AuthFlowEvent.UsernameRequired(outcome.tempToken))
        }
    }

    fun oauthApple(identityToken: String, code: String?) = run {
        when (val outcome = repo.oauthApple(
            identityToken = identityToken,
            authorizationCode = code,
            givenName = null,
            familyName = null,
        )) {
            is AuthRepository.AuthOutcome.SignedIn ->
                _events.tryEmit(AuthFlowEvent.SignedIn)
            is AuthRepository.AuthOutcome.UsernameRequired ->
                _events.tryEmit(AuthFlowEvent.UsernameRequired(outcome.tempToken))
        }
    }

    fun checkUsername(username: String, onResult: (Boolean) -> Unit) {
        viewModelScope.launch {
            runCatching { repo.checkUsername(username.trim()) }
                .onSuccess(onResult)
                .onFailure { onResult(false) }
        }
    }

    /**
     * Public hook for sub-flows (e.g. [ForgotPasswordScreen]) that
     * own their own coroutine scope but still want their errors
     * surfaced through the same toast pipeline every other screen
     * uses. Wraps the message in an [AuthFlowEvent.Error] and emits
     * onto the shared events channel.
     */
    fun emitError(message: String) {
        _events.tryEmit(AuthFlowEvent.Error(message))
    }

    /**
     * Wraps the suspend body, manages [isWorking], catches HTTP +
     * generic errors, and emits an [AuthFlowEvent.Error] on failure.
     * Keeps every action above to a single readable expression.
     */
    private fun run(body: suspend () -> Unit) {
        viewModelScope.launch {
            _isWorking.value = true
            try {
                body()
            } catch (http: HttpException) {
                val msg = http.response()?.errorBody()?.string()?.takeIf { it.isNotBlank() }
                    ?: "Request failed (HTTP ${http.code()})."
                _events.tryEmit(AuthFlowEvent.Error(msg))
            } catch (t: Throwable) {
                _events.tryEmit(AuthFlowEvent.Error(t.message ?: "Something went wrong."))
            } finally {
                _isWorking.value = false
            }
        }
    }
}
