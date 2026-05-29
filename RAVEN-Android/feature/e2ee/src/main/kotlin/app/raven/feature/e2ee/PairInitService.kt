package app.raven.feature.e2ee

import android.util.Base64
import android.util.Log
import app.raven.core.security.IdentityKeyService
import app.raven.core.security.TokenStore
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Phase 2f pair-init: fetches the peer's prekey bundle, **verifies
 * the signed-prekey Ed25519 signature**, runs simplified X3DH
 * ([X3DHSession]), derives the initial direction-specific chain keys
 * via [DoubleRatchet.initialChainKeys], and caches a [SessionState] in
 * [SessionStore] keyed `(peerUserId, peerDeviceId)`.
 *
 * What changed from Phase 2e:
 *   • SPK signature verification — catches a malicious server that
 *     swaps a peer's `signed_pre_key` for one it controls. The signature
 *     is Ed25519 over the SPK pub bytes by the peer's identity key
 *   • Chain key bootstrap — instead of just storing the root, we derive
 *     `sendChainKey` and `recvChainKey` immediately so the first
 *     [MessageSealer.sealOutgoing] / [MessageSealer.openIncoming] can
 *     start ratcheting per Signal §5.2
 *   • Peer identity key persistence — for the Phase 2g TOFU UI banner
 *     that compares fresh-fetched identity bytes against the cached
 *     ones and warns the user on change
 *
 * Initiator flow ([initiator]):
 *   1. Cache hit → return early
 *   2. Fetch peer bundle
 *   3. **Verify signed_pre_key_signature** against bundle.identity_key
 *   4. Mint X25519 ephemeral
 *   5. X3DH → root
 *   6. [DoubleRatchet.initialChainKeys] → (sendChain, recvChain)
 *   7. Persist
 *
 * Responder flow ([responder]):
 *   1. Cache check — reuse if anchor ephemeral matches
 *   2. Fetch peer bundle (need identity X25519 — wire only carries eph)
 *   3. Verify peer's own SPK signature (peer might be impersonated)
 *   4. Load OUR SPK priv
 *   5. X3DH responder → same root the initiator computed
 *   6. Derive chain keys
 *   7. Persist
 */
@Singleton
class PairInitService @Inject constructor(
    private val identityKeys: IdentityKeyService,
    private val bundleApi: E2eeBundleApi,
    private val sessionStore: SessionStore,
    private val prekeyBundleService: PrekeyBundleService,
    private val tokenStore: TokenStore,
) {

    private val mutex = Mutex()

    suspend fun initiator(
        peerUserId: String,
        peerDeviceId: String = DEFAULT_PEER_DEVICE,
    ): SessionState? = mutex.withLock {
        sessionStore.load(peerUserId, peerDeviceId)?.let { return@withLock it }

        val bundle = fetchBundle(peerUserId, peerDeviceId) ?: return@withLock null

        // ── SPK signature verify ──────────────────────────────────
        val peerIdentityKey = decodeKey(bundle.identityKey, "identity_key", 32)
            ?: return@withLock null
        val peerStaticPub = decodeKey(bundle.identityAgreementKey, "identity_agreement_key", 32)
            ?: return@withLock null
        val peerSpkPub = decodeKey(bundle.signedPreKey, "signed_pre_key", 32)
            ?: return@withLock null
        val spkSig = runCatching { Base64.decode(bundle.signedPreKeySignature, Base64.NO_WRAP) }
            .getOrNull()
        if (spkSig == null || !verifyEd25519(peerIdentityKey, peerSpkPub, spkSig)) {
            Log.w(LOG_TAG, "SPK signature verify FAILED for $peerUserId/$peerDeviceId — " +
                "refusing to establish session (likely server tampering)")
            return@withLock null
        }

        val meId = tokenStore.currentUserId().orEmpty()
        val myStatic = identityKeys.x25519Keypair()
        val (ephPriv, ephPub) = X25519Ephemeral.generate()

        val root = X3DHSession.deriveInitiator(
            myStaticPriv = myStatic.privateKey,
            myEphPriv = ephPriv,
            peerStaticPub = peerStaticPub,
            peerSpkPub = peerSpkPub,
        )
        val (sendChain, recvChain) = DoubleRatchet.initialChainKeys(
            rootKey = root,
            meUserId = meId,
            peerUserId = peerUserId,
        )

        val session = SessionState(
            rootKey = root,
            sendChainKey = sendChain,
            recvChainKey = recvChain,
            sendCount = 0,
            recvCount = 0,
            replayWindow = 0L,
            anchorEphemeralPub = ephPub,
            myEphemeralPriv = ephPriv,
            peerIdentityKey = peerIdentityKey,
            peerStaticPub = peerStaticPub,
            peerSignedPrekey = peerSpkPub,
        )
        sessionStore.save(peerUserId, peerDeviceId, session)
        Log.i(LOG_TAG, "Initiator session established for $peerUserId/$peerDeviceId")
        session
    }

    suspend fun responder(
        peerUserId: String,
        peerEphemeralPub: ByteArray,
        peerDeviceId: String = DEFAULT_PEER_DEVICE,
    ): SessionState? = mutex.withLock {
        sessionStore.load(peerUserId, peerDeviceId)?.let { existing ->
            if (existing.anchorEphemeralPub.contentEquals(peerEphemeralPub)) {
                return@withLock existing
            }
            Log.i(LOG_TAG, "Peer eph rotated for $peerUserId — re-keying responder")
        }

        val mySpkPriv = prekeyBundleService.currentSignedPrekeyPrivate() ?: run {
            Log.w(LOG_TAG, "No SPK priv on device — responder establish refused")
            return@withLock null
        }
        val mySpkPub = prekeyBundleService.currentSignedPrekeyPublic() ?: ByteArray(0)

        // Pull peer's bundle so we can: (a) bind peer's identity X25519
        // for DH1/DH2 in X3DH responder, (b) record peer's identity
        // Ed25519 in the session for TOFU, (c) verify peer's SPK
        // signature so a stolen-token attacker can't fabricate
        // initiator messages with a forged SPK.
        val peerBundle = fetchBundle(peerUserId, peerDeviceId) ?: return@withLock null
        val peerIdentityKey = decodeKey(peerBundle.identityKey, "identity_key", 32)
            ?: return@withLock null
        val peerStaticPub = decodeKey(peerBundle.identityAgreementKey, "identity_agreement_key", 32)
            ?: return@withLock null
        val peerSpkPub = decodeKey(peerBundle.signedPreKey, "signed_pre_key", 32)
            ?: return@withLock null
        val spkSig = runCatching { Base64.decode(peerBundle.signedPreKeySignature, Base64.NO_WRAP) }
            .getOrNull()
        if (spkSig == null || !verifyEd25519(peerIdentityKey, peerSpkPub, spkSig)) {
            Log.w(LOG_TAG, "Peer SPK signature verify failed (responder) for $peerUserId — refusing")
            return@withLock null
        }

        val meId = tokenStore.currentUserId().orEmpty()
        val myStatic = identityKeys.x25519Keypair()
        val root = X3DHSession.deriveResponder(
            myStaticPriv = myStatic.privateKey,
            mySpkPriv = mySpkPriv,
            peerStaticPub = peerStaticPub,
            peerEphPub = peerEphemeralPub,
        )
        val (sendChain, recvChain) = DoubleRatchet.initialChainKeys(
            rootKey = root,
            meUserId = meId,
            peerUserId = peerUserId,
        )

        val session = SessionState(
            rootKey = root,
            sendChainKey = sendChain,
            recvChainKey = recvChain,
            sendCount = 0,
            recvCount = 0,
            replayWindow = 0L,
            anchorEphemeralPub = peerEphemeralPub.copyOf(),
            myEphemeralPriv = null,
            peerIdentityKey = peerIdentityKey,
            peerStaticPub = peerStaticPub,
            peerSignedPrekey = mySpkPub,  // ours; for auditability
        )
        sessionStore.save(peerUserId, peerDeviceId, session)
        Log.i(LOG_TAG, "Responder session established for $peerUserId/$peerDeviceId")
        session
    }

    // ─── Helpers ────────────────────────────────────────────────

    private suspend fun fetchBundle(peerUserId: String, peerDeviceId: String): FetchedBundleResponseDto? =
        runCatching {
            bundleApi.fetchBundle(peerUserId, peerDeviceId)
        }.getOrElse {
            Log.w(LOG_TAG, "Bundle fetch failed for $peerUserId/$peerDeviceId: ${it.message}")
            null
        }

    /** Base64-decode a fixed-length public key from a bundle field. */
    private fun decodeKey(b64: String, fieldName: String, expectedLen: Int): ByteArray? {
        val bytes = runCatching { Base64.decode(b64, Base64.NO_WRAP) }.getOrNull()
        if (bytes == null || bytes.size != expectedLen) {
            Log.w(LOG_TAG, "Bundle field $fieldName has bad length (${bytes?.size}, want $expectedLen)")
            return null
        }
        return bytes
    }

    /**
     * Verify an Ed25519 signature using BouncyCastle. Returns false
     * on any exception (malformed key, malformed sig, length mismatch)
     * to keep the call site simple — we treat all failure modes the
     * same: refuse to establish the session.
     */
    private fun verifyEd25519(publicKey: ByteArray, message: ByteArray, signature: ByteArray): Boolean {
        return try {
            val pub = Ed25519PublicKeyParameters(publicKey, 0)
            val verifier = Ed25519Signer().apply {
                init(false, pub)
                update(message, 0, message.size)
            }
            verifier.verifySignature(signature)
        } catch (t: Throwable) {
            Log.w(LOG_TAG, "Ed25519 verify exception: ${t.message}")
            false
        }
    }

    companion object {
        private const val LOG_TAG = "PairInit"
        const val DEFAULT_PEER_DEVICE = "ios-primary"
    }
}
