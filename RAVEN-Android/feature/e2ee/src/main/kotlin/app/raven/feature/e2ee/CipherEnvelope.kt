package app.raven.feature.e2ee

import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Inner cipher envelope carried inside an [MessageEnvelope.SEALED_MAGIC]
 * (RVNS1) wire frame. Phase 2e shape:
 *
 *   ┌────────┬─────────────────────────────────────────────────┐
 *   │ 1 byte │ Version = 0x01                                  │
 *   │ 32 b   │ Sender's ephemeral X25519 public key            │
 *   │ 8 b    │ Big-endian message counter (per session)        │
 *   │ 12 b   │ AES-GCM IV (random per message)                 │
 *   │ N b    │ AES-GCM ciphertext + 16-byte auth tag           │
 *   └────────┴─────────────────────────────────────────────────┘
 *
 * The receiver:
 *   1. Strips the 8-byte RVNS1 magic.
 *   2. Reads version + ephemeral_pub + counter + IV.
 *   3. Looks up the per-peer root key (running X3DH responder side
 *      on first message from this ephemeral).
 *   4. Derives `msg_key = HKDF(root, "raven-msg-v1|counter")`.
 *   5. AES-GCM-decrypts with `(msg_key, IV, AAD)`.
 *
 * AAD binds sender id + recipient id + msgId so a malicious server
 * can't re-point ciphertext between (sender, recipient) pairs —
 * same defence iOS adds in `MessageContentSealer` round 13.
 *
 * Not iOS-interop: iOS uses Signal's Double Ratchet over a Noise
 * transport. Phase 2f ports the Signal stack for cross-platform
 * interop. Phase 2e gives us real working E2EE between Android
 * RAVEN users — the wire format is documented end-to-end so a
 * future iOS-bridge codec can read these envelopes if needed.
 */
object CipherEnvelope {

    const val VERSION: Byte = 0x01
    private const val EPH_PUB_LEN = 32
    private const val COUNTER_LEN = 8
    private const val IV_LEN = 12
    /** 1 (version) + 32 (eph) + 8 (counter) + 12 (iv) */
    const val HEADER_LEN = 1 + EPH_PUB_LEN + COUNTER_LEN + IV_LEN

    data class Encoded(
        val bytes: ByteArray,
        /** Header alone, used as AES-GCM AAD by both sides. */
        val header: ByteArray,
    )

    /** Build the wire bytes for one sealed message. */
    fun encode(
        msgKey: ByteArray,
        ephemeralPub: ByteArray,
        counter: Long,
        iv: ByteArray,
        plaintext: ByteArray,
        ad: ByteArray,
    ): Encoded {
        require(ephemeralPub.size == EPH_PUB_LEN) { "ephemeral pub must be 32 bytes" }
        require(iv.size == IV_LEN) { "iv must be 12 bytes" }

        val header = ByteArray(HEADER_LEN).apply {
            this[0] = VERSION
            System.arraycopy(ephemeralPub, 0, this, 1, EPH_PUB_LEN)
            // Counter big-endian
            for (i in 0 until COUNTER_LEN) {
                this[1 + EPH_PUB_LEN + i] = ((counter ushr ((COUNTER_LEN - 1 - i) * 8)) and 0xFF).toByte()
            }
            System.arraycopy(iv, 0, this, 1 + EPH_PUB_LEN + COUNTER_LEN, IV_LEN)
        }

        // Bind header + caller-supplied AD into the AES-GCM AAD so a
        // server-side splice attack (swap header to point at a
        // different sender) is detected on decrypt.
        val aad = header + ad
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(msgKey, "AES"), GCMParameterSpec(128, iv))
            updateAAD(aad)
        }
        val ct = cipher.doFinal(plaintext)
        return Encoded(bytes = header + ct, header = header)
    }

    data class ParsedHeader(
        val version: Byte,
        val ephemeralPub: ByteArray,
        val counter: Long,
        val iv: ByteArray,
        val ciphertext: ByteArray,
        val header: ByteArray,
    )

    /** Parse the wire bytes (post-RVNS1-magic). Returns null on
     *  malformed input. */
    fun decodeHeader(payload: ByteArray): ParsedHeader? {
        if (payload.size < HEADER_LEN + 16) return null  // 16 = AEAD tag floor
        val version = payload[0]
        if (version != VERSION) return null
        val ephemeralPub = payload.copyOfRange(1, 1 + EPH_PUB_LEN)
        var counter = 0L
        for (i in 0 until COUNTER_LEN) {
            counter = (counter shl 8) or (payload[1 + EPH_PUB_LEN + i].toLong() and 0xFF)
        }
        val iv = payload.copyOfRange(
            1 + EPH_PUB_LEN + COUNTER_LEN,
            1 + EPH_PUB_LEN + COUNTER_LEN + IV_LEN,
        )
        val ciphertext = payload.copyOfRange(HEADER_LEN, payload.size)
        val header = payload.copyOfRange(0, HEADER_LEN)
        return ParsedHeader(version, ephemeralPub, counter, iv, ciphertext, header)
    }

    /** Decrypt a parsed envelope. Returns null when AEAD verify fails. */
    fun decrypt(
        msgKey: ByteArray,
        parsed: ParsedHeader,
        ad: ByteArray,
    ): ByteArray? {
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, SecretKeySpec(msgKey, "AES"), GCMParameterSpec(128, parsed.iv))
                updateAAD(parsed.header + ad)
            }
            cipher.doFinal(parsed.ciphertext)
        } catch (_: Throwable) {
            null
        }
    }
}
