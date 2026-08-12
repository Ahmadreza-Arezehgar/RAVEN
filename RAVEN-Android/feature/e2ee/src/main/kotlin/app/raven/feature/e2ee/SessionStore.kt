package app.raven.feature.e2ee

import android.util.Base64
import app.raven.core.security.SecureStore
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Persists per-peer X3DH session state (Phase 2e shape).
 *
 * Each entry is keyed `(peerUserId, peerDeviceId)` and stores:
 *
 *   • [SessionState.rootKey] — 32-byte X3DH-derived secret.
 *     Used as the HKDF salt for per-message keys.
 *   • [SessionState.myEphemeralPub] / [SessionState.myEphemeralPriv]
 *     — initiator-side: the X25519 ephemeral we generated when this
 *     conversation started. Reused on every send to the same peer
 *     so the receiver only has to run X3DH once.
 *   • [SessionState.peerSignedPrekey] / [SessionState.peerStaticPub]
 *     — the bundle bits we used to derive the root. Kept around for
 *     auditability + the future TOFU banner that compares against
 *     fresh bundle fetches.
 *   • [SessionState.sendCounter] / [SessionState.recvCounter] —
 *     monotonic counters per direction. The receiver also tracks
 *     [SessionState.lastSeenRecvCounter] for replay rejection.
 *
 * Storage backend is [SecureStore] (Keystore-fenced
 * EncryptedSharedPreferences), so material at rest is wrapped by
 * the Android Keystore master key.
 */
@Singleton
class SessionStore @Inject constructor(
    private val secureStore: SecureStore,
    private val json: Json,
) {

    private val mutex = Mutex()
    private val cache = mutableMapOf<String, SessionState>()

    suspend fun load(peerUserId: String, peerDeviceId: String): SessionState? = mutex.withLock {
        val key = key(peerUserId, peerDeviceId)
        cache[key]?.let { return@withLock it.copy() }
        val raw = secureStore.getString(key) ?: return@withLock null
        val stored = runCatching { json.decodeFromString<StoredSession>(raw) }.getOrNull()
            ?: return@withLock null
        val st = stored.toState()
        cache[key] = st
        st.copy()
    }

    suspend fun save(peerUserId: String, peerDeviceId: String, state: SessionState) = mutex.withLock {
        val key = key(peerUserId, peerDeviceId)
        cache[key] = state.copy()
        secureStore.putString(key, json.encodeToString(StoredSession.fromState(state)))
    }

    suspend fun clear(peerUserId: String, peerDeviceId: String) = mutex.withLock {
        val k = key(peerUserId, peerDeviceId)
        cache.remove(k)
        secureStore.remove(k)
    }

    /**
     * Wipe in-process session cache + every persisted `e2ee.session.*`
     * entry. Called from [app.raven.core.security.TokenStore.signOutLocally]
     * via [app.raven.core.security.SignOutHooks] so a sign-out → sign-in
     * without process restart cannot reuse prior peer sessions.
     */
    fun clearAll() = runBlocking {
        mutex.withLock {
            cache.clear()
            secureStore.removeByPrefix("e2ee.session.")
        }
    }

    private fun key(peerUserId: String, peerDeviceId: String) =
        "e2ee.session.$peerUserId.$peerDeviceId"
}

/**
 * Phase 2f session state — double-ratchet shape.
 *
 * Replaces Phase 2e's flat `rootKey + per-counter HKDF` model with
 * per-direction **chain keys** that ratchet forward on every message
 * (see [DoubleRatchet]). The root key is kept around for an eventual
 * Phase 2g DH-ratchet upgrade but no longer participates in the
 * per-message keying.
 *
 * Field-by-field:
 *   • [rootKey] — original X3DH-derived secret. Frozen after init;
 *     Phase 2g's DH ratchet will start re-deriving this on each peer
 *     DH pub change
 *   • [sendChainKey] / [recvChainKey] — the live symmetric chain keys.
 *     Per-message: `(next_chain, msg_key) = HMAC(chain, [0x02|0x01])`.
 *     The chain ALWAYS advances on send/recv — never reuse a key
 *   • [sendCount] — number of messages I've sent in this chain
 *   • [recvCount] — high-watermark of accepted counters from peer
 *   • [replayWindow] — 32-slot bitmap behind [recvCount]; bit i set
 *     means counter `(recvCount - 1 - i)` already accepted
 *   • [anchorEphemeralPub] — the initiator's X25519 ephemeral, used
 *     verbatim on every outbound wire header so the responder can
 *     replay X3DH on first inbound (and so a future re-establish can
 *     detect "fresh ephemeral → new session")
 *   • [myEphemeralPriv] — initiator-only; held for the eventual DH
 *     ratchet that will need to ECDH our priv against a rotated peer
 *     pub. Null on responder side
 *   • [peerIdentityKey] — peer's Ed25519 identity pub. TOFU foundation:
 *     a fresh bundle fetch comparing this against the new bytes is
 *     how the UI banner detects "identity changed" in Phase 2g
 *   • [peerStaticPub] — peer's X25519 identity-agreement pub
 *   • [peerSignedPrekey] — peer's X25519 SPK pub used for X3DH
 */
data class SessionState(
    val rootKey: ByteArray,
    val sendChainKey: ByteArray,
    val recvChainKey: ByteArray,
    val sendCount: Long,
    val recvCount: Long,
    val replayWindow: Long,
    val anchorEphemeralPub: ByteArray,
    val myEphemeralPriv: ByteArray?,
    val peerIdentityKey: ByteArray,
    val peerStaticPub: ByteArray,
    val peerSignedPrekey: ByteArray,
)

@Serializable
private data class StoredSession(
    val rootKeyB64: String,
    val sendChainKeyB64: String,
    val recvChainKeyB64: String,
    val sendCount: Long,
    val recvCount: Long,
    val replayWindow: Long = 0L,
    val anchorEphemeralPubB64: String,
    val myEphemeralPrivB64: String?,
    val peerIdentityKeyB64: String,
    val peerStaticPubB64: String,
    val peerSignedPrekeyB64: String,
) {
    fun toState(): SessionState = SessionState(
        rootKey = Base64.decode(rootKeyB64, Base64.NO_WRAP),
        sendChainKey = Base64.decode(sendChainKeyB64, Base64.NO_WRAP),
        recvChainKey = Base64.decode(recvChainKeyB64, Base64.NO_WRAP),
        sendCount = sendCount,
        recvCount = recvCount,
        replayWindow = replayWindow,
        anchorEphemeralPub = Base64.decode(anchorEphemeralPubB64, Base64.NO_WRAP),
        myEphemeralPriv = myEphemeralPrivB64?.let { Base64.decode(it, Base64.NO_WRAP) },
        peerIdentityKey = Base64.decode(peerIdentityKeyB64, Base64.NO_WRAP),
        peerStaticPub = Base64.decode(peerStaticPubB64, Base64.NO_WRAP),
        peerSignedPrekey = Base64.decode(peerSignedPrekeyB64, Base64.NO_WRAP),
    )

    companion object {
        fun fromState(s: SessionState) = StoredSession(
            rootKeyB64 = Base64.encodeToString(s.rootKey, Base64.NO_WRAP),
            sendChainKeyB64 = Base64.encodeToString(s.sendChainKey, Base64.NO_WRAP),
            recvChainKeyB64 = Base64.encodeToString(s.recvChainKey, Base64.NO_WRAP),
            sendCount = s.sendCount,
            recvCount = s.recvCount,
            replayWindow = s.replayWindow,
            anchorEphemeralPubB64 = Base64.encodeToString(s.anchorEphemeralPub, Base64.NO_WRAP),
            myEphemeralPrivB64 = s.myEphemeralPriv?.let { Base64.encodeToString(it, Base64.NO_WRAP) },
            peerIdentityKeyB64 = Base64.encodeToString(s.peerIdentityKey, Base64.NO_WRAP),
            peerStaticPubB64 = Base64.encodeToString(s.peerStaticPub, Base64.NO_WRAP),
            peerSignedPrekeyB64 = Base64.encodeToString(s.peerSignedPrekey, Base64.NO_WRAP),
        )
    }
}
