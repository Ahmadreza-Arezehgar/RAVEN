package app.raven.feature.e2ee

import android.util.Base64
import android.util.Log
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.security.SecureRandom
import javax.inject.Inject
import javax.inject.Singleton

/**
 * End-to-end seal / open pipe for one-to-one chat messages — the
 * outermost crypto layer of the Android RAVEN client (Phase 2f).
 *
 * What Phase 2f adds on top of 2e:
 *   • **Per-message symmetric ratchet** — instead of `msg_key =
 *     HKDF(root, sender, counter)`, we now derive each key from a
 *     chain key that ratchets forward (Signal §5.2 KDF_CK). Once a
 *     chain key is used, it is replaced by `HMAC(ck, 0x02)`; the old
 *     value is unrecoverable — so a compromise of the LIVE chain
 *     key cannot decrypt past messages
 *   • **32-slot sliding replay window** — accept any counter up to
 *     32 behind the high-watermark, reject duplicates. Lets us
 *     tolerate out-of-order delivery (WebSocket reconnect, queued
 *     pushes) without losing messages
 *   • **Skip-ahead burn** — receiver burns chain forward up to
 *     [DoubleRatchet.MAX_SKIP] when a counter lands ahead of
 *     `recvCount` (lost intermediate messages from the wire still
 *     advance the chain so future arrivals decrypt correctly)
 *
 * Outbound ([sealOutgoing]):
 *   1. Try `PairInitService.initiator()`
 *   2. Ratchet `sendChainKey` → `(newChain, msgKey)`
 *   3. Mint fresh 12-byte IV
 *   4. Run [CipherEnvelope.encode] with AAD = sender|recipient|msgId
 *   5. Wrap result in RVNS1 magic + Base64
 *   6. Persist `(newChain, sendCount + 1)`
 *
 * Inbound ([openIncoming]):
 *   1. Decode RVNS1 wire (strip 8-byte magic)
 *   2. Parse [CipherEnvelope] header
 *   3. Load session (or [PairInitService.responder] establish on miss)
 *   4. Replay-window check against `recvCount` + `replayWindow` bitmap
 *   5. Ratchet `recvChainKey` forward by `(headerCount - recvCount)`
 *      to land on the message key
 *   6. Decrypt
 *   7. Persist updated chain + window
 *
 * Fallback policy unchanged from 2e: any miss surfaces as null
 * (UI "[unreadable]" placeholder) or an RVNP1 plaintext fallback
 * on the send side.
 */
@Singleton
class MessageSealer @Inject constructor(
    private val sessionStore: SessionStore,
    private val pairInit: PairInitService,
) {

    private val mutex = Mutex()
    private val rng = SecureRandom()

    suspend fun sealOutgoing(
        plaintext: String,
        senderUserId: String,
        recipientUserId: String,
        messageId: String,
    ): SealResult = mutex.withLock {
        if (plaintext.isEmpty()) return SealResult.Empty

        val session = pairInit.initiator(recipientUserId)
        if (session == null) {
            Log.d(LOG_TAG, "No session for $recipientUserId — RVNP1 fallback")
            return SealResult.Plaintext(MessageEnvelope.encodePlaintext(plaintext))
        }

        // Advance the send chain by one step. KDF_CK guarantees the
        // old chain key is unrecoverable, so a compromise of the
        // NEW chain reveals nothing about THIS message's key.
        val step = DoubleRatchet.ratchetChain(session.sendChainKey)
        val counter = session.sendCount
        val iv = ByteArray(12).also { rng.nextBytes(it) }
        val ad = aad(senderUserId, recipientUserId, messageId)

        val encoded = try {
            CipherEnvelope.encode(
                msgKey = step.messageKey,
                ephemeralPub = session.anchorEphemeralPub,
                counter = counter,
                iv = iv,
                plaintext = plaintext.toByteArray(Charsets.UTF_8),
                ad = ad,
            )
        } catch (t: Throwable) {
            Log.w(LOG_TAG, "AES-GCM encrypt failed: ${t.message}")
            return SealResult.Plaintext(MessageEnvelope.encodePlaintext(plaintext))
        }

        // Persist BEFORE letting the ciphertext leave the process.
        // A crash between encrypt + persist would reuse the message
        // key on retry — AES-GCM nonce-reuse breaks tag verification
        // catastrophically.
        sessionStore.save(
            peerUserId = recipientUserId,
            peerDeviceId = PairInitService.DEFAULT_PEER_DEVICE,
            state = session.copy(
                sendChainKey = step.nextChainKey,
                sendCount = counter + 1,
            ),
        )

        val sealed = ByteArray(MessageEnvelope.SEALED_MAGIC.size + encoded.bytes.size)
        System.arraycopy(MessageEnvelope.SEALED_MAGIC, 0, sealed, 0, MessageEnvelope.SEALED_MAGIC.size)
        System.arraycopy(encoded.bytes, 0, sealed, MessageEnvelope.SEALED_MAGIC.size, encoded.bytes.size)
        return SealResult.Sealed(Base64.encodeToString(sealed, Base64.NO_WRAP))
    }

    suspend fun openIncoming(
        wireContent: String,
        senderUserId: String,
        recipientUserId: String,
        messageId: String,
    ): String? = mutex.withLock {
        val ct = (MessageEnvelope.decode(wireContent) as? MessageEnvelope.Decoded.Sealed)?.ciphertext
            ?: return@withLock null

        val parsed = CipherEnvelope.decodeHeader(ct) ?: run {
            Log.d(LOG_TAG, "Malformed CipherEnvelope from $senderUserId")
            return@withLock null
        }

        val session = sessionStore.load(senderUserId, PairInitService.DEFAULT_PEER_DEVICE)
            ?: pairInit.responder(
                peerUserId = senderUserId,
                peerEphemeralPub = parsed.ephemeralPub,
            )
            ?: return@withLock null

        // ── Replay-window check ──────────────────────────────────
        // recvCount is the high-watermark; replayWindow is a 32-bit
        // bitmap of counters in [recvCount-32, recvCount-1]. Refuse
        // duplicates + anything more than 32 behind.
        val counter = parsed.counter
        if (!replayCheck(session.recvCount, session.replayWindow, counter)) {
            Log.w(LOG_TAG, "Replay rejected for $senderUserId/$messageId: counter=$counter " +
                "high=${session.recvCount} win=${session.replayWindow.toString(16)}")
            return@withLock null
        }

        // ── Ratchet the recv chain to the target counter ─────────
        // The recv chain currently sits at session.recvCount steps
        // already advanced. We need to land on `counter`, which means
        // skipping (counter - recvCount) more steps. ChainStep returns
        // (chain-at-target, msg-key-for-target).
        val skipResult = DoubleRatchet.skipChainTo(
            chainKey = session.recvChainKey,
            currentCount = session.recvCount,
            targetCount = counter,
        ) ?: run {
            Log.w(LOG_TAG, "Skip-ahead refused for $senderUserId/$messageId: " +
                "counter=$counter, recvCount=${session.recvCount}")
            return@withLock null
        }

        val ad = aad(senderUserId, recipientUserId, messageId)
        val pt = CipherEnvelope.decrypt(skipResult.messageKey, parsed, ad) ?: run {
            Log.d(LOG_TAG, "AEAD verify failed from $senderUserId/$messageId")
            return@withLock null
        }

        val (newHigh, newWindow) = updateReplayWindow(session.recvCount, session.replayWindow, counter)
        sessionStore.save(
            peerUserId = senderUserId,
            peerDeviceId = PairInitService.DEFAULT_PEER_DEVICE,
            state = session.copy(
                recvChainKey = skipResult.nextChainKey,
                recvCount = newHigh,
                replayWindow = newWindow,
            ),
        )

        return@withLock String(pt, Charsets.UTF_8)
    }

    /**
     * Check whether [counter] should be accepted given the current
     * `(highWatermark, bitmap)`.
     *
     * Rules:
     *   • counter ≥ highWatermark — accept (a "future" message that
     *     advances the window)
     *   • counter < highWatermark - 32 — refuse (too far behind to
     *     re-verify deduplication)
     *   • else — accept iff the corresponding bit in [bitmap] is
     *     UNSET (counter not yet seen)
     */
    private fun replayCheck(highWatermark: Long, bitmap: Long, counter: Long): Boolean {
        if (counter < 0) return false
        if (counter >= highWatermark) return true
        val behind = highWatermark - 1 - counter
        if (behind >= REPLAY_WINDOW_SIZE) return false
        return (bitmap ushr behind.toInt()) and 1L == 0L
    }

    /**
     * Compute the new `(highWatermark, bitmap)` after accepting
     * [counter]. Counters ahead of the watermark shift the bitmap
     * left by the gap and set bit 0 for the watermark-1; counters
     * already inside the window just set their corresponding bit.
     */
    private fun updateReplayWindow(highWatermark: Long, bitmap: Long, counter: Long): Pair<Long, Long> {
        return if (counter >= highWatermark) {
            // Shift bitmap to record the OLD highWatermark+1 entries.
            // E.g. if counter == highWatermark, we shift left by 1 and
            // set bit 0 (the old highWatermark slot, now "1 behind").
            val shift = counter - highWatermark + 1
            val shifted = if (shift >= REPLAY_WINDOW_SIZE) 0L else bitmap shl shift.toInt()
            (counter + 1) to (shifted or 1L)
        } else {
            val behind = highWatermark - 1 - counter
            highWatermark to (bitmap or (1L shl behind.toInt()))
        }
    }

    private fun aad(senderUserId: String, recipientUserId: String, messageId: String): ByteArray {
        val s = "raven-sealer-v2|$senderUserId|$recipientUserId|$messageId"
        return s.toByteArray(Charsets.UTF_8)
    }

    sealed interface SealResult {
        data object Empty : SealResult
        data class Sealed(val base64: String) : SealResult
        data class Plaintext(val base64: String) : SealResult

        val base64Content: String
            get() = when (this) {
                Empty -> ""
                is Sealed -> base64
                is Plaintext -> base64
            }
    }

    companion object {
        private const val LOG_TAG = "MessageSealer"
        /** Width of the replay-protection sliding window. A Long
         *  bitmap gives us exactly 64 slots; we use 32 to leave
         *  headroom for the shift-left semantics without overflow. */
        const val REPLAY_WINDOW_SIZE = 32
    }
}
