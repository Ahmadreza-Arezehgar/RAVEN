package app.raven.feature.e2ee

import android.util.Base64
import android.util.Log
import app.raven.core.security.IdentityKeyService
import app.raven.core.security.SecureStore
import app.raven.core.security.TokenStore
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.security.SecureRandom
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Manages the device's signed prekey bundle: builds it on first
 * launch, publishes to the server, and re-publishes whenever the
 * signed prekey rotates.
 *
 * Mirror of iOS `E2EEBootstrap.swift` — same publish-on-launch flow,
 * same field shapes. Phase 2c only handles the publish side;
 * fetching peer bundles for X3DH lands in Phase 2d when we actually
 * encrypt.
 */
@Singleton
class PrekeyBundleService @Inject constructor(
    private val identityKeys: IdentityKeyService,
    private val bundleApi: E2eeBundleApi,
    private val tokenStore: TokenStore,
    private val secureStore: SecureStore,
) {

    /**
     * Publish the bundle if it hasn't been published from this
     * install yet. Idempotent: subsequent calls re-publish only
     * when the local "needs-republish" flag is set (e.g. after a
     * signed-prekey rotation).
     */
    suspend fun ensurePublished() {
        val userId = tokenStore.currentUserId() ?: return
        if (secureStore.getBoolean(KEY_BUNDLE_PUBLISHED, false)) return

        runCatching {
            val req = buildBundle(userId = userId, deviceId = deviceId())
            bundleApi.publishBundle(req)
            secureStore.putBoolean(KEY_BUNDLE_PUBLISHED, true)
            Log.i(LOG_TAG, "Published E2EE bundle for $userId / ${req.deviceId}")
        }.onFailure { t ->
            // Non-fatal — Phase 2c isn't actually encrypting yet, so
            // a publish failure doesn't break message delivery. The
            // next ensurePublished() retries.
            Log.w(LOG_TAG, "Bundle publish failed: ${t.message}")
        }
    }

    /** Force a fresh publish on the next [ensurePublished] call.
     *  Used by Phase 2d's signed-prekey rotation worker. */
    fun markNeedsRepublish() {
        secureStore.putBoolean(KEY_BUNDLE_PUBLISHED, false)
    }

    /** Wipe the local "published" flag on logout — next sign-in
     *  republishes. Also drops the persisted SPK material so the
     *  next responder establishment can't decrypt sessions that were
     *  set up against the OLD bundle (defence-in-depth on account
     *  switch). */
    fun reset() {
        secureStore.putBoolean(KEY_BUNDLE_PUBLISHED, false)
        secureStore.remove(KEY_DEVICE_ID)
        secureStore.remove(KEY_SPK_PRIV)
        secureStore.remove(KEY_SPK_PUB)
    }

    // ─── Internals ───────────────────────────────────────────────

    /**
     * Load the device's current signed-prekey **private** key.
     *
     * Used by [PairInitService.responder] when a sealed message
     * arrives from a new peer — we need to ECDH their ephemeral
     * against our SPK priv to compute the responder-side root.
     *
     * Returns null if no bundle has been published yet (first
     * launch before [ensurePublished] runs). The responder path
     * surfaces the RVNS1 as "[encrypted — bundle not yet published]"
     * in that case.
     */
    fun currentSignedPrekeyPrivate(): ByteArray? =
        secureStore.getBytes(KEY_SPK_PRIV)

    /** Companion to [currentSignedPrekeyPrivate] — the matching
     *  public bytes. Kept around so responder sessions can record
     *  which SPK was used (auditability + future TOFU banner). */
    fun currentSignedPrekeyPublic(): ByteArray? =
        secureStore.getBytes(KEY_SPK_PUB)

    // ─── Internals ───────────────────────────────────────────────

    private suspend fun buildBundle(userId: String, deviceId: String): UploadBundleRequestDto {
        val ed = identityKeys.ed25519Keypair()
        val xa = identityKeys.x25519Keypair()

        // Generate a fresh signed-prekey for this publish. The id
        // is a small int the server uses to match consumed OPKs
        // back to a specific generation. Phase 2c keeps id=1 since
        // the rotation worker isn't wired yet — Phase 2f bumps it.
        val rng = SecureRandom()
        val signedPreKeyPriv = X25519PrivateKeyParameters(rng)
        val signedPreKeyPub = signedPreKeyPriv.generatePublicKey().encoded

        // Phase 2e: persist the SPK private alongside the public.
        // The responder side of X3DH (PairInitService.responder)
        // needs this priv to derive a root key from inbound
        // initiator messages. Without persistence, a device could
        // only INITIATE sessions — it could never decrypt one started
        // by a peer who fetched our published bundle.
        secureStore.putBytes(KEY_SPK_PRIV, signedPreKeyPriv.encoded)
        secureStore.putBytes(KEY_SPK_PUB, signedPreKeyPub)

        // Sign the prekey's public bytes with the identity Ed25519
        // key so peers can verify the prekey wasn't replaced by
        // the server. Same scheme iOS uses.
        val signature = ed25519Sign(ed.privateKey, signedPreKeyPub)

        val now = System.currentTimeMillis() / 1000.0
        return UploadBundleRequestDto(
            userId = userId,
            deviceId = deviceId,
            identityKey = Base64.encodeToString(ed.publicKey, Base64.NO_WRAP),
            identityAgreementKey = Base64.encodeToString(xa.publicKey, Base64.NO_WRAP),
            signedPreKeyId = 1,
            signedPreKey = Base64.encodeToString(signedPreKeyPub, Base64.NO_WRAP),
            signedPreKeySignature = Base64.encodeToString(signature, Base64.NO_WRAP),
            signedPreKeyCreatedAt = now,
            oneTimePreKeys = emptyList(),  // Phase 2f fills the pool
            createdAt = now,
        )
    }

    private fun ed25519Sign(privateKey: ByteArray, message: ByteArray): ByteArray {
        val sk = Ed25519PrivateKeyParameters(privateKey, 0)
        val signer = Ed25519Signer().apply {
            init(true, sk)
            update(message, 0, message.size)
        }
        return signer.generateSignature()
    }

    /**
     * Stable per-install device id. Generated on first call,
     * persisted in SecureStore so we don't end up with a fresh id
     * (and a fresh bundle row) every launch.
     */
    private fun deviceId(): String {
        val existing = secureStore.getString(KEY_DEVICE_ID)
        if (!existing.isNullOrBlank()) return existing
        val fresh = "and-" + java.util.UUID.randomUUID().toString()
        secureStore.putString(KEY_DEVICE_ID, fresh)
        return fresh
    }

    companion object {
        private const val LOG_TAG = "PrekeyBundle"
        private const val KEY_BUNDLE_PUBLISHED = "e2ee.bundle.published"
        private const val KEY_DEVICE_ID = "e2ee.device_id"
        // Phase 2e — kept current-only for now. Phase 2f's rotation
        // worker will move to a versioned key list so an old SPK
        // can be retired (and decrypt-only-replayed-messages).
        private const val KEY_SPK_PRIV = "e2ee.spk.priv"
        private const val KEY_SPK_PUB = "e2ee.spk.pub"
    }
}
