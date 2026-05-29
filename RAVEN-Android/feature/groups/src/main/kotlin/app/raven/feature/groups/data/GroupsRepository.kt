package app.raven.feature.groups.data

import javax.inject.Inject
import javax.inject.Singleton

/** Network-backed repository for group creation + the member picker. */
@Singleton
class GroupsRepository @Inject constructor(
    private val api: GroupsApi,
) {

    /** The signed-in user's friends, as picker candidates. */
    suspend fun friends(): List<GroupCandidate> =
        api.getFriends().map { GroupCandidate.from(it) }

    /** User search — picker fallback when the friends list is empty. */
    suspend fun searchUsers(query: String): List<GroupCandidate> =
        api.searchUsers(query).map { GroupCandidate.from(it) }

    /** Create a group; returns the server's new [GroupResponse]. */
    suspend fun createGroup(name: String, memberIds: List<String>): GroupResponse =
        api.createGroup(CreateGroupRequest(name = name, memberIds = memberIds))
}
