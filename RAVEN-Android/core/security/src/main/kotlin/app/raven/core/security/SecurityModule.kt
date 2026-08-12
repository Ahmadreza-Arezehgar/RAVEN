package app.raven.core.security

import android.content.Context
import app.raven.core.network.TokenProvider
import app.raven.core.network.Unauthenticated
import dagger.Binds
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import dagger.multibindings.Multibinds
import retrofit2.Retrofit
import retrofit2.create
import javax.inject.Singleton

/**
 * Hilt wiring. Two responsibilities:
 *   1. Provide [SecureStore] backed by the application context.
 *   2. Bind [TokenStore] as the implementation of the [TokenProvider]
 *      contract that `:core:network` declared. This is the seam that
 *      lets the network layer call into secure-storage without
 *      compile-time depending on the Android Keystore APIs.
 */
@Module
@InstallIn(SingletonComponent::class)
object SecurityProvidersModule {

    @Provides
    @Singleton
    fun provideSecureStore(@ApplicationContext context: Context): SecureStore =
        SecureStore(context)

    @Provides
    @Singleton
    fun provideRefreshTokenService(@Unauthenticated retrofit: Retrofit): RefreshTokenService =
        retrofit.create()

    @Provides
    @Singleton
    fun provideMeApi(retrofit: Retrofit): MeApi = retrofit.create()
}

@Module
@InstallIn(SingletonComponent::class)
abstract class SecurityBindsModule {

    @Binds
    @Singleton
    abstract fun bindTokenProvider(impl: TokenStore): TokenProvider

    /** Empty multibinding so TokenStore can inject Set<SignOutHooks> even
     *  when no feature module contributes hooks (tests / slim graphs). */
    @Multibinds
    abstract fun signOutHooks(): Set<SignOutHooks>
}
