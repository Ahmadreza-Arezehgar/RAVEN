package app.raven

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.raven.core.design.RavenTheme
import app.raven.core.security.TokenStore
import app.raven.feature.chat.data.ChatRepository
import app.raven.feature.e2ee.PrekeyBundleService
import app.raven.feature.e2ee.PrekeyRotationScheduler
import app.raven.nav.RavenNavGraph
import dagger.hilt.android.AndroidEntryPoint
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Single activity. Compose owns every screen via the
 * [RavenNavGraph] navigation graph; activity is just the OS-level
 * host.
 *
 * Edge-to-edge is on so the iOS-style full-bleed glass works — the
 * theme already declares transparent status/nav bar.
 */
@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        // Installs the Android-12 splash screen AND applies the
        // `postSplashScreenTheme` (Theme.Raven, NoActionBar). Without
        // this call the activity keeps the splash theme — which has an
        // ActionBar — and a stray light "RAVEN" title bar shows on
        // every screen.
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        setContent {
            RavenTheme {
                val rootVm: RootViewModel = hiltViewModel()
                val authState by rootVm.authState.collectAsState()
                val isBootstrapped by rootVm.isBootstrapped.collectAsState()
                RavenNavGraph(authState = authState, isBootstrapped = isBootstrapped)
            }
        }
    }
}

/**
 * Process-level VM. Responsibilities:
 *   1. Fire the [TokenStore.bootstrap] one-shot on cold start so
 *      the auth gate doesn't flash the wrong screen
 *   2. Tie the /ws/inbox WebSocket lifecycle to the auth state —
 *      connect on SIGNED_IN, disconnect on SIGNED_OUT /
 *      REFRESH_FAILED. iOS does the equivalent in
 *      `AuthService.bootStateDidChange` + `RealtimeService.start`
 *   3. **Phase 2f**: on SIGNED_IN, ensure the e2ee prekey bundle is
 *      published + schedule the SPK rotation worker. On sign-out,
 *      cancel the worker so a new account doesn't inherit the old
 *      user's rotation cadence
 */
@HiltViewModel
class RootViewModel @Inject constructor(
    private val tokenStore: TokenStore,
    private val chatRepo: ChatRepository,
    private val prekeyBundleService: PrekeyBundleService,
    private val prekeyRotationScheduler: PrekeyRotationScheduler,
) : ViewModel() {
    val authState: StateFlow<TokenStore.AuthState> = tokenStore.authState
    val isBootstrapped: StateFlow<Boolean> = tokenStore.isBootstrapped

    init {
        viewModelScope.launch {
            tokenStore.bootstrap()
        }
        viewModelScope.launch {
            // Mirror the auth state into the realtime + e2ee lifecycle.
            // We collect on the same VM scope so cleanup happens
            // automatically on process death.
            authState.collect { state ->
                when (state) {
                    TokenStore.AuthState.SIGNED_IN -> {
                        chatRepo.startRealtime()
                        // Phase 2f — publish bundle if needed, then
                        // arm the 24h rotation worker. The publish
                        // call is idempotent; the scheduler dedups
                        // via KEEP-policy unique work.
                        prekeyBundleService.ensurePublished()
                        prekeyRotationScheduler.schedule()
                    }
                    TokenStore.AuthState.SIGNED_OUT,
                    TokenStore.AuthState.REFRESH_FAILED -> {
                        chatRepo.stopRealtime()
                        prekeyRotationScheduler.cancel()
                    }
                }
            }
        }
    }
}
