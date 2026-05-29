package app.raven.feature.auth.oauth

import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * Provides the [GoogleSignInHelper] bound to the [OAuthConfig].
 *
 * The [OAuthConfig] itself is provided by the **app module** (see
 * `app/.../OAuthConfigModule.kt`) since the values come from
 * `BuildConfig`, which only the app module owns.
 */
@Module
@InstallIn(SingletonComponent::class)
object OAuthModule {

    @Provides
    @Singleton
    fun provideGoogleSignInHelper(config: OAuthConfig): GoogleSignInHelper =
        GoogleSignInHelper(webClientId = config.googleWebClientId)
}
