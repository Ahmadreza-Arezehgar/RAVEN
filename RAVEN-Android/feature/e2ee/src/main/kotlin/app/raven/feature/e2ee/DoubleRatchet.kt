package app.raven.feature.e2ee

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Symmetric ratchet primitives for Phase 2f's per-message forward
 * secrecy.
 *
 * Phase 2e gave us a per-peer X3DH root and derived each message
 * key directly from `(root, senderId, counter)`. That works, but
 * if the chain key ever leaks, ALL past messages decrypt — because
 * the root itself is a fixed long-lived secret and the per-counter
 * derivation is reversible-by-replay.
 *
 * Phase 2f introduces the symmetric chain ratchet (Signal Double
 * Ratchet's inner chain):
 *
 *   • Each direction (send / recv) maintains a 32-byte **chain key**
 *   • For each message:
 *       msg_key   = HMAC-SHA256(chain_key, 0x01)
 *       new_chain = HMAC-SHA256(chain_key, 0x02)
 *     The old `chain_key` is immediately discarded
 *   • The old `chain_key` is unrecoverable from `(msg_key, new_chain)`
 *     thanks to HMAC's one-way property — so a leak of the CURRENT
 *     chain key reveals nothing about PAST message keys
 *
 * What this DOES protect against:
 *   • A compromised chain key cannot decrypt messages sent before
 *     the compromise (forward secrecy)
 *   • Distinct counters use distinct keys, so nonce reuse is
 *     structurally impossible inside one chain
 *
 * What this does NOT yet protect against (Phase 2g):
 *   • A compromised root key still threatens future messages — there's
 *     no DH ratchet step on peer-key rotation yet. Phase 2g adds the
 *     outer DH ratchet that re-keys the root on every received message
 *     with a new sender DH pub
 *
 * The chain advancement KDF here is identical to Signal's spec
 * §5.2 (KDF_CK with constants 0x01/0x02), so a future DH-ratchet
 * upgrade only has to replace the [initialChainKeys] init path, not
 * the per-message advance.
 */
object DoubleRatchet {

    /** Magic byte input to KDF_CK to mint the per-message key. */
    private const val MSG_KEY_INPUT: Byte = 0x01
    /** Magic byte input to KDF_CK to mint the next chain key. */
    private const val CHAIN_KEY_INPUT: Byte = 0x02

    /** Result of one chain advance: the new chain key (to persist)
     *  and the per-message key (to encrypt/decrypt with, then drop). */
    data class ChainStep(val nextChainKey: ByteArray, val messageKey: ByteArray)

    /**
     * Advance a symmetric chain by one step.
     *
     * Caller MUST persist [ChainStep.nextChainKey] before using
     * [ChainStep.messageKey] — failing to update the chain on send
     * would re-use the same per-message key on retry, defeating
     * AES-GCM's nonce guarantee.
     */
    fun ratchetChain(chainKey: ByteArray): ChainStep {
        require(chainKey.size == 32) { "chain key must be 32 bytes" }
        val msgKey = hmacSha256(chainKey, byteArrayOf(MSG_KEY_INPUT))
        val nextChain = hmacSha256(chainKey, byteArrayOf(CHAIN_KEY_INPUT))
        return ChainStep(nextChainKey = nextChain, messageKey = msgKey)
    }

    /**
     * From an X3DH-derived root key, derive the initial pair of
     * direction-specific chain keys.
     *
     * Both sides compute both keys identically by sorting the user
     * IDs lexicographically before building the HKDF `info` label —
     * so "alice→bob" always means the same chain regardless of who
     * runs the function.
     *
     * Returns:
     *   • `chainFor(meUserId)` — my outbound chain start
     *   • `chainFor(peerUserId)` — peer's outbound chain start (my inbound)
     */
    fun initialChainKeys(rootKey: ByteArray, meUserId: String, peerUserId: String): Pair<ByteArray, ByteArray> {
        require(rootKey.size == 32) { "root key must be 32 bytes" }
        val (lo, hi) = if (meUserId < peerUserId) meUserId to peerUserId else peerUserId to meUserId
        val loChain = hkdf(rootKey, "raven-chain-v1|$lo→$hi", 32)
        val hiChain = hkdf(rootKey, "raven-chain-v1|$hi→$lo", 32)
        val myChain = if (meUserId == lo) loChain else hiChain
        val peerChain = if (peerUserId == lo) loChain else hiChain
        return myChain to peerChain
    }

    /**
     * Skip ahead in a chain to land on a target counter, returning
     * (new chain key, message key for target). Used on the receive
     * side when an out-of-order message arrives — the receiver
     * burns through intermediate keys (which it then DROPS, because
     * Phase 2f doesn't yet keep a skipped-keys store).
     *
     * Refuses to skip more than [MAX_SKIP] forward to bound CPU
     * burn from a malicious sender claiming `counter = 2^31`.
     */
    fun skipChainTo(
        chainKey: ByteArray,
        currentCount: Long,
        targetCount: Long,
    ): ChainStep? {
        if (targetCount < currentCount) return null
        val skip = targetCount - currentCount
        if (skip > MAX_SKIP) return null
        var ck = chainKey
        var msgKey: ByteArray = ByteArray(0)
        var nextCk: ByteArray = ck
        for (i in 0..skip) {
            val step = ratchetChain(ck)
            msgKey = step.messageKey
            nextCk = step.nextChainKey
            ck = step.nextChainKey
        }
        return ChainStep(nextChainKey = nextCk, messageKey = msgKey)
    }

    // ─── Crypto primitives ──────────────────────────────────────

    /** Single-block HKDF-SHA256 (RFC 5869) — salt = 32 zeros, info
     *  per-caller, output ≤32 bytes (we never need more for one
     *  chain-key derivation). */
    private fun hkdf(ikm: ByteArray, infoString: String, length: Int): ByteArray {
        require(length in 1..32) { "hkdf one-block only supports ≤32 bytes" }
        val salt = ByteArray(32)
        val prk = hmacSha256(salt, ikm)
        val info = infoString.toByteArray(Charsets.UTF_8)
        val input = ByteArray(info.size + 1).apply {
            info.copyInto(this)
            this[info.size] = 0x01
        }
        return hmacSha256(prk, input).copyOfRange(0, length)
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    /** Cap on consecutive skipped messages a receiver will burn
     *  through before giving up — prevents CPU-DoS from a sender
     *  jumping the counter to MAX_LONG. Signal's spec calls this
     *  `MAX_SKIP` and uses ~1000; we follow. */
    const val MAX_SKIP: Long = 1000
}
