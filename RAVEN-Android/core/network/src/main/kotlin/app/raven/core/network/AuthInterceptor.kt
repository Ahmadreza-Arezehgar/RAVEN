package app.raven.core.network

import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.Response
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Adds `Authorization: Bearer <jwt>` to every outbound request and,
 * on a 401 from the server, retries once after asking the
 * [TokenProvider] for a fresh access token.
 *
 * Why blocking inside an interceptor: OkHttp interceptors run on the
 * network dispatcher's threads, NOT the Kotlin coroutine context. The
 * cheapest way to reach a suspend function from there is
 * [runBlocking]; we only ever block for a single network round-trip
 * (the refresh call), which is what the rest of the request was about
 * to do anyway. If the suspend cost ever shows up in a profile, switch
 * to a `Deferred`-cache pattern.
 *
 * 🔴 hacker-audit note (carry-over from the iOS audit): the access
 * token here is short-lived (15 min by default). The refresh token is
 * held inside the [TokenProvider] implementation; it never appears on
 * any request line. This interceptor only ever puts the access token
 * on the wire — matching the iOS `NetworkService` posture.
 */
@Singleton
class AuthInterceptor @Inject constructor(
    private val tokenProvider: TokenProvider,
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val original = chain.request()

        // Skip auth header for endpoints that don't need it
        // (login, register, OAuth callback). Mark those with
        // header `X-Raven-No-Auth: 1` at the Retrofit annotation
        // layer; we strip the marker before sending.
        val skipAuth = original.header("X-Raven-No-Auth") != null
        if (skipAuth) {
            val cleaned = original.newBuilder().removeHeader("X-Raven-No-Auth").build()
            return chain.proceed(cleaned)
        }

        val initialToken = runBlocking { tokenProvider.accessToken() }
        val firstAttempt = original.newBuilder().apply {
            if (initialToken != null) header("Authorization", "Bearer $initialToken")
            header("X-Raven-Client", "android")
        }.build()

        val response = chain.proceed(firstAttempt)

        // Single retry on 401 after a refresh. Anything else (403,
        // 5xx, etc.) is for the caller to handle.
        if (response.code != 401) return response

        val refreshed = runBlocking { tokenProvider.refreshAccessToken() } ?: return response
        response.close()

        val retry = original.newBuilder().apply {
            header("Authorization", "Bearer $refreshed")
            header("X-Raven-Client", "android")
        }.build()
        return chain.proceed(retry)
    }
}
