package app.raven.feature.chat.data

/**
 * Defends the chat UI against server-side at-rest ciphertext that
 * occasionally leaks into name fields.
 *
 * The server Fernet-encrypts `User.first_name` / `last_name` columns
 * and is supposed to `decrypt_text()` them before responding — but
 * `/api/messages/conversations` skips that step, so the peer's first
 * and last name arrive as raw Fernet tokens (`gAAAA…`). The iOS app
 * carries the same `String.looksEncrypted` guard; this is the Kotlin
 * mirror of it so a ciphertext blob never reaches a name label.
 */

/** True when [this] looks like an encrypted token, not a human name. */
fun String.looksEncrypted(): Boolean {
    val s = trim()
    if (s.length < 20) return false
    // Fernet tokens start "gAAAA"; JWT-ish blobs start "eyJ".
    if (s.startsWith("gAAAA") || s.startsWith("eyJ")) return true
    // A long, unbroken base64 / base64url token with no whitespace
    // is almost certainly ciphertext rather than a person's name.
    if (s.length >= 40 && s.none { it.isWhitespace() } &&
        s.all { it.isLetterOrDigit() || it in "+/=-_" }
    ) {
        return true
    }
    return false
}

/** [raw] trimmed, or null when it is blank or [looksEncrypted]. */
fun cleanNameOrNull(raw: String?): String? =
    raw?.trim()?.takeIf { it.isNotEmpty() && !it.looksEncrypted() }

/**
 * Build a human-readable peer name from raw wire fields, dropping any
 * ciphertext that leaked through and falling back gracefully:
 * `first last` → `username` → `User <id-prefix>`.
 */
fun composePeerName(
    firstName: String?,
    lastName: String?,
    username: String,
    userId: String,
): String {
    val parts = listOfNotNull(cleanNameOrNull(firstName), cleanNameOrNull(lastName))
    val composed = parts.joinToString(" ")
    if (composed.isNotBlank()) return composed
    if (username.isNotBlank()) return username
    return "User ${userId.take(6)}"
}
