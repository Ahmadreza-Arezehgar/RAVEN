package app.raven.core.security

import android.util.Base64
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import java.security.SecureRandom
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Per-device identity keys for E2EE.
 *
 * Mirror of iOS `DeviceIdentityService` — two separate keypairs:
 *
 *   • **Ed25519 signing key** — long-lived per-device identity.
 *     Public half goes in the prekey bundle as `identity_key`. Used
 *     to sign signed-prekeys, mesh post envelopes, etc.
 *   • **X25519 agreement key** — used for ECDH during X3DH /
 *     pair-init. Public half goes in the bundle as
 *     `identity_agreement_key`. iOS uses a separate key for ECDH
 *     because CryptoKit needs distinct types for SigningKey vs
 *     KeyAgreementKey — we follow the same split so future Noise
 *     transport interop is friction-free.
 *
 * Both private halves are stored as raw 32-byte arrays inside
 * [SecureStore], which is Android Keystore-fenced. The Curve25519
 * curves aren't supported by Android Keystore directly (only RSA +
 * NIST EC P-256/384), so we manage the material at the application
 * layer and rely on Keystore-encrypted SharedPreferences for
 * at-rest protection — same posture as the SQLCipher passphrase.
 */
@Singleton
class IdentityKeyService @Inject constructor(
    private val secureStore: SecureStore,
) {

    private val mutex = Mutex()

    /**
     * Get-or-generate the long-lived Ed25519 signing keypair.
     * Returns the 32-byte private + 32-byte public seed pair.
     * Idempotent — subsequent calls return the same keys.
     */
    suspend fun ed25519Keypair(): Ed25519Keypair = mutex.withLock {
        val existing = secureStore.getBytes(SecureStore.KEY_IDENTITY_ED25519_PRIV)
        if (existing != null && existing.size == 32) {
            val sk = Ed25519PrivateKeyParameters(existing, 0)
            return@withLock Ed25519Keypair(privateKey = existing, publicKey = sk.generatePublicKey().encoded)
        }
        val rng = SecureRandom()
        val sk = Ed25519PrivateKeyParameters(rng)
        val priv = sk.encoded
        val pub = sk.generatePublicKey().encoded
        secureStore.putBytes(SecureStore.KEY_IDENTITY_ED25519_PRIV, priv)
        Ed25519Keypair(privateKey = priv, publicKey = pub)
    }

    /**
     * Get-or-generate the long-lived X25519 agreement keypair.
     * Same shape as [ed25519Keypair] but for ECDH.
     */
    suspend fun x25519Keypair(): X25519Keypair = mutex.withLock {
        val existing = secureStore.getBytes(SecureStore.KEY_IDENTITY_X25519_PRIV)
        if (existing != null && existing.size == 32) {
            val sk = X25519PrivateKeyParameters(existing, 0)
            return@withLock X25519Keypair(privateKey = existing, publicKey = sk.generatePublicKey().encoded)
        }
        val rng = SecureRandom()
        val sk = X25519PrivateKeyParameters(rng)
        val priv = sk.encoded
        val pub = sk.generatePublicKey().encoded
        secureStore.putBytes(SecureStore.KEY_IDENTITY_X25519_PRIV, priv)
        X25519Keypair(privateKey = priv, publicKey = pub)
    }

    /** Wipe both identity keys. Called on sign-out + account-switch
     *  so the next sign-in gets fresh material. */
    fun reset() {
        secureStore.remove(SecureStore.KEY_IDENTITY_ED25519_PRIV)
        secureStore.remove(SecureStore.KEY_IDENTITY_X25519_PRIV)
    }
}

data class Ed25519Keypair(
    val privateKey: ByteArray,  // 32 bytes
    val publicKey: ByteArray,   // 32 bytes
) {
    val publicKeyBase64: String get() = Base64.encodeToString(publicKey, Base64.NO_WRAP)
}

data class X25519Keypair(
    val privateKey: ByteArray,
    val publicKey: ByteArray,
) {
    val publicKeyBase64: String get() = Base64.encodeToString(publicKey, Base64.NO_WRAP)
}
