package app.raven.feature.auth.oauth

import android.annotation.SuppressLint
import android.net.Uri
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import app.raven.core.design.Spacing

/**
 * Apple's identity provider has no native Android SDK, so we run
 * the OAuth Authorization-Code flow in an in-process WebView.
 *
 * Flow:
 *   1. Load `https://appleid.apple.com/auth/authorize?...` with
 *      our Services ID + redirect URI.
 *   2. Apple authenticates the user, then redirects to
 *      `redirect_uri` with `code` + `id_token`.
 *   3. The server callback at
 *      `/api/auth/oauth/apple/callback` accepts that POST and
 *      bounces back to a deep link
 *      `raven://oauth/apple/done#id_token=...&code=...`.
 *   4. This WebView intercepts the deep link, extracts the
 *      identity token, and hands it to [onIdentityToken].
 *
 * Phase 1b will replace this with the more polished
 * AuthorizationManagedActivityResult once we drop minSdk to 21+
 * and have the server callback wired. For now this is the same
 * pattern the iOS `AppleSignInCoordinator` follows when the
 * Apple Authentication Services SDK isn't available.
 */
@SuppressLint("SetJavaScriptEnabled")  // Apple's auth UI is JS-heavy.
@Composable
fun AppleSignInScreen(
    config: OAuthConfig,
    onIdentityToken: (idToken: String, code: String?) -> Unit,
    onCancel: () -> Unit,
    onFailure: (String) -> Unit,
) {
    val authorizeUrl = remember(config) {
        Uri.parse("https://appleid.apple.com/auth/authorize").buildUpon()
            .appendQueryParameter("client_id", config.appleServicesId)
            .appendQueryParameter("redirect_uri", config.appleRedirectUri)
            .appendQueryParameter("response_type", "code id_token")
            .appendQueryParameter("response_mode", "form_post")
            .appendQueryParameter("scope", "name email")
            // CSRF state — Phase 1b will move this to a real
            // server-issued nonce verified on the callback side.
            .appendQueryParameter("state", java.util.UUID.randomUUID().toString())
            .build()
            .toString()
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .systemBarsPadding(),
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            // ── Header bar ──
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(56.dp)
                    .padding(horizontal = Spacing.md),
            ) {
                Text(
                    text = "Sign in with Apple",
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onBackground,
                    modifier = Modifier.align(Alignment.CenterStart),
                )
                Text(
                    text = "Cancel",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier
                        .padding(end = Spacing.xs)
                        .align(Alignment.CenterEnd)
                        .clickable(onClick = onCancel),
                )
            }

            Spacer(Modifier.height(Spacing.xs))

            // ── WebView host ──
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                    WebView(ctx).apply {
                        settings.javaScriptEnabled = true
                        settings.domStorageEnabled = true
                        settings.cacheMode = WebSettings.LOAD_NO_CACHE
                        // Apple gates sign-in on third-party cookies.
                        CookieManager.getInstance().setAcceptCookie(true)
                        CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)

                        webViewClient = object : WebViewClient() {
                            override fun shouldOverrideUrlLoading(
                                view: WebView,
                                request: WebResourceRequest,
                            ): Boolean = handleRedirect(
                                url = request.url.toString(),
                                onIdentityToken = onIdentityToken,
                                onFailure = onFailure,
                            )
                        }
                        loadUrl(authorizeUrl)
                    }
                },
            )
        }
    }
}

/**
 * Returns true (claim the URL) if `url` is our redirect deep link
 * `raven://oauth/apple/done#...`. Parses the fragment params and
 * dispatches success / failure.
 */
private fun handleRedirect(
    url: String,
    onIdentityToken: (idToken: String, code: String?) -> Unit,
    onFailure: (String) -> Unit,
): Boolean {
    if (!url.startsWith("raven://oauth/apple/done")) return false
    val fragment = Uri.parse(url).encodedFragment.orEmpty()
    val params = fragment.split('&').mapNotNull {
        val eq = it.indexOf('=')
        if (eq <= 0) null else it.substring(0, eq) to Uri.decode(it.substring(eq + 1))
    }.toMap()
    val err = params["error"]
    if (err != null) {
        onFailure("Apple error: $err")
        return true
    }
    val idToken = params["id_token"]
    val code = params["code"]
    if (idToken.isNullOrBlank()) {
        onFailure("Apple sign-in returned no id_token.")
        return true
    }
    onIdentityToken(idToken, code)
    return true
}
