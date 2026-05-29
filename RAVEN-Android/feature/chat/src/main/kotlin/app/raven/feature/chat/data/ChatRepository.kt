package app.raven.feature.chat.data

import app.raven.core.network.RealtimeWebSocket
import app.raven.core.security.TokenStore
import app.raven.core.storage.ConversationDao
import app.raven.core.storage.MessageDao
import app.raven.feature.e2ee.MessageEnvelope
import app.raven.feature.e2ee.MessageSealer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import java.util.Collections
import java.util.LinkedHashMap
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Cache-first chat repository. Mirror of iOS
 * `ConversationStore.shared` + `MessageStore.shared` patterns: the
 * UI never blocks on the network — it observes Room flows; the
 * repository fans out incoming wire data into the cache + the WS
 * pipes new events into the same cache so observers light up
 * everywhere at once.
 *
 * Responsibilities:
 *   • Expose [observeInbox] / [observeThread] Flows backed by Room
 *   • Pull on demand from REST and write through to Room
 *   • Listen on [RealtimeWebSocket] for inbound /ws/inbox events
 *     and write them through to Room (which fires every observer)
 *   • Provide [send] / [markRead] mutators that update both the
 *     server AND the local cache so the UI gets instant feedback
 */
@Singleton
class ChatRepository @Inject constructor(
    private val api: ChatApi,
    private val tokenStore: TokenStore,
    private val conversationDao: ConversationDao,
    private val messageDao: MessageDao,
    private val realtime: RealtimeWebSocket,
    private val json: Json,
    private val messageSealer: MessageSealer,
) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @Volatile private var wsCollectStarted = false

    /**
     * Cache of `msgId → plaintext` for messages WE sent, so that when
     * the server echoes the same message back over `/ws/inbox` we
     * render the user's own text instead of trying (and failing) to
     * decrypt the RVNS1 ciphertext we shipped to the peer.
     *
     * Bounded LRU at [OUTBOX_PLAINTEXT_CAP] entries — sized for a few
     * minutes of heavy chat. Older entries roll off; if a stale echo
     * arrives after eviction we fall through to the "[encrypted —
     * sent from another device]" placeholder, which is the right UI
     * for a multi-device session anyway.
     */
    private val outboxPlaintext: MutableMap<String, String> =
        Collections.synchronizedMap(
            object : LinkedHashMap<String, String>(64, 0.75f, /* accessOrder = */ true) {
                override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?): Boolean =
                    size > OUTBOX_PLAINTEXT_CAP
            }
        )

    // ─── Observers ───────────────────────────────────────────────

    fun observeInbox(): Flow<List<Conversation>> =
        conversationDao.observeInbox().map { rows -> rows.map { it.toModel() } }

    fun observeThread(otherUserId: String): Flow<List<ChatMessage>> {
        val me = tokenStore.currentUserId().orEmpty()
        return messageDao.observe(otherUserId).map { rows -> rows.map { it.toModel(me) } }
    }

    // ─── Network sync ────────────────────────────────────────────

    /** Fetch fresh inbox from server, replace Room rows. Caller
     *  (the VM) collects [observeInbox] separately. */
    suspend fun syncInbox() {
        val list = api.listConversations()
        conversationDao.upsertAll(list.map(ConversationDto::toEntity))
    }

    /** Fetch fresh thread from server, upsert into Room. */
    suspend fun syncThread(otherUserId: String) {
        val me = tokenStore.currentUserId().orEmpty()
        val msgs = api.getThread(otherUserId)
        val entities = msgs.map { dto ->
            val resolved = resolveIncomingContent(dto, currentUserId = me)
            dto.toEntity(currentUserId = me, resolvedContent = resolved)
        }
        messageDao.upsertAll(entities)
    }

    // ─── Mutators ────────────────────────────────────────────────

    suspend fun sendText(
        recipientId: String,
        text: String,
        replyToMessageId: String? = null,
        replyToPreview: String? = null,
        replyToSenderName: String? = null,
    ): ChatMessage {
        val me = tokenStore.currentUserId().orEmpty()
        val msgId = UUID.randomUUID().toString()

        // Phase 2e — wrap in RVNS1 (X3DH + AES-GCM) when a session
        // exists, else fall back to RVNP1 plaintext (peer hasn't
        // published a bundle, network down, etc.). iOS does the
        // same fall-back in `MessageContentSealer.seal(...)`.
        val sealed = messageSealer.sealOutgoing(
            plaintext = text,
            senderUserId = me,
            recipientUserId = recipientId,
            messageId = msgId,
        )
        val wireContent = sealed.base64Content

        // Cache our plaintext for echo-resolution — must happen
        // BEFORE the network round-trip so a fast WS echo can find it.
        outboxPlaintext[msgId] = text

        val req = SendMessageRequest(
            recipientId = recipientId,
            content = wireContent,
            messageId = msgId,
            messageType = "text",
            replyToMessageId = replyToMessageId,
            replyToTextPreview = replyToPreview,
            replyToSenderName = replyToSenderName,
            replyToType = if (replyToMessageId != null) "text" else null,
        )
        val ack = api.send(req)
        val entity = ack.toEntity(currentUserId = me, resolvedContent = text)
        messageDao.upsert(entity)
        // Optimistically bump the conversation row so the inbox
        // re-sorts immediately. Sender-id is `me` so the unread
        // counter doesn't tick up on our own send.
        conversationDao.bumpLastMessage(
            id = recipientId,
            preview = entity.content,
            senderId = me,
            timestampMs = entity.created_at,
            unreadDelta = 0,
        )
        return entity.toModel(me)
    }

    suspend fun markRead(messageIds: List<String>) {
        if (messageIds.isEmpty()) return
        api.markRead(MarkReadRequest(messageIds))
        // Optimistic local clear — the WS will follow up with the
        // server's authoritative read_at timestamps when 2c lands.
        val first = messageDao.byId(messageIds.first())
        if (first != null) {
            conversationDao.markRead(first.conversation_id)
        }
    }

    // ─── Realtime ingestion ──────────────────────────────────────

    /**
     * Start consuming /ws/inbox events. Idempotent — repeated calls
     * are no-ops while the collect job is still alive. The caller
     * (lifecycle observer in the app module) invokes this once on
     * `signed-in` and never again until `signed-out → signed-in`.
     */
    fun startRealtime() {
        if (wsCollectStarted) return
        wsCollectStarted = true
        realtime.connect()
        scope.launch {
            realtime.events.collect { raw -> handleIncoming(raw) }
        }
    }

    fun stopRealtime() {
        realtime.disconnect()
        // Leave the collect job alive — when the user signs back in
        // and we call connect() again the same flow keeps feeding
        // it. No need to tear down the scope for now.
    }

    /**
     * Decode a /ws/inbox payload and write it through to Room.
     *
     * Server's WebSocket sends one of two shapes today:
     *   • a single `MessageDto` JSON object on send/bridge events
     *   • a JSON array of `MessageDto` on the 30-second catch-up
     *
     * We accept either by sniffing the first non-whitespace char.
     */
    private suspend fun handleIncoming(raw: String) {
        val trimmed = raw.trimStart()
        // Decode in a non-suspending block, then dispatch the
        // results suspending so we can write through to Room.
        val batch: List<MessageDto> = try {
            if (trimmed.startsWith("[")) {
                json.decodeFromString<List<MessageDto>>(raw)
            } else {
                listOf(json.decodeFromString<MessageDto>(raw))
            }
        } catch (_: Throwable) {
            return
        }
        batch.forEach { ingestMessage(it) }
    }

    /** Funnel for one DTO → Room. Bumps the conversation row + the
     *  unread counter when the message came from the peer. */
    private suspend fun ingestMessage(dto: MessageDto) {
        val me = tokenStore.currentUserId().orEmpty()
        val resolved = resolveIncomingContent(dto, currentUserId = me)
        val entity = dto.toEntity(currentUserId = me, resolvedContent = resolved)
        messageDao.upsert(entity)
        val unreadDelta = if (dto.senderId == me) 0 else 1
        conversationDao.bumpLastMessage(
            id = entity.conversation_id,
            preview = entity.content,
            senderId = entity.sender_id,
            timestampMs = entity.created_at,
            unreadDelta = unreadDelta,
        )
    }

    /**
     * Decode a wire `content` string into the UI-ready plaintext.
     *
     * Three paths:
     *   1. **Our own send echoed back** — pull from [outboxPlaintext]
     *      so we don't have to attempt a decrypt against a session
     *      our own device couldn't decrypt anyway (we encrypted FOR
     *      the peer, not for us).
     *   2. **RVNS1 from peer** — delegate to
     *      [MessageSealer.openIncoming]. The sealer handles
     *      session-load-or-establish + replay check + AEAD verify.
     *   3. **RVNP1 / Legacy** — strip the envelope, render the raw
     *      UTF-8 body.
     *
     * Suspending because the responder-side X3DH derivation inside
     * [MessageSealer] may fetch the peer's bundle to learn their
     * identity X25519 key.
     */
    private suspend fun resolveIncomingContent(dto: MessageDto, currentUserId: String): String {
        if (dto.senderId == currentUserId) {
            outboxPlaintext[dto.id]?.let { return it }
        }
        return when (val d = MessageEnvelope.decode(dto.content)) {
            is MessageEnvelope.Decoded.Plaintext -> d.text
            is MessageEnvelope.Decoded.Legacy -> d.raw
            is MessageEnvelope.Decoded.Sealed -> {
                if (dto.senderId == currentUserId) {
                    // Our own RVNS1 — the outbox cache missed (LRU
                    // eviction or another-device-sent-this scenario).
                    // Phase 2g multi-device will surface the right
                    // shared-secret path; until then show a hint.
                    "[encrypted — sent from another device]"
                } else {
                    // `content` is nullable on the wire but the Sealed
                    // branch only fires after a successful decode, so
                    // .orEmpty() is just a static-type appeasement —
                    // openIncoming re-decodes internally and returns
                    // null on any malformed input anyway.
                    messageSealer.openIncoming(
                        wireContent = dto.content.orEmpty(),
                        senderUserId = dto.senderId,
                        recipientUserId = currentUserId,
                        messageId = dto.id,
                    ) ?: "🔒 Couldn't decrypt"
                }
            }
        }
    }

    companion object {
        /** Roughly 5–10 minutes of busy 1:1 chat. Tuned for memory
         *  rather than completeness — a missed echo only costs us
         *  a placeholder string in the bubble. */
        private const val OUTBOX_PLAINTEXT_CAP = 256
    }
}
