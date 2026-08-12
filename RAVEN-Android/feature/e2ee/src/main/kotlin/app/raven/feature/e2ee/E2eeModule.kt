package app.raven.feature.e2ee

import app.raven.core.security.SignOutHooks
import dagger.Binds
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dagger.multibindings.IntoSet
import retrofit2.Retrofit
import retrofit2.create
import javax.inject.Inject
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object E2eeModule {

    @Provides
    @Singleton
    fun provideBundleApi(retrofit: Retrofit): E2eeBundleApi = retrofit.create()
}

/** Clears SessionStore + PrekeyBundle in-process/disk state on sign-out. */
@Singleton
class E2eeSignOutHooks @Inject constructor(
    private val sessionStore: SessionStore,
    private val prekeyBundleService: PrekeyBundleService,
) : SignOutHooks {
    override fun onLocalSignOut() {
        sessionStore.clearAll()
        prekeyBundleService.reset()
    }
}

@Module
@InstallIn(SingletonComponent::class)
abstract class E2eeSignOutModule {
    @Binds
    @IntoSet
    @Singleton
    abstract fun bindE2eeSignOutHooks(impl: E2eeSignOutHooks): SignOutHooks
}
