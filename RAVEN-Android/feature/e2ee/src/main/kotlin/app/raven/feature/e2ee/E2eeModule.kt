package app.raven.feature.e2ee

import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import retrofit2.Retrofit
import retrofit2.create
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object E2eeModule {

    @Provides
    @Singleton
    fun provideBundleApi(retrofit: Retrofit): E2eeBundleApi = retrofit.create()
}
