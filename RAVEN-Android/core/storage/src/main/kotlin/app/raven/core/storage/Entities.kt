package app.raven.core.storage

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * Local DB schema. v2 (Phase 2b) — see [RavenDatabase.VERSION].
 *
 * Mirror of the iOS Core Data + SQLCipher schema in
 * `DatabaseService.swift` + `MessageStore.swift`. Each entity is the
 * Android twin of an iOS NSManagedObject subclass.
 *
 * Naming: snake_case columns so a data-export round-trip with the
 * server schema is friction-free.
 */

@Entity(tableName = "messages",
    indices = [
        Index("conversation_id"),
        Index("created_at"),
    ])
data class MessageEntity(
    @PrimaryKey val id: String,
    val conversation_id: String,
    val sender_id: String,
    val recipient_id: String?,
    val group_id: String?,
    /**
     * Stored as the opaque RVNS1/RVNP1 envelope when the message is
     * E2EE, or the plaintext body when it's a system/onboarding row.
     * Never `null` — empty messages are not allowed.
     */
    val content: String,
    val message_type: String,
    val created_at: Long,
    val delivered_at: Long?,
    val read_at: Long?,
    val attribution_verified: Boolean = true,
    /** Reply preview metadata, mirrored from the server response. */
    val reply_to_message_id: String? = null,
    val reply_to_text_preview: String? = null,
    val reply_to_sender_name: String? = null,
    val reply_to_type: String? = null,
    /** Sender display info — denormalised so the UI doesn't need to
     *  join `users` on every render. Updated on every upsert. */
    val sender_username: String? = null,
    val sender_name: String? = null,
)

@Entity(tableName = "conversations",
    indices = [Index("updated_at")])
data class ConversationEntity(
    /** For 1:1 chats this is the peer's user_id (matches the server's
     *  `room_id`). For groups, the group_id. */
    @PrimaryKey val id: String,
    val peer_user_id: String?,
    val group_id: String?,
    val title: String?,
    val last_message_preview: String?,
    val last_message_sender_id: String? = null,
    val last_message_timestamp: Long? = null,
    val unread_count: Int = 0,
    val updated_at: Long,
    val is_archived: Boolean = false,
    val is_pinned: Boolean = false,
    /** Mute state — read for now; Phase 2c wires the mutator. */
    val is_muted: Boolean = false,
    val is_group: Boolean = false,
    val group_name: String? = null,
    val group_avatar_url: String? = null,
    /** Peer denormalised fields so the inbox renders without a
     *  users join. */
    val peer_username: String? = null,
    val peer_display_name: String? = null,
    val peer_avatar_url: String? = null,
    val peer_is_verified: Boolean = false,
    val peer_is_premium: Boolean = false,
)

@Entity(tableName = "users",
    indices = [Index("username")])
data class UserEntity(
    @PrimaryKey val id: String,
    val username: String,
    val display_name: String?,
    val avatar_url: String?,
    val is_verified: Boolean = false,
    val is_premium: Boolean = false,
    val last_seen_at: Long?,
)
