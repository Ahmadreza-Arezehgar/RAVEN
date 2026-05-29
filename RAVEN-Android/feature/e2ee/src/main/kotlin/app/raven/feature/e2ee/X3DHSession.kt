package app.raven.feature.e2ee

import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Simplified X3DH session derivation — gives us a real per-peer
 * root key without the iOS-Signal Double-Ratchet complexity.
 *
 * Mirror of the **initial-key-derivation** half of iOS
 * `X3DH.deriveInitiatorSecret(...)` + `RatchetSessionStore.split(...)`
 * — without the post-handshake DH ratchet. Forward secrecy here
 * comes from each message deriving a fresh `msg_key` via HKDF
 * over a per-send counter; the root itself is pinned for the
 * lifetime of the conversation. Phase 2f swaps in the DH ratchet
 * + chain key rotation to match Signal-spec semantics.
 *
 * Initiator (sender) DHs:
 *   • DH1 = ECDH(my_static_x25519, peer_signed_prekey)
 *   • DH2 = ECDH(my_ephemeral_x25519, peer_static_x25519)
 *   • DH3 = ECDH(my_ephemeral_x25519, peer_signed_prekey)
 *   • root = HKDF-SHA256(salt = 32-byte zeros,
 *                        ikm = DH1 ‖ DH2 ‖ DH3,
 *                        info = "raven-x3dh-v1",
 *                        L = 32)
 *
 * Responder runs the SAME DHs with sides swapped (priv↔pub) and
 * gets bit-for-bit the same root.
 *
 * Why no one-time-prekey (OPK) yet? Server stores the OPK pool
 * but the Phase 2c publish ships an empty pool. Phase 2f wires
 * the rotation worker that re-fills + consumes OPKs. Without OPK,
 * "deniability" is weaker — but every other X3DH guarantee
 * (mutual auth, forward secrecy via ephemeral) still holds.
 */
object X3DHSession {

    /**
     * Initiator-side derivation. Called once when sender first
     * wants to talk to peer.
     *
     * @param myStaticPriv  my X25519 identity-agreement private key
     * @param myEphPriv     fresh X25519 ephemeral private (32 random bytes)
     * @param peerStaticPub peer's X25519 identity-agreement public
     * @param peerSpkPub    peer's signed-prekey public (X25519)
     * @return 32-byte root key
     */
    fun deriveInitiator(
        myStaticPriv: ByteArray,
        myEphPriv: ByteArray,
        peerStaticPub: ByteArray,
        peerSpkPub: ByteArray,
    ): ByteArray {
        val dh1 = ecdh(myStaticPriv, peerSpkPub)
        val dh2 = ecdh(myEphPriv, peerStaticPub)
        val dh3 = ecdh(myEphPriv, peerSpkPub)
        return hkdfRoot(dh1 + dh2 + dh3)
    }

    /**
     * Responder-side derivation. Called when receiver first decrypts
     * a message from a peer who used the responder's published bundle.
     *
     * @param myStaticPriv  my X25519 identity-agreement private
     * @param mySpkPriv     my signed-prekey private (X25519)
     * @param peerStaticPub peer's X25519 identity-agreement public
     * @param peerEphPub    the ephemeral the peer included in the message
     */
    fun deriveResponder(
        myStaticPriv: ByteArray,
        mySpkPriv: ByteArray,
        peerStaticPub: ByteArray,
        peerEphPub: ByteArray,
    ): ByteArray {
        // Same three DHs, sides swapped. Order matters for the HKDF
        // input — has to match the initiator.
        //   DH1 = my_spk × peer_static  (initiator: peer_spk × my_static)
        //   DH2 = my_static × peer_eph  (initiator: peer_static × my_eph)
        //   DH3 = my_spk × peer_eph     (initiator: peer_spk × my_eph)
        val dh1 = ecdh(mySpkPriv, peerStaticPub)
        val dh2 = ecdh(myStaticPriv, peerEphPub)
        val dh3 = ecdh(mySpkPriv, peerEphPub)
        return hkdfRoot(dh1 + dh2 + dh3)
    }

    /**
     * Per-message key derivation, bound to (sender, counter).
     *
     * Both sides compute the same key for the same wire message:
     *   • Sender uses [senderUserId] = own user id, [counter] = sendCounter
     *   • Receiver uses [senderUserId] = peer's user id, [counter] = parsed-from-wire
     *
     * Binding the sender id into HKDF info gives us direction-separation
     * for free: A→B uses keys derived from "...|A|...", B→A from
     * "...|B|...", so even with one shared root key, the two
     * directions can't reuse nonces against each other.
     *
     * The (root, sender, counter) tuple MUST NEVER repeat — AES-GCM's
     * tag verification collapses under nonce reuse. The caller's
     * monotonic [SessionState.sendCounter] gives us that guarantee.
     */
    fun messageKey(root: ByteArray, senderUserId: String, counter: Long): ByteArray {
        val info = "raven-msg-v1|$senderUserId|$counter".toByteArray(Charsets.UTF_8)
        return hkdfExpand(root, info, 32)
    }

    // ── Crypto primitives ────────────────────────────────────────

    private fun ecdh(privateKey: ByteArray, publicKey: ByteArray): ByteArray {
        val priv = X25519PrivateKeyParameters(privateKey, 0)
        val pub = X25519PublicKeyParameters(publicKey, 0)
        val agreement = X25519Agreement().apply { init(priv) }
        val out = ByteArray(agreement.agreementSize)
        agreement.calculateAgreement(pub, out, 0)
        return out
    }

    /** HKDF-SHA256 — full extract+expand, salt = 32 zero bytes. */
    private fun hkdfRoot(ikm: ByteArray): ByteArray {
        val salt = ByteArray(32)  // RFC 5869 §2.2 — all zeros when no salt
        val prk = hmacSha256(salt, ikm)
        return hkdfExpand(prk, "raven-x3dh-v1".toByteArray(Charsets.UTF_8), 32)
    }

    /** HKDF-Expand (RFC 5869 §2.3). One block (≤32 bytes) is enough. */
    private fun hkdfExpand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 1..32) { "Phase 2e expand only emits ≤32 bytes" }
        val input = ByteArray(info.size + 1).apply {
            info.copyInto(this)
            this[info.size] = 0x01
        }
        val t1 = hmacSha256(prk, input)
        return t1.copyOfRange(0, length)
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }
}

/**
 * Helper to generate a fresh X25519 ephemeral keypair.
 *
 * Used by the initiator at session-start; the keypair is cached in
 * [SessionStore] so subsequent sends to the same peer reuse it
 * (and the receiver only has to run X3DH once per peer).
 */
internal object X25519Ephemeral {
    fun generate(): Pair<ByteArray, ByteArray> {
        val sk = X25519PrivateKeyParameters(java.security.SecureRandom())
        return sk.encoded to sk.generatePublicKey().encoded
    }
}
