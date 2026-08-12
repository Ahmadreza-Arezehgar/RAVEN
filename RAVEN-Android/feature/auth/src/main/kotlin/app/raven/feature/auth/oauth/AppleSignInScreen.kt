package app.raven.feature.auth.oauth

import android.annotation.SuppressLint
import android.net.Uri
import android.util.Base64
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
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * Apple's identity provider has no native Android SDK, so we run
 * the OAuth Authorization-Code flow in an in-process WebView.
 *
 * Flow:
 *   1. Load `https://appleid.apple.com/auth/authorize?...` with
 *      our Services ID + redirect URI + CSRF `state` + PKCE S256.
 *   2. Apple authenticates the user, then form_posts to the server
 *      callback which bounces `raven://oauth/apple/done#...` including
 *      the echoed `state`.
 *   3. This WebView intercepts the deep link, **rejects state mismatch**,
 *      extracts the identity token, and hands it to [onIdentityToken].
 */
@SuppressLint("SetJavaScriptEnabled")  // Apple's auth UI is JS-heavy.
@Composable
fun AppleSignInScreen(
    config: OAuthConfig,
    onIdentityToken: (idToken: String, code: String?) -> Unit,
    onCancel: () -> Unit,
    onFailure: (String) -> Unit,
) {
    // Persist expected CSRF state + PKCE verifier for this compose
    // session. Apple echoes `state` via the server deep-link bounce;
    // mismatch → abort (CSRF).
    val oauthSession = remember(config) { AppleOAuthSession.mint() }
    val authorizeUrl = remember(config, oauthSession) {
        Uri.parse("https://appleid.apple.com/auth/authorize").buildUpon()
            .appendQueryParameter("client_id", config.appleServicesId)
            .appendQueryParameter("redirect_uri", config.appleRedirectUri)
            .appendQueryParameter("response_type", "code id_token")
            .appendQueryParameter("response_mode", "form_post")
            .appendQueryParameter("scope", "name email")
            .appendQueryParameter("state", oauthSession.state)
            .appendQueryParameter("code_challenge", oauthSession.codeChallenge)
            .appendQueryParameter("code_challenge_method", "S256")
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

            Spacer(modifier = Modifier.height(Spacing.xs))

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
                                expectedState = oauthSession.state,
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

/** Client-minted CSRF state + PKCE S256 pair for one authorize attempt. */
internal data class AppleOAuthSession(
    val state: String,
    val codeVerifier: String,
    val codeChallenge: String,
) {
    companion object {
        fun mint(): AppleOAuthSession {
            val rng = SecureRandom()
            val stateBytes = ByteArray(32)
            rng.nextBytes(stateBytes)
            val state = Base64.encodeToString(stateBytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

            val verifierBytes = ByteArray(32)
            rng.nextBytes(verifierBytes)
            val codeVerifier = Base64.encodeToString(
                verifierBytes,
                Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
            )
            val digest = MessageDigest.getInstance("SHA-256").digest(codeVerifier.toByteArray(Charsets.US_ASCII))
            val codeChallenge = Base64.encodeToString(
                digest,
                Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
            )
            return AppleOAuthSession(state, codeVerifier, codeChallenge)
        }
    }
}

/**
 * Returns true (claim the URL) if `url` is our redirect deep link
 * `raven://oauth/apple/done#...`. Parses the fragment params,
 * rejects CSRF state mismatch, then dispatches success / failure.
 */
internal fun handleRedirect(
    url: String,
    expectedState: String,
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
    val returnedState = params["state"]
    if (returnedState.isNullOrBlank() || returnedState != expectedState) {
        onFailure("Apple sign-in rejected: OAuth state mismatch (possible CSRF).")
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
