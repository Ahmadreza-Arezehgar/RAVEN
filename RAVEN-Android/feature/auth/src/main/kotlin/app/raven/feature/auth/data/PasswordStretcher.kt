package app.raven.feature.auth.data

import android.util.Base64
import java.security.MessageDigest
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/**
 * Client-side password key-stretching. Byte-exact match for
 * `PasswordStretcher.stretch` in
 * `ios-native/RAVEN/RAVEN/Core/Security/E2EE/PasswordStretcher.swift`.
 *
 * The raw password never leaves the device: register / login send a
 * PBKDF2-HMAC-SHA256 derivative under a username-bound salt. The
 * server bcrypt-hashes whatever string the client sends, so this
 * value MUST be identical to what iOS produces — otherwise a
 * cross-client login fails with 401.
 *
 * Wire format — `"RVNS1$" + base64(derived)`:
 *   • algorithm  : PBKDF2-HMAC-SHA256
 *   • iterations : 600_000  (OWASP 2023)
 *   • salt       : SHA-256("RAVEN-PWS-v1|" + lowercased(username))
 *   • output     : 32 bytes, standard base64 (44 chars incl. padding)
 *
 * The `RVNS1$` marker lets the server tell a stretched password from
 * a legacy plaintext one.
 */
object PasswordStretcher {

    /** Wire-format marker for a stretched password — must match iOS. */
    private const val WIRE_MARKER = "RVNS1\$"

    /** OWASP-recommended PBKDF2-SHA256 iteration count (2023). */
    private const val ITERATIONS = 600_000

    /** 32-byte derived key. */
    private const val KEY_LENGTH_BITS = 256

    /**
     * Stretch [password] into the server-bound value to send on
     * register / login. [usernameLowercased] must be the lowercased
     * username so a capitalisation typo can't break login.
     */
    fun stretch(password: String, usernameLowercased: String): String {
        if (password.isEmpty()) return ""

        // Salt = SHA-256("RAVEN-PWS-v1|" + username). Mirrors the iOS
        // `saltBytes(forUsername:)` v1 form — iOS keeps v1 as the
        // active path so existing accounts keep logging in.
        val saltSeed = "RAVEN-PWS-v1|$usernameLowercased".toByteArray(Charsets.UTF_8)
        val salt = MessageDigest.getInstance("SHA-256").digest(saltSeed)

        val spec = PBEKeySpec(password.toCharArray(), salt, ITERATIONS, KEY_LENGTH_BITS)
        val derived = SecretKeyFactory
            .getInstance("PBKDF2WithHmacSHA256")
            .generateSecret(spec)
            .encoded

        // Standard padded base64, single line — matches Swift's
        // `Data.base64EncodedString()`.
        return WIRE_MARKER + Base64.encodeToString(derived, Base64.NO_WRAP)
    }
}
