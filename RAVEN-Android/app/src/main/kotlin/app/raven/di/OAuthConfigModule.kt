package app.raven.di

import app.raven.BuildConfig
import app.raven.feature.auth.oauth.OAuthConfig
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * Bridges build-time `BuildConfig` constants into the Hilt graph.
 * Lives in the app module because BuildConfig is generated per
 * Android-module and we want one canonical source of truth — the
 * app — for OAuth config.
 */
@Module
@InstallIn(SingletonComponent::class)
object OAuthConfigModule {

    @Provides
    @Singleton
    fun provideOAuthConfig(): OAuthConfig = OAuthConfig(
        googleWebClientId = BuildConfig.GOOGLE_WEB_CLIENT_ID,
        appleServicesId = BuildConfig.APPLE_SERVICES_ID,
        appleRedirectUri = BuildConfig.APPLE_REDIRECT_URI,
    )
}
