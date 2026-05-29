package app.raven.feature.groups.data

import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import retrofit2.Retrofit
import retrofit2.create
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object GroupsDataModule {

    @Provides
    @Singleton
    fun provideGroupsApi(retrofit: Retrofit): GroupsApi = retrofit.create()
}
