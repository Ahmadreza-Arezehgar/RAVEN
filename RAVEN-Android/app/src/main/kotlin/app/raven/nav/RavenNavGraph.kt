package app.raven.nav

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import app.raven.core.design.Spacing
import app.raven.core.security.TokenStore
import app.raven.feature.auth.ui.AuthGate
import app.raven.feature.shell.MainShellGraph

/**
 * Top-level navigation graph. Three logical sections today:
 *   1. **Splash / boot** — placeholder until the auth state resolves
 *   2. **Auth gate** — login / register / OAuth (real screens in
 *      Phase 1; placeholder for now)
 *   3. **Main shell** — tabbed shell (Inbox / Echo / Discover /
 *      Profile) (built in Phase 2)
 *
 * The graph chooses the right start destination based on [authState];
 * subsequent screens push on top of that.
 *
 * Route strings are kept in the [Routes] object so renames stay in
 * one place. As we add features, each one will own its own
 * sub-graph registered here via `navigation { ... }`.
 */
object Routes {
    const val SPLASH = "splash"
    const val AUTH_GATE = "auth"
    const val MAIN_SHELL = "main"
}

@Composable
fun RavenNavGraph(authState: TokenStore.AuthState, isBootstrapped: Boolean) {
    val nav = rememberNavController()

    // Until the TokenStore.bootstrap() round-trip lands, we render
    // the splash. Without this we'd flash the auth landing for one
    // frame, then immediately swap to the main shell once the
    // bootstrap learned the user is signed-in — equivalent of the
    // iOS `AppBootState.checking` case in AuthGateView.swift.
    val start = when {
        !isBootstrapped -> Routes.SPLASH
        authState == TokenStore.AuthState.SIGNED_IN -> Routes.MAIN_SHELL
        else -> Routes.AUTH_GATE
    }

    NavHost(navController = nav, startDestination = start) {
        composable(Routes.SPLASH) { SplashPlaceholder() }
        composable(Routes.AUTH_GATE) {
            AuthGate(
                onSignedIn = {
                    nav.navigate(Routes.MAIN_SHELL) {
                        popUpTo(Routes.AUTH_GATE) { inclusive = true }
                        launchSingleTop = true
                    }
                }
            )
        }
        composable(Routes.MAIN_SHELL) {
            // Post-auth — the shell owns its own nav graph for the
            // tab-bar + chat-thread push.
            MainShellGraph()
        }
    }

    // Mid-session logout handling: signing out from the Profile tab
    // (or a failed token refresh) flips [authState]. `startDestination`
    // only applies on first compose, so this effect is what actually
    // clears the back stack and returns the user to the auth gate.
    LaunchedEffect(isBootstrapped, authState) {
        if (isBootstrapped && authState != TokenStore.AuthState.SIGNED_IN) {
            nav.navigate(Routes.AUTH_GATE) {
                popUpTo(nav.graph.startDestinationId) { inclusive = true }
                launchSingleTop = true
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────
// Splash placeholder — replaced by the real launch animation later.
// ─────────────────────────────────────────────────────────────────

@Composable
private fun SplashPlaceholder() {
    PlaceholderSurface("RAVEN")
}

@Composable
private fun PlaceholderSurface(label: String) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .padding(Spacing.lg),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.displayMedium,
            color = MaterialTheme.colorScheme.primary,
        )
    }
}
