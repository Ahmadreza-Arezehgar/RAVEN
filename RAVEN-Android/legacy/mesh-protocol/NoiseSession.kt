// NoiseSession.kt (Android)
//
// `Noise_IK_25519_ChaChaPoly_SHA256` — IK pattern of the Noise Protocol
// Framework (https://noiseprotocol.org/noise.html#5.2). Sibling of:
//   • ios-native/RAVEN/RAVEN/Core/Security/NoiseSession.swift (canonical)
//   • RAVEN-MacApp/RAVEN/Core/Security/NoiseSession.swift
//   • RAVEN-Windows/src/Crypto/NoiseSession.cs
//
// The wire format and HKDF / ChaChaPoly / SHA-256 semantics MUST match
// the Swift sibling byte-for-byte so iOS/Mac ↔ Android interop works.
//
// External dependencies needed before this compiles:
//
//   ```kotlin
//   // app/build.gradle.kts
//   dependencies {
//       implementation("org.bouncycastle:bcprov-jdk18on:1.78")
//   }
//   ```
//
// BouncyCastle ships X25519 key agreement plus ChaCha20Poly1305; the
// Android Conscrypt provider also has both since API 30+, but BC is
// the simpler choice because it's available across the full minSdk
// range we ship.
//
// State-machine logic mirrors the Swift sibling step-for-step.

package app.raven.mesh

import org.bouncycastle.crypto.AsymmetricCipherKeyPair
import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.engines.ChaCha7539Engine
import org.bouncycastle.crypto.generators.X25519KeyPairGenerator
import org.bouncycastle.crypto.macs.Poly1305
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.ParametersWithIV
import org.bouncycastle.crypto.params.X25519KeyGenerationParameters
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

class NoiseException(message: String) : Exception(message)

/**
 * Drives a `Noise_IK_25519_ChaChaPoly_SHA256` handshake. Two
 * messages: initiator → responder, then responder → initiator.
 * Call [split] once both messages have been written/read to derive
 * the transport-mode cipher pair.
 */
class NoiseSession(
    private val role: Role,
    private val staticPrivate: ByteArray,
    private val staticPublic: ByteArray,
    peerStaticKey: ByteArray?,
    prologue: ByteArray = ByteArray(0),
) {
    enum class Role { INITIATOR, RESPONDER }

    companion object {
        const val PROTOCOL_NAME = "Noise_IK_25519_ChaChaPoly_SHA256"
    }

    private var ePrivate: ByteArray? = null
    private var ePublic: ByteArray? = null
    private var peerStatic: ByteArray? = peerStaticKey?.copyOf()
    private var peerEphemeral: ByteArray? = null

    private var ck = ByteArray(32)
    private var h = ByteArray(32)
    private var k: ByteArray? = null
    private var n: Long = 0
    private var msgIndex = 0

    /** Peer's static public key — non-null on the responder after [readMessage1]. */
    val peerStaticPublicKey: ByteArray?
        get() = peerStatic?.copyOf()

    /** Handshake hash — useful for binding application-level data
     *  (e.g. an out-of-band SAS string) to this session. Only
     *  meaningful after [split]. */
    val handshakeHash: ByteArray
        get() = h.copyOf()

    init {
        require(staticPrivate.size == 32) { "staticPrivate must be 32 bytes" }
        require(staticPublic.size == 32) { "staticPublic must be 32 bytes" }

        val nameBytes = PROTOCOL_NAME.toByteArray(Charsets.UTF_8)
        when {
            nameBytes.size == 32 -> nameBytes.copyInto(h)
            nameBytes.size < 32 -> nameBytes.copyInto(h, 0, 0, nameBytes.size)
            else -> h = MessageDigest.getInstance("SHA-256").digest(nameBytes)
        }
        h.copyInto(ck)

        mixHash(prologue)

        // IK pre-message: responder's static is mixed in by both sides
        // before message 1.
        when (role) {
            Role.INITIATOR -> {
                val rs = peerStatic ?: throw NoiseException("Initiator requires peerStaticKey for IK")
                mixHash(rs)
            }
            Role.RESPONDER -> mixHash(staticPublic)
        }
    }

    // ── SymmetricState helpers (Noise §5.2) ──────────────────────

    private fun mixHash(data: ByteArray) {
        val combined = ByteArray(h.size + data.size)
        h.copyInto(combined, 0)
        data.copyInto(combined, h.size)
        h = MessageDigest.getInstance("SHA-256").digest(combined)
    }

    private fun mixKey(input: ByteArray) {
        // HKDF(ck, input, n=2) → (ck', k')
        val prk = hmacSha256(ck, input)
        val t1 = hmacSha256(prk, byteArrayOf(0x01))
        val t2input = ByteArray(t1.size + 1).apply {
            t1.copyInto(this)
            this[t1.size] = 0x02
        }
        val t2 = hmacSha256(prk, t2input)
        ck = t1
        k = t2
        n = 0
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    /** 96-bit ChaChaPoly nonce: 4 zero bytes prefix + 8-byte LE counter. */
    private fun currentNonce(): ByteArray {
        val nonce = ByteArray(12)
        ByteBuffer.wrap(nonce, 4, 8).order(ByteOrder.LITTLE_ENDIAN).putLong(n)
        return nonce
    }

    private fun encryptAndHash(plaintext: ByteArray): ByteArray {
        val key = k ?: run {
            mixHash(plaintext)
            return plaintext
        }
        val ct = aeadSeal(key, currentNonce(), plaintext, h)
        n++
        mixHash(ct)
        return ct
    }

    private fun decryptAndHash(ciphertext: ByteArray): ByteArray {
        val key = k ?: run {
            mixHash(ciphertext)
            return ciphertext
        }
        if (ciphertext.size < 16) throw NoiseException("ciphertext too short for AEAD tag")
        val pt = aeadOpen(key, currentNonce(), ciphertext, h)
        n++
        mixHash(ciphertext)
        return pt
    }

    // ── ChaCha20-Poly1305 wrappers (BouncyCastle) ────────────────

    private fun aeadSeal(key: ByteArray, nonce: ByteArray, plaintext: ByteArray, ad: ByteArray): ByteArray {
        val aead = ChaCha20Poly1305()
        aead.init(true, AEADParameters(KeyParameter(key), 128, nonce, ad))
        val out = ByteArray(aead.getOutputSize(plaintext.size))
        val len = aead.processBytes(plaintext, 0, plaintext.size, out, 0)
        aead.doFinal(out, len)
        return out
    }

    private fun aeadOpen(key: ByteArray, nonce: ByteArray, ciphertext: ByteArray, ad: ByteArray): ByteArray {
        val aead = ChaCha20Poly1305()
        aead.init(false, AEADParameters(KeyParameter(key), 128, nonce, ad))
        val out = ByteArray(aead.getOutputSize(ciphertext.size))
        try {
            val len = aead.processBytes(ciphertext, 0, ciphertext.size, out, 0)
            val finalLen = aead.doFinal(out, len)
            return out.copyOf(len + finalLen)
        } catch (_: Exception) {
            throw NoiseException("AEAD verify failed")
        }
    }

    // ── X25519 key agreement (BouncyCastle) ──────────────────────

    private fun generateEphemeral(): Pair<ByteArray, ByteArray> {
        val gen = X25519KeyPairGenerator()
        gen.init(X25519KeyGenerationParameters(SecureRandom()))
        val pair: AsymmetricCipherKeyPair = gen.generateKeyPair()
        val priv = (pair.private as X25519PrivateKeyParameters).encoded
        val pub = (pair.public as X25519PublicKeyParameters).encoded
        return priv to pub
    }

    private fun dh(privateKey: ByteArray, publicKey: ByteArray): ByteArray {
        val priv = X25519PrivateKeyParameters(privateKey, 0)
        val pub = X25519PublicKeyParameters(publicKey, 0)
        val agreement = X25519Agreement()
        agreement.init(priv)
        val shared = ByteArray(agreement.agreementSize)
        agreement.calculateAgreement(pub, shared, 0)
        return shared
    }

    // ── Handshake messages ───────────────────────────────────────

    /** Initiator → responder. Pattern: e, es, s, ss + payload. */
    fun writeMessage1(payload: ByteArray = ByteArray(0)): ByteArray {
        if (role != Role.INITIATOR || msgIndex != 0) throw NoiseException("writeMessage1 out of order")
        val rs = peerStatic ?: throw NoiseException("Missing peer static key")

        val (ePriv, ePub) = generateEphemeral()
        ePrivate = ePriv
        ePublic = ePub
        mixHash(ePub)

        // es: DH(e, rs)
        mixKey(dh(ePriv, rs))

        val encryptedS = encryptAndHash(staticPublic)

        // ss: DH(s, rs)
        mixKey(dh(staticPrivate, rs))

        val encryptedPayload = encryptAndHash(payload)

        val out = ByteArrayOutputStream()
        out.write(ePub)
        out.write(encryptedS)
        out.write(encryptedPayload)
        msgIndex = 1
        return out.toByteArray()
    }

    fun readMessage1(message: ByteArray): ByteArray {
        if (role != Role.RESPONDER || msgIndex != 0) throw NoiseException("readMessage1 out of order")
        if (message.size < 32 + 32 + 16) throw NoiseException("message 1 truncated")

        val ePub = message.copyOfRange(0, 32)
        peerEphemeral = ePub
        mixHash(ePub)

        // es: DH(s, re)
        mixKey(dh(staticPrivate, ePub))

        val encS = message.copyOfRange(32, 32 + 48)
        val rs = decryptAndHash(encS)
        if (rs.size != 32) throw NoiseException("recovered static wrong length")
        peerStatic = rs

        // ss: DH(s, rs)
        mixKey(dh(staticPrivate, rs))

        val encPayload = message.copyOfRange(32 + 48, message.size)
        val payload = decryptAndHash(encPayload)
        msgIndex = 1
        return payload
    }

    /** Responder → initiator. Pattern: e, ee, se + payload. */
    fun writeMessage2(payload: ByteArray = ByteArray(0)): ByteArray {
        if (role != Role.RESPONDER || msgIndex != 1) throw NoiseException("writeMessage2 out of order")
        val re = peerEphemeral ?: throw NoiseException("Missing peer ephemeral")

        val (ePriv, ePub) = generateEphemeral()
        ePrivate = ePriv
        ePublic = ePub
        mixHash(ePub)

        mixKey(dh(ePriv, re))           // ee
        mixKey(dh(staticPrivate, re))   // se on responder side

        val encryptedPayload = encryptAndHash(payload)

        val out = ByteArrayOutputStream()
        out.write(ePub)
        out.write(encryptedPayload)
        msgIndex = 2
        return out.toByteArray()
    }

    fun readMessage2(message: ByteArray): ByteArray {
        if (role != Role.INITIATOR || msgIndex != 1) throw NoiseException("readMessage2 out of order")
        val e = ePrivate ?: throw NoiseException("Missing ephemeral private")
        val rs = peerStatic ?: throw NoiseException("Missing peer static")
        if (message.size < 32 + 16) throw NoiseException("message 2 truncated")

        val ePub = message.copyOfRange(0, 32)
        peerEphemeral = ePub
        mixHash(ePub)

        mixKey(dh(e, ePub))       // ee
        mixKey(dh(e, rs))         // se on initiator side

        val encPayload = message.copyOfRange(32, message.size)
        val payload = decryptAndHash(encPayload)
        msgIndex = 2
        return payload
    }

    // ── Split: derive transport-mode cipher pair ─────────────────

    /**
     * After both handshake messages have completed, derive the
     * transport-mode cipher states. Returns `(sending, receiving)`
     * keyed for THIS side — the initiator's `sending` matches the
     * responder's `receiving`, and vice versa.
     */
    fun split(): Pair<NoiseCipherState, NoiseCipherState> {
        if (msgIndex != 2) throw NoiseException("split called before handshake completed")
        // HKDF(ck, "", n=2)
        val prk = hmacSha256(ck, ByteArray(0))
        val t1 = hmacSha256(prk, byteArrayOf(0x01))
        val t2input = ByteArray(t1.size + 1).apply {
            t1.copyInto(this)
            this[t1.size] = 0x02
        }
        val t2 = hmacSha256(prk, t2input)

        return when (role) {
            Role.INITIATOR -> NoiseCipherState(t1) to NoiseCipherState(t2)
            Role.RESPONDER -> NoiseCipherState(t2) to NoiseCipherState(t1)
        }
    }
}

/**
 * Post-handshake AEAD state. Each direction (send / receive) gets one.
 * ChaCha20-Poly1305 with monotonically increasing nonces; reusing a
 * nonce is a security failure, so callers should treat the state as
 * non-thread-safe and not mutate from multiple threads concurrently.
 */
class NoiseCipherState(key: ByteArray) {
    private val key = key.copyOf()
    private var n: Long = 0

    init { require(key.size == 32) { "key must be 32 bytes" } }

    private fun currentNonce(): ByteArray {
        val nonce = ByteArray(12)
        ByteBuffer.wrap(nonce, 4, 8).order(ByteOrder.LITTLE_ENDIAN).putLong(n)
        return nonce
    }

    fun encryptWithAd(ad: ByteArray, plaintext: ByteArray): ByteArray {
        val aead = ChaCha20Poly1305()
        aead.init(true, AEADParameters(KeyParameter(key), 128, currentNonce(), ad))
        val out = ByteArray(aead.getOutputSize(plaintext.size))
        val len = aead.processBytes(plaintext, 0, plaintext.size, out, 0)
        aead.doFinal(out, len)
        n++
        return out
    }

    fun decryptWithAd(ad: ByteArray, ciphertext: ByteArray): ByteArray {
        if (ciphertext.size < 16) throw NoiseException("ciphertext too short for AEAD tag")
        val aead = ChaCha20Poly1305()
        aead.init(false, AEADParameters(KeyParameter(key), 128, currentNonce(), ad))
        val out = ByteArray(aead.getOutputSize(ciphertext.size))
        try {
            val len = aead.processBytes(ciphertext, 0, ciphertext.size, out, 0)
            val finalLen = aead.doFinal(out, len)
            n++
            return out.copyOf(len + finalLen)
        } catch (_: Exception) {
            throw NoiseException("AEAD verify failed")
        }
    }
}
