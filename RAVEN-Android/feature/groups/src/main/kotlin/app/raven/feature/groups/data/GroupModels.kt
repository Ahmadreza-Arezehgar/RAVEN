package app.raven.feature.groups.data

/**
 * UI-facing model for a user who can be added to a group. Unifies the
 * two server sources — the friends list and user search — so the
 * member picker renders one row type.
 */
data class GroupCandidate(
    val id: String,
    val username: String,
    val displayName: String,
    val avatarUrl: String?,
) {
    companion object {
        fun from(dto: FriendDto): GroupCandidate = GroupCandidate(
            id = dto.id,
            username = dto.username,
            displayName = dto.displayName?.takeIf { it.isNotBlank() } ?: dto.username,
            avatarUrl = dto.avatarPath,
        )

        fun from(dto: UserSearchDto): GroupCandidate = GroupCandidate(
            id = dto.id,
            username = dto.username,
            displayName = dto.username,
            avatarUrl = dto.avatarPath,
        )
    }
}
