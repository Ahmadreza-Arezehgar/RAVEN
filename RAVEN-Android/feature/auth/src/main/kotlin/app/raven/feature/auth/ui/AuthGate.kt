package app.raven.feature.auth.ui

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import app.raven.feature.auth.data.AuthRepository
import app.raven.feature.auth.oauth.GoogleSignInHelper
import app.raven.feature.auth.oauth.OAuthConfig
import app.raven.feature.auth.oauth.AppleSignInScreen
import app.raven.feature.auth.state.AuthFlowEvent
import app.raven.feature.auth.state.AuthGateState
import app.raven.feature.auth.state.AuthViewModel
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.launch

/**
 * Top-level auth gate. Drops in where the iOS app would render
 * `AuthGateView`. While the auth state is "signed in", [onSignedIn]
 * fires once so the upstream nav graph can switch to the main shell.
 *
 * Owns its own [androidx.navigation.NavHostController] for the
 * multi-step Email signup + forgot-password + apple-webview routes.
 */
@Composable
fun AuthGate(
    onSignedIn: () -> Unit,
) {
    val viewModel: AuthViewModel = hiltViewModel()
    val gateState by viewModel.gateState.collectAsState()
    val context = LocalContext.current

    // Surface errors as toasts. Phase 2 swaps to inline / snackbar.
    LaunchedEffect(viewModel) {
        viewModel.events.collect { ev ->
            if (ev is AuthFlowEvent.Error) {
                Toast.makeText(context, ev.message, Toast.LENGTH_LONG).show()
            }
        }
    }

    when (val state = gateState) {
        AuthGateState.Checking -> SplashFiller()
        AuthGateState.Onboarding -> {
            OnboardingScreen(onFinish = { viewModel.markOnboardingSeen() })
        }
        AuthGateState.Unauthenticated -> {
            UnauthenticatedFlow(viewModel = viewModel)
        }
        is AuthGateState.UsernameRequired -> {
            UsernameSelectionScreen(tempToken = state.tempToken, viewModel = viewModel)
        }
        is AuthGateState.EmailVerificationRequired -> {
            OTPVerificationScreen(
                email = state.email,
                onBack = { /* no-op — user can't escape email verification */ },
                viewModel = viewModel,
            )
        }
        AuthGateState.PhoneCollectionOptional -> {
            LaunchedEffect(Unit) { onSignedIn() }
        }
        AuthGateState.SignedIn -> {
            LaunchedEffect(Unit) { onSignedIn() }
        }
    }
}

@Composable
private fun SplashFiller() {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = "RAVEN",
            style = MaterialTheme.typography.displayMedium,
            color = MaterialTheme.colorScheme.primary,
        )
    }
}

// ─────────────────────────────────────────────────────────────────
// Unauthenticated sub-flow.
// Routes: landing ⇄ login ⇄ signup ⇄ otp ⇄ forgot ⇄ apple-webview
// ─────────────────────────────────────────────────────────────────

private object UnauthRoutes {
    const val LANDING = "auth/landing"
    const val LOGIN = "auth/login"
    const val SIGNUP = "auth/signup"
    const val OTP = "auth/otp/{email}"
    const val FORGOT = "auth/forgot"
    const val APPLE_WEB = "auth/apple"
    fun otp(email: String) = "auth/otp/${java.net.URLEncoder.encode(email, "UTF-8")}"
}

/**
 * Hilt entry-point that lets `@Composable`s reach into the
 * SingletonComponent for plain (non-@HiltViewModel) deps. Used here
 * for the [GoogleSignInHelper] + [OAuthConfig] + [AuthRepository] —
 * none of which sit cleanly on a ViewModel because the helpers are
 * stateless and the repo is consumed in two screens that don't
 * share a VM scope.
 */
@EntryPoint
@InstallIn(SingletonComponent::class)
interface AuthHiltAccess {
    fun authRepository(): AuthRepository
    fun googleSignInHelper(): GoogleSignInHelper
    fun oauthConfig(): OAuthConfig
}

@Composable
private fun UnauthenticatedFlow(viewModel: AuthViewModel) {
    val nav = rememberNavController()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    val accessors = EntryPointAccessors.fromApplication(
        context.applicationContext,
        AuthHiltAccess::class.java,
    )
    val repo = accessors.authRepository()
    val googleHelper = accessors.googleSignInHelper()
    val oauthConfig = accessors.oauthConfig()

    LaunchedEffect(viewModel) {
        viewModel.events.collect { ev ->
            when (ev) {
                is AuthFlowEvent.OtpSent -> {
                    nav.navigate(UnauthRoutes.otp(ev.email)) {
                        launchSingleTop = true
                    }
                }
                else -> Unit  // SignedIn / UsernameRequired propagate via gateState
            }
        }
    }

    NavHost(navController = nav, startDestination = UnauthRoutes.LANDING) {
        composable(UnauthRoutes.LANDING) {
            AuthLandingScreen(
                onCreateAccount = { nav.navigate(UnauthRoutes.SIGNUP) },
                onLogin = { nav.navigate(UnauthRoutes.LOGIN) },
                onGoogleClick = {
                    scope.launch {
                        when (val r = googleHelper.signIn(context)) {
                            is GoogleSignInHelper.Result.Success -> {
                                viewModel.oauthGoogle(r.idToken)
                            }
                            GoogleSignInHelper.Result.Cancelled -> Unit
                            is GoogleSignInHelper.Result.Failure ->
                                viewModel.emitError(r.message)
                        }
                    }
                },
                onAppleClick = { nav.navigate(UnauthRoutes.APPLE_WEB) },
                isLoading = false,
            )
        }
        composable(UnauthRoutes.LOGIN) {
            LoginScreen(
                onForgotPassword = { nav.navigate(UnauthRoutes.FORGOT) },
                onBack = { nav.popBackStack() },
                viewModel = viewModel,
            )
        }
        composable(UnauthRoutes.SIGNUP) {
            SignUpScreen(
                onBack = { nav.popBackStack() },
                viewModel = viewModel,
            )
        }
        composable(
            route = UnauthRoutes.OTP,
            arguments = listOf(navArgument("email") { type = NavType.StringType }),
        ) { entry ->
            val rawEmail = entry.arguments?.getString("email").orEmpty()
            val email = java.net.URLDecoder.decode(rawEmail, "UTF-8")
            OTPVerificationScreen(
                email = email,
                onBack = { nav.popBackStack() },
                viewModel = viewModel,
            )
        }
        composable(UnauthRoutes.FORGOT) {
            ForgotPasswordScreen(
                // ForgotPasswordScreen now auto-signs-in after reset,
                // so the TokenStore.authState flip will propagate up
                // to the parent AuthGate and switch to the main shell.
                // This callback fires after auto-login succeeds; we
                // just need to surface a confirmation toast — the
                // navigation itself happens via gateState.
                onResetComplete = {
                    Toast.makeText(context, "Password reset ✓", Toast.LENGTH_SHORT).show()
                },
                onBack = { nav.popBackStack() },
                repo = repo,
                viewModel = viewModel,
            )
        }
        composable(UnauthRoutes.APPLE_WEB) {
            AppleSignInScreen(
                config = oauthConfig,
                onIdentityToken = { idToken, code ->
                    viewModel.oauthApple(idToken, code)
                    nav.popBackStack()
                },
                onCancel = { nav.popBackStack() },
                onFailure = { msg ->
                    viewModel.emitError(msg)
                    nav.popBackStack()
                },
            )
        }
    }
}
