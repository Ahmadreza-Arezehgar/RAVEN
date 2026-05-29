package app.raven.feature.e2ee

import android.util.Base64

/**
 * Wire-format envelope for message content. Pixel-identical to iOS
 * `MessageContentSealer.swift`:
 *
 *   ┌──────────┬──────────────────────────────────────────────┐
 *   │ 8 bytes  │ "RVNS1\0\0\0" — sealed (Noise transport CT)  │
 *   │ N bytes  │ Ciphertext + AEAD tag                        │
 *   └──────────┴──────────────────────────────────────────────┘
 *
 *   ┌──────────┬──────────────────────────────────────────────┐
 *   │ 8 bytes  │ "RVNP1\0\0\0" — plaintext fallback           │
 *   │ N bytes  │ UTF-8 message body                           │
 *   └──────────┴──────────────────────────────────────────────┘
 *
 * Both shapes are Base64-encoded before they go on the wire — the
 * server only sees opaque bytes in either case. The receiver
 * checks the magic and either decrypts (RVNS1) or unwraps (RVNP1).
 *
 * Phase 2c ships RVNP1 wrap on the outbound path so the server
 * sees opaque-shaped bytes from Android too (no naked plaintext in
 * the `content` field). Phase 2d adds RVNS1 encryption via
 * X3DH + AES-GCM once the pair-init flow lands.
 */
object MessageEnvelope {

    val SEALED_MAGIC: ByteArray = byteArrayOf(0x52, 0x56, 0x4E, 0x53, 0x31, 0x00, 0x00, 0x00)
    val PLAIN_MAGIC: ByteArray = byteArrayOf(0x52, 0x56, 0x4E, 0x50, 0x31, 0x00, 0x00, 0x00)

    /** Max wire-bytes — same 256 KB cap iOS enforces. */
    const val MAX_WIRE_BYTES = 256 * 1024

    /** AEAD-tag floor for RVNS1 — anything smaller is invalid. */
    const val MIN_SEALED_REST = 17

    sealed interface Decoded {
        /** Recognised RVNP1 — plaintext body. */
        data class Plaintext(val text: String) : Decoded

        /** Recognised RVNS1 — ciphertext bytes (post-header). The
         *  caller has the session key and decrypts. Phase 2c
         *  surfaces this as "[encrypted, can't read yet]". */
        data class Sealed(val ciphertext: ByteArray) : Decoded

        /** Anything else — pre-envelope legacy content or garbage. */
        data class Legacy(val raw: String) : Decoded
    }

    /**
     * Wrap a UTF-8 plaintext into the RVNP1 envelope, then Base64
     * encode. The server stores the result as opaque bytes.
     *
     * Empty / null returns "" so the caller can short-circuit
     * — empty messages don't go on the wire (matches iOS guard).
     */
    fun encodePlaintext(text: String): String {
        if (text.isEmpty()) return ""
        val body = text.toByteArray(Charsets.UTF_8)
        val out = ByteArray(PLAIN_MAGIC.size + body.size)
        System.arraycopy(PLAIN_MAGIC, 0, out, 0, PLAIN_MAGIC.size)
        System.arraycopy(body, 0, out, PLAIN_MAGIC.size, body.size)
        if (out.size > MAX_WIRE_BYTES) {
            // Truncate isn't right — refuse the send by returning
            // empty so the caller can surface an error. iOS rejects
            // the same way.
            return ""
        }
        return Base64.encodeToString(out, Base64.NO_WRAP)
    }

    /**
     * Decode a `content` string from the wire. Falls back to
     * [Decoded.Legacy] for content that's neither RVNP1 nor RVNS1
     * (e.g. messages from very old clients pre-envelope, or
     * deliberately-plaintext system messages).
     */
    fun decode(raw: String?): Decoded {
        if (raw.isNullOrEmpty()) return Decoded.Legacy("")
        val bytes = try {
            Base64.decode(raw, Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            return Decoded.Legacy(raw)
        }
        if (bytes.size > MAX_WIRE_BYTES) return Decoded.Legacy(raw)
        if (bytes.size < 8) return Decoded.Legacy(raw)
        val header = bytes.copyOfRange(0, 8)
        return when {
            header.contentEquals(PLAIN_MAGIC) -> {
                val body = bytes.copyOfRange(8, bytes.size)
                Decoded.Plaintext(String(body, Charsets.UTF_8))
            }
            header.contentEquals(SEALED_MAGIC) -> {
                val ct = bytes.copyOfRange(8, bytes.size)
                if (ct.size < MIN_SEALED_REST) Decoded.Legacy(raw)
                else Decoded.Sealed(ct)
            }
            else -> Decoded.Legacy(raw)
        }
    }
}
