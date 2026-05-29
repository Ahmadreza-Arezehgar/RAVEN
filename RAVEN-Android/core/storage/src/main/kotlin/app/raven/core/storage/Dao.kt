package app.raven.core.storage

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

@Dao
interface MessageDao {

    @Query("SELECT * FROM messages WHERE conversation_id = :conversationId ORDER BY created_at ASC")
    fun observe(conversationId: String): Flow<List<MessageEntity>>

    @Query("SELECT * FROM messages WHERE id = :id LIMIT 1")
    suspend fun byId(id: String): MessageEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(message: MessageEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(messages: List<MessageEntity>)

    @Query("DELETE FROM messages WHERE conversation_id = :conversationId")
    suspend fun deleteConversation(conversationId: String)
}

@Dao
interface ConversationDao {

    @Query("SELECT * FROM conversations WHERE is_archived = 0 ORDER BY is_pinned DESC, updated_at DESC")
    fun observeInbox(): Flow<List<ConversationEntity>>

    @Query("SELECT * FROM conversations WHERE id = :id LIMIT 1")
    suspend fun byId(id: String): ConversationEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(conversation: ConversationEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(conversations: List<ConversationEntity>)

    @Update
    suspend fun update(conversation: ConversationEntity)

    @Query("UPDATE conversations SET unread_count = 0 WHERE id = :id")
    suspend fun markRead(id: String)

    /**
     * Bump the last-message + activity fields without overwriting
     * the rest of the row (peer display, mute flag, etc.). Called
     * when a new message arrives via WebSocket for a conversation
     * we already know about. The unread bump is conditional on
     * `senderId != currentUserId` so own-echo doesn't inflate the
     * counter — caller handles that.
     */
    @Query(
        """
        UPDATE conversations SET
            last_message_preview = :preview,
            last_message_sender_id = :senderId,
            last_message_timestamp = :timestampMs,
            updated_at = :timestampMs,
            unread_count = unread_count + :unreadDelta
        WHERE id = :id
        """
    )
    suspend fun bumpLastMessage(
        id: String,
        preview: String?,
        senderId: String?,
        timestampMs: Long,
        unreadDelta: Int,
    )

    @Query("DELETE FROM conversations")
    suspend fun clearAll()
}

@Dao
interface UserDao {

    @Query("SELECT * FROM users WHERE id = :id LIMIT 1")
    suspend fun byId(id: String): UserEntity?

    @Query("SELECT * FROM users WHERE id IN (:ids)")
    suspend fun byIds(ids: List<String>): List<UserEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(user: UserEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(users: List<UserEntity>)
}
