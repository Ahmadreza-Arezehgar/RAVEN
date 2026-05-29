package app.raven.feature.discover.data

import app.raven.feature.feed.data.Post
import javax.inject.Inject
import javax.inject.Singleton

/** Network-backed repository for the Discover tab. */
@Singleton
class DiscoverRepository @Inject constructor(
    private val api: DiscoverApi,
) {

    suspend fun suggested(): List<DiscoverUser> =
        api.suggested().items.map { DiscoverUser.from(it) }

    suspend fun searchUsers(query: String): List<DiscoverUser> =
        api.searchUsers(query).map { DiscoverUser.from(it) }

    suspend fun searchPosts(query: String): List<Post> =
        api.searchPosts(query).map { Post.from(it) }

    suspend fun sendFriendRequest(userId: String) {
        api.sendFriendRequest(userId)
    }
}
