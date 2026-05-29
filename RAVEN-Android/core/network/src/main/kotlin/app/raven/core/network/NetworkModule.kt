package app.raven.core.network

import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import java.util.concurrent.TimeUnit
import javax.inject.Qualifier
import javax.inject.Singleton

/**
 * Qualifier for the OkHttp + Retrofit pair that does NOT include the
 * [AuthInterceptor]. Used by the refresh-token endpoint so we don't
 * get a circular dependency:
 *   OkHttp ← AuthInterceptor ← TokenProvider ← TokenStore ←
 *     RefreshTokenService ← Retrofit ← OkHttp
 *
 * Marking the refresh chain @Unauthenticated breaks the loop —
 * Retrofit2 for refresh uses a plain OkHttp instance with no
 * authenticator hooked in.
 */
@Qualifier
@Retention(AnnotationRetention.BINARY)
annotation class Unauthenticated

/**
 * Hilt module that wires up OkHttp + Retrofit + JSON.
 *
 * - `OkHttpClient` keeps a single connection pool app-wide and adds
 *   our [AuthInterceptor] for bearer-token injection.
 * - `Json` mirrors the iOS `JSONDecoder` defaults the server expects
 *   (lenient on unknown keys, snake_case).
 * - `Retrofit` is provisioned once per process; per-feature service
 *   interfaces are bound separately by their owning modules.
 *
 * The [TokenProvider] dependency is satisfied by `:core:security`'s
 * Hilt module — that's where the actual Keystore-backed store lives.
 */
@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {

    @Provides
    @Singleton
    fun provideJson(): Json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = false
        // Server uses snake_case columns; we keep camelCase on the
        // Kotlin side and let kotlinx-serialization translate via
        // explicit @SerialName annotations on DTOs.
        explicitNulls = false
    }

    @Provides
    @Singleton
    fun provideOkHttp(
        authInterceptor: AuthInterceptor,
    ): OkHttpClient {
        val logging = HttpLoggingInterceptor().apply {
            level = HttpLoggingInterceptor.Level.BASIC
            // Redact secrets from logs even if level bumps to BODY.
            redactHeader("Authorization")
            redactHeader("X-Admin-Secret")
        }
        return OkHttpClient.Builder()
            .connectTimeout(8, TimeUnit.SECONDS)
            // Generous read timeout: some endpoints — the semantic
            // post search, a cold-started Cloud Run instance — take
            // 15-20s to send the first response byte. readTimeout is
            // the per-read socket inactivity gap, NOT the total
            // transfer time, so 60s is still safe for large media
            // downloads. (Without this, OkHttp's 10s default fires.)
            .readTimeout(60, TimeUnit.SECONDS)
            // No write/call timeout — RAVEN+ uploads can run
            // multi-minute for 2GB voice files. iOS does the same.
            .writeTimeout(0, TimeUnit.SECONDS)
            .callTimeout(0, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
            .addInterceptor(authInterceptor)
            .addInterceptor(logging)
            .build()
    }

    @Provides
    @Singleton
    fun provideRetrofit(
        okHttp: OkHttpClient,
        json: Json,
    ): Retrofit {
        return Retrofit.Builder()
            .baseUrl(RavenServer.activeBaseUrl())
            .client(okHttp)
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
            .build()
    }

    /** Plain OkHttp with no auth interceptor. */
    @Provides
    @Singleton
    @Unauthenticated
    fun provideUnauthenticatedOkHttp(): OkHttpClient {
        val logging = HttpLoggingInterceptor().apply {
            level = HttpLoggingInterceptor.Level.BASIC
            redactHeader("Authorization")
        }
        return OkHttpClient.Builder()
            .connectTimeout(8, TimeUnit.SECONDS)
            .callTimeout(15, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
            .addInterceptor(logging)
            .build()
    }

    /** Retrofit instance bound to the unauth client. The refresh
     *  token service is the canonical consumer. */
    @Provides
    @Singleton
    @Unauthenticated
    fun provideUnauthenticatedRetrofit(
        @Unauthenticated okHttp: OkHttpClient,
        json: Json,
    ): Retrofit {
        return Retrofit.Builder()
            .baseUrl(RavenServer.activeBaseUrl())
            .client(okHttp)
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
            .build()
    }

    /**
     * Long-lived WebSocket client for /ws/inbox. Uses the auth
     * OkHttp (so connection-pool + DNS cache are shared with REST)
     * and reads bearer tokens via [TokenProvider] on each upgrade
     * attempt — same path the AuthInterceptor uses.
     */
    @Provides
    @Singleton
    fun provideRealtimeWebSocket(
        okHttp: OkHttpClient,
        tokenProvider: TokenProvider,
    ): RealtimeWebSocket = RealtimeWebSocket(
        baseHttpUrl = RavenServer.activeBaseUrl(),
        okHttp = okHttp,
        tokenProvider = tokenProvider,
    )
}
