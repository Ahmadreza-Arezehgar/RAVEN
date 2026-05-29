package app.raven.feature.discover.data

/**
 * UI-facing model for a person shown in Discover — unifies a
 * suggested friend and a search result behind one shape.
 */
data class DiscoverUser(
    val id: String,
    val username: String,
    val displayName: String,
    val avatarUrl: String?,
    /** Secondary line — the suggestion reason, the bio, or @username. */
    val subtitle: String,
) {
    companion object {
        fun from(dto: SuggestedUserDto): DiscoverUser = DiscoverUser(
            id = dto.userId,
            username = dto.username,
            displayName = cleanDisplayName(dto.displayName) ?: dto.username,
            avatarUrl = dto.avatarUrl,
            subtitle = dto.reason.trim().ifBlank { "@${dto.username}" },
        )

        fun from(dto: UserSearchDto): DiscoverUser = DiscoverUser(
            id = dto.id,
            username = dto.username,
            displayName = cleanDisplayName(dto.displayName) ?: dto.username,
            avatarUrl = dto.avatarUrl,
            subtitle = "@${dto.username}",
        )
    }
}

/**
 * A display name unless it is blank, a server-side decryption-failure
 * placeholder (`[DECRYPT_FAILED]`), or raw ciphertext that leaked
 * through — in those cases null, so callers fall back to `@username`.
 */
private fun cleanDisplayName(raw: String?): String? {
    val s = raw?.trim().orEmpty()
    if (s.isEmpty()) return null
    if (s.contains("DECRYPT_FAILED", ignoreCase = true)) return null
    if (s.startsWith("gAAAA") || s.startsWith("eyJ")) return null
    return s
}
