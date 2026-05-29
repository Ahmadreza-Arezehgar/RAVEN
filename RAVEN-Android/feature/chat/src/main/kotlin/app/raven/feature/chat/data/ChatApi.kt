package app.raven.feature.chat.data

import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.Path
import retrofit2.http.Query

/**
 * Retrofit binding for the chat-related endpoints we need in
 * Phase 2 (Chat MVP). Mirror of iOS `MessageService` + `ConversationStore`
 * network methods.
 *
 * Out of scope for Phase 2: archive/delete/mute mutators, message
 * editing, voice/media uploads. Those land in Phase 2b once the
 * text path is solid.
 */
interface ChatApi {

    /** List the caller's inbox — one row per peer / group. */
    @GET("api/messages/conversations")
    suspend fun listConversations(
        @Query("limit") limit: Int = 50,
        @Query("since") since: String? = null,
    ): List<ConversationDto>

    /** Full thread with a single peer. Server returns ASC by timestamp. */
    @GET("api/messages/conversation/{otherUserId}")
    suspend fun getThread(
        @Path("otherUserId") otherUserId: String,
    ): List<MessageDto>

    @POST("api/messages/send")
    suspend fun send(@Body body: SendMessageRequest): MessageDto

    /** Server marks the listed message ids as read. Returns 204. */
    @POST("api/messages/read")
    suspend fun markRead(@Body body: MarkReadRequest)
}
