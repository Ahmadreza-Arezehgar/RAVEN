package app.raven.feature.auth.oauth

/**
 * OAuth wiring values that are config-time (read from
 * `local.properties` by the app module's Gradle script and exposed
 * as `BuildConfig` fields). We pass them in by interface so the
 * auth module doesn't compile-time depend on the app's BuildConfig.
 */
data class OAuthConfig(
    /** Web client ID for Google Sign-In (Cloud Console → OAuth 2.0 →
     *  Web application). NOT the Android client ID. */
    val googleWebClientId: String,
    /** Apple Sign-In Services ID
     *  (e.g. `com.ravenmessenger.android.signin`). */
    val appleServicesId: String,
    /** Apple redirect URI registered against the Services ID. */
    val appleRedirectUri: String,
)
