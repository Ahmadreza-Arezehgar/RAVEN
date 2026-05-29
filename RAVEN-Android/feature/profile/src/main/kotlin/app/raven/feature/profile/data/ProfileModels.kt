package app.raven.feature.profile.data

import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * UI-facing profile model — the Compose layer talks in this, not the
 * raw DTO. Equivalent of the iOS `User` / `FullProfileResponse`.
 */
data class UserProfile(
    val id: String,
    val username: String,
    /** Resolved name for display — falls back to the username. */
    val displayName: String,
    /** Raw display name (may be blank) — used to prefill the editor. */
    val rawDisplayName: String,
    val avatarUrl: String?,
    val bio: String,
    val joinedAt: Instant?,
    val isVerified: Boolean,
    val isPremium: Boolean,
    val postsCount: Int,
    val friendsCount: Int,
) {
    companion object {
        fun from(dto: FullProfileDto): UserProfile {
            val name = dto.displayName?.trim().orEmpty()
            return UserProfile(
                id = dto.id,
                username = dto.username,
                displayName = name.ifBlank { dto.username },
                rawDisplayName = name,
                avatarUrl = dto.avatarUrl,
                bio = dto.bio?.trim().orEmpty(),
                joinedAt = parseInstant(dto.joinedAt),
                isVerified = dto.isVerified,
                isPremium = dto.isPremium,
                postsCount = dto.postsCount,
                friendsCount = dto.friendsCount,
            )
        }
    }
}

/** Best-effort ISO-8601 parse — server may stamp with or without offset. */
private fun parseInstant(raw: String?): Instant? {
    if (raw.isNullOrBlank()) return null
    return try {
        OffsetDateTime.parse(raw, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant()
    } catch (_: Throwable) {
        try {
            Instant.parse(raw)
        } catch (_: Throwable) {
            try {
                LocalDateTime.parse(raw).toInstant(ZoneOffset.UTC)
            } catch (_: Throwable) {
                null
            }
        }
    }
}
