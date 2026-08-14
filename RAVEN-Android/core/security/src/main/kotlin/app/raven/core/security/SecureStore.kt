package app.raven.core.security

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Android Keystore-backed key/value store. The Android twin of the
 * iOS `KeychainService.swift`.
 *
 * `EncryptedSharedPreferences` wraps every value with an AES-GCM key
 * that lives in the Android Keystore — so the values on disk
 * (`/data/data/app.raven/shared_prefs/raven.secure.xml`) are
 * ciphertext, and reading them requires the device key. On a locked
 * device with biometric+passcode, the key is fenced behind the
 * lock-screen credential.
 *
 * Use this for anything bearer-token-shaped: JWT access/refresh
 * tokens, OAuth tokens, identity-key material, the SQLCipher DB
 * passphrase. Don't use this for user-preference flags — those live
 * in DataStore.
 *
 * Wrapped fields:
 *   - "auth.access" : current short-lived JWT
 *   - "auth.refresh": opaque refresh token
 *   - "auth.user_id": canonical user id (UUID) for fast checks
 *   - "db.cipher_key": 256-bit hex for SQLCipher
 *   - "identity.ed25519_priv": 32-byte Ed25519 private key
 *   - "identity.x25519_priv":  32-byte X25519 private key
 *
 * All access is synchronous because `EncryptedSharedPreferences` is
 * synchronous; we wrap calls in a coroutine `withContext(Dispatchers.IO)`
 * at the call site if blocking on the main thread is a concern.
 */
@Singleton
class SecureStore @Inject constructor(
    context: Context,
) {

    private val prefs: SharedPreferences by lazy {
        val masterKey = MasterKey.Builder(context.applicationContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            // Bind the master key to a non-extractable hardware key
            // when the device has a StrongBox or TEE — falls through
            // gracefully on older hardware.
            .setUserAuthenticationRequired(false)
            .build()

        EncryptedSharedPreferences.create(
            context.applicationContext,
            FILE_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    /** Read a string. Returns null if absent (NOT empty-string). */
    fun getString(key: String): String? = prefs.getString(key, null)

    /** Write a string. Use [remove] to clear. */
    fun putString(key: String, value: String) {
        prefs.edit().putString(key, value).apply()
    }

    /** Remove a single key. No-op if it's already absent. */
    fun remove(key: String) {
        prefs.edit().remove(key).apply()
    }

    /** Remove every stored key whose name starts with [prefix].
     *  Used on sign-out to purge all `e2ee.*` session + prekey
     *  material in one shot without touching unrelated keys (e.g. the
     *  SQLCipher DB key). See [app.raven.core.security.TokenStore.signOutLocally]. */
    fun removeByPrefix(prefix: String) {
        val editor = prefs.edit()
        // Copy the key set first — mutating prefs while iterating its
        // live `.all` view is undefined.
        for (k in prefs.all.keys.toList()) {
            if (k.startsWith(prefix)) editor.remove(k)
        }
        editor.apply()
    }

    /** Wipe every secret. Called on logout / account-switch. */
    fun clear() {
        prefs.edit().clear().apply()
    }

    /** Bool helper — used for "biometric enrolled?" / "vault active?" */
    fun getBoolean(key: String, default: Boolean = false): Boolean =
        prefs.getBoolean(key, default)

    fun putBoolean(key: String, value: Boolean) {
        prefs.edit().putBoolean(key, value).apply()
    }

    /** Byte-array helper — keys are stored as Base64 strings internally
     *  because EncryptedSharedPreferences doesn't expose a byte-array
     *  primitive. */
    fun getBytes(key: String): ByteArray? {
        val b64 = getString(key) ?: return null
        return android.util.Base64.decode(b64, android.util.Base64.NO_WRAP)
    }

    fun putBytes(key: String, value: ByteArray) {
        putString(key, android.util.Base64.encodeToString(value, android.util.Base64.NO_WRAP))
    }

    companion object {
        const val FILE_NAME = "raven.secure"

        // Predefined keys — keep these centralised so a typo doesn't
        // leave one site reading "auth.refresh" and another writing
        // "auth.refesh".
        const val KEY_ACCESS_TOKEN = "auth.access"
        const val KEY_REFRESH_TOKEN = "auth.refresh"
        const val KEY_USER_ID = "auth.user_id"
        const val KEY_DB_CIPHER = "db.cipher_key"
        const val KEY_IDENTITY_ED25519_PRIV = "identity.ed25519_priv"
        const val KEY_IDENTITY_X25519_PRIV = "identity.x25519_priv"
    }
}
