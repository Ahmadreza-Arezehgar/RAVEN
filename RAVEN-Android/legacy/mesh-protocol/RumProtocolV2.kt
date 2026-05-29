// RumProtocolV2.kt
//
// RAVEN Universal Mesh — protocol v2 (Android).
//
// BYTE-IDENTICAL sibling of:
//   • ios-native/RAVEN/RAVEN/Core/Mesh/RUMProtocolV2.swift (canonical)
//   • RAVEN-MacApp/RAVEN/Core/Mesh/RUMProtocolV2.swift
//   • RAVEN-Windows/src/Mesh/RumProtocolV2.cs
//
// This file is the seed of the Android port. The rest of RAVEN-Android/
// will be built around it once the Kotlin module structure is set up
// (Gradle, Compose UI, Room DB, Bluetooth GATT server). See
// `docs/MESH_PROTOCOL.md §V2` for the protocol spec — the test vectors
// at the end are required round-trip cases for compatibility CI.

package app.raven.mesh

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.UUID

object RumProtocolV2 {

    // ── Wire constants ────────────────────────────────────────────────

    /** Version byte stamped into every v2 envelope. */
    const val VERSION: Byte = 0x02

    /** Service UUID for v2 GATT advertising. */
    val SERVICE_UUID: UUID = UUID.fromString("12345678-2345-2345-2345-123456789ABC")

    /** Message TX/RX characteristic. */
    val MESSAGE_CHARACTERISTIC_UUID: UUID = UUID.fromString("12345678-2345-2345-2345-123456789ABD")

    /** Capabilities characteristic — read-only big-endian uint32. */
    val CAPABILITIES_CHARACTERISTIC_UUID: UUID = UUID.fromString("12345678-2345-2345-2345-123456789ABE")

    // ── Envelope layout ───────────────────────────────────────────────
    //
    //   0 ..  1  version          uint8 (always 0x02)
    //   1 ..  2  type             uint8 — see MessageType
    //   2 ..  3  ttl              uint8 (0–MAX_TTL; relays decrement)
    //   3 ..  4  flags            uint8 — see Flags
    //   4 ..  8  timestamp        uint32 BE — unix seconds
    //   8 .. 24  msg_id           16 bytes — UUID v4 binary
    //  24 .. 40  sender_pid       16 bytes — SHA-256(sender_pubkey)[:16]
    //  40 .. 56  dest_pid         16 bytes — SHA-256(dest_pubkey)[:16]
    //                              or BROADCAST_PEER_ID
    //  56 .. 57  hop_count        uint8 — relays increment
    //  57 .. 58  spray_remaining  uint8 — Spray-and-Wait copy budget
    //  58 .. 60  payload_len      uint16 BE
    //  60 ..  N  payload          payload_len bytes
    //  N .. N+64 signature        Ed25519 (only if Flags.SIGNATURE_PRESENT)
    //  N+64 .. M  pq_signature    ML-DSA-65 (3293 B, only if Flags.PQ_HYBRID_SIG
    //                              — reserved for C.4, not emitted today)

    const val HEADER_SIZE = 60
    const val SIGNATURE_SIZE = 64

    /**
     * ML-DSA-65 signature size (FIPS 204 final). Reserved alongside
     * [Flags.PQ_HYBRID_SIG]; receivers only consume these bytes when the
     * flag is set, so existing readers ignore them and stay compatible.
     */
    const val PQ_SIGNATURE_SIZE = 3_293

    const val MAX_PAYLOAD_SIZE = 32_768
    val PADDING_TARGETS = intArrayOf(256, 512, 1024, 2048, 4096, 8192)

    // ── Type discriminator ────────────────────────────────────────────

    enum class MessageType(val raw: Byte) {
        TEXT(0),
        IMAGE(1),
        VOICE(2),
        FILE(3),
        LOCATION(4),
        SYSTEM(5),
        ACK(6),
        STOP(7),
        POST_SHARE(8),
        EPHEMERAL(9),

        /**
         * Noise IK handshake message 1 — initiator's ephemeral,
         * encrypted static, plus an optional payload (typically the
         * chat text for 1-RTT delivery). Receiver routes the bytes to
         * its `NoiseSessionStore.processInboundHandshake1` equivalent.
         */
        NOISE_HANDSHAKE_1(10),

        /**
         * Noise IK handshake message 2 — responder's ephemeral and an
         * optional reply payload. Receiver routes the bytes to
         * `NoiseSessionStore.finishHandshakeAsInitiator`.
         */
        NOISE_HANDSHAKE_2(11),

        // ── Post-quantum hybrid (C.4) — reserved, gated on `PQ_ENABLED` ──
        //
        // Hybrid IK pattern: classical X25519 chaining mixed with
        // ML-KEM-768 KEM output. An attacker has to break BOTH lattice and
        // DH to read anything. The constants are reserved here today
        // (May 2026) so the four code-base copies of this enum stay
        // aligned even though we don't emit these message types until
        // Android API 35's `java.security` JCA exposes ML-KEM-768. See
        // `docs/RUM_V2_ROADMAP.md` §C.4.

        /**
         * Hybrid handshake message 1 — initiator side.
         * Payload layout: `[X25519 ephemeral pubkey | ML-KEM-768 encaps
         * pubkey | legacy IK message-1 body]`.
         */
        PQ_NOISE_HANDSHAKE_1(12),

        /**
         * Hybrid handshake message 2 — responder side.
         * Payload layout: `[X25519 ephemeral pubkey | ML-KEM-768 ciphertext
         * against initiator's ephemeral PQ pubkey | legacy IK message-2
         * body]`.
         */
        PQ_NOISE_HANDSHAKE_2(13),

        // ── Mesh security hardening (Phase E) — reserved, off-by-default ─
        //
        // See `docs/RUM_V2_ROADMAP.md` §E for the threat model + per-phase
        // design. These constants are reserved here today (May 2026) so
        // the four code-base copies of this enum stay aligned even though
        // we don't emit these types until the matching feature flag in
        // SecurityConstants is flipped on per-phase.

        /**
         * Decoy envelope emitted on idle (Phase E.1). Receivers AEAD-verify
         * then drop silently. The payload is random bytes inside a real
         * Noise IK ciphertext so passive observers can't distinguish it
         * from a real frame by size, flag pattern, or signature shape.
         */
        COVER(14),

        /**
         * Announces a peer-ID rotation event (Phase E.4) so peers can
         * re-derive the expected pseudonym map without waiting for the
         * next real message. Encrypted inside the Noise transport AEAD.
         */
        PEER_ID_ROTATE(15);

        companion object {
            fun fromRaw(b: Byte): MessageType? = values().firstOrNull { it.raw == b }
        }
    }

    // ── Flag bits ─────────────────────────────────────────────────────

    object Flags {
        const val NONE: Byte               = 0
        const val ENCRYPTED: Byte          = 1
        const val BRIDGED: Byte            = 1 shl 1
        const val GROUP: Byte              = 1 shl 2
        const val ACK_REQUIRED: Byte       = 1 shl 3
        const val NEEDS_FORWARDING: Byte   = 1 shl 4
        const val SIGNATURE_PRESENT: Byte  = 1 shl 5

        /**
         * Payload is encrypted with a Noise IK transport-mode cipher
         * (`NoiseSessionStore.encrypt`) instead of the v1
         * AES-GCM-with-static-ECDH path that [ENCRYPTED] signals.
         * Receivers route the payload to `NoiseSessionStore.decrypt`.
         */
        const val NOISE_TRANSPORT: Byte    = 1 shl 6

        /**
         * Envelope trailer carries an ML-DSA-65 signature in addition to
         * the Ed25519 sig signalled by [SIGNATURE_PRESENT]. Verifiers
         * MUST require both to validate — falling back to "either one"
         * defeats the hybrid guarantee. Reserved for C.4; senders don't
         * set this until [PQ_ENABLED] flips on.
         */
        const val PQ_HYBRID_SIG: Byte      = 1 shl 7

        private infix fun Byte.shl(n: Int): Byte = (this.toInt() shl n).toByte()

        fun has(flags: Byte, bit: Byte): Boolean = (flags.toInt() and bit.toInt()) != 0
    }

    // ── Capabilities ──────────────────────────────────────────────────

    object Capabilities {
        const val V2_PROTOCOL: UInt    = 1u shl 0
        const val BLE_TRANSPORT: UInt  = 1u shl 1
        const val WIFI_AWARE: UInt     = 1u shl 2
        const val MULTIPEER: UInt      = 1u shl 3
        const val WIFI_DIRECT: UInt    = 1u shl 4
        const val SERVER_BRIDGE: UInt  = 1u shl 5
        const val CAN_BE_BRIDGE: UInt  = 1u shl 6

        /**
         * Peer can run the hybrid X25519 + ML-KEM-768 IK handshake.
         * Negotiation rule: prefer hybrid iff BOTH sides advertise this.
         * Reserved for C.4 — senders only assert when [PQ_ENABLED] is true.
         */
        const val PQ_HYBRID_KEM: UInt  = 1u shl 7

        /**
         * Peer can verify + emit [Flags.PQ_HYBRID_SIG] (ML-DSA-65 trailer
         * signature). Independent of [PQ_HYBRID_KEM] — a platform might
         * land sig support first (smaller, no handshake-size penalty).
         */
        const val PQ_HYBRID_SIG: UInt  = 1u shl 8

        // ── Phase E — Mesh security hardening ─────────────────────────
        //
        // See `docs/RUM_V2_ROADMAP.md` §E. Each bit advertises that this
        // peer supports a specific hardening sub-phase. Engines must
        // NEVER assert a bit whose feature flag in SecurityConstants is
        // off — that'd cause peers to expect behaviour we don't actually
        // deliver.

        /**
         * Peer emits cover-traffic frames ([MessageType.COVER]) during
         * idle periods (Phase E.1). Informational — receivers always
         * accept cover frames regardless of this bit.
         */
        const val COVER_TRAFFIC: UInt     = 1u shl 9

        /**
         * Peer can produce + verify the hop-by-hop HMAC chain trailer
         * (Phase E.2). Requires v3 envelope. Two peers both with this
         * bit negotiate envelope v3; otherwise stay on v2.
         */
        const val HOP_AUTH: UInt          = 1u shl 10

        /**
         * Peer binds + checks a monotonic message counter inside the
         * Noise transport AEAD's associated data (Phase E.3). Receivers
         * drop messages whose counter doesn't strictly increase per
         * session.
         */
        const val MONOTONIC_COUNTER: UInt = 1u shl 11

        /**
         * Peer derives + recognises rotating pseudonymous peer IDs
         * (Phase E.4). Requires v3 envelope. Two peers both with this
         * bit negotiate v3 + rotating IDs; otherwise the connection
         * falls back to stable IDs and accepts the metadata leak.
         */
        const val ROTATING_PEER_ID: UInt  = 1u shl 12
    }

    // ── Routing constants ─────────────────────────────────────────────

    const val DEFAULT_SPRAY_COPIES: Byte = 4
    const val DEFAULT_TTL: Byte = 7
    const val MAX_TTL: Byte = 15

    /**
     * Master switch for post-quantum hybrid mode (C.4).
     *
     * When `false` (today, May 2026): the protocol module reserves bits +
     * message types but no client emits `PQ_HYBRID_*` capabilities or PQ
     * handshake frames. Engines must NEVER advertise the PQ caps with
     * this flag off — that'd cause peers to try a hybrid handshake we
     * can't complete.
     *
     * Flip to `true` once `PqNoiseSession.isAvailable` is true on enough
     * platforms (Apple's CryptoKit ML-KEM ship, Android API 35 rollout,
     * .NET 10 release).
     */
    const val PQ_ENABLED: Boolean = false

    // ── Peer ID helpers ───────────────────────────────────────────────

    /**
     * Derive the 16-byte stable peer ID from a Curve25519 static public
     * key. SAME derivation as iOS/Mac/Windows — verify against the test
     * vector in docs/MESH_PROTOCOL.md.
     */
    fun peerIdFromPublicKey(publicKey: ByteArray): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        val full = md.digest(publicKey)
        return full.copyOfRange(0, 16)
    }

    /** All-0xFF peer ID = "broadcast to everyone in mesh". */
    val BROADCAST_PEER_ID: ByteArray = ByteArray(16) { 0xFF.toByte() }

    // ── Envelope ──────────────────────────────────────────────────────

    data class Envelope(
        val type: MessageType,
        val ttl: Byte,
        val flags: Byte,
        val timestamp: UInt,
        val msgId: ByteArray,
        val senderPid: ByteArray,
        val destPid: ByteArray,
        val hopCount: Byte,
        val sprayRemaining: Byte,
        val payload: ByteArray,
        val signature: ByteArray? = null,
    ) {
        // Equals + hashCode account for ByteArray identity → value equality.
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is Envelope) return false
            return type == other.type &&
                ttl == other.ttl &&
                flags == other.flags &&
                timestamp == other.timestamp &&
                msgId.contentEquals(other.msgId) &&
                senderPid.contentEquals(other.senderPid) &&
                destPid.contentEquals(other.destPid) &&
                hopCount == other.hopCount &&
                sprayRemaining == other.sprayRemaining &&
                payload.contentEquals(other.payload) &&
                ((signature == null && other.signature == null) ||
                    (signature != null && other.signature != null &&
                        signature.contentEquals(other.signature)))
        }

        override fun hashCode(): Int {
            var r = type.hashCode()
            r = 31 * r + ttl
            r = 31 * r + flags
            r = 31 * r + timestamp.hashCode()
            r = 31 * r + msgId.contentHashCode()
            r = 31 * r + senderPid.contentHashCode()
            r = 31 * r + destPid.contentHashCode()
            r = 31 * r + hopCount
            r = 31 * r + sprayRemaining
            r = 31 * r + payload.contentHashCode()
            r = 31 * r + (signature?.contentHashCode() ?: 0)
            return r
        }
    }

    // ── Errors ────────────────────────────────────────────────────────

    class CodecException(message: String) : Exception(message)

    // ── Encode ────────────────────────────────────────────────────────

    /**
     * Serialize an envelope to its wire form. Throws [CodecException] if
     * any 16-byte ID is the wrong length or the payload exceeds
     * [MAX_PAYLOAD_SIZE].
     */
    fun encode(envelope: Envelope): ByteArray {
        if (envelope.msgId.size != 16 || envelope.senderPid.size != 16 || envelope.destPid.size != 16) {
            throw CodecException("envelope IDs must each be 16 bytes")
        }
        if (envelope.payload.size > MAX_PAYLOAD_SIZE) {
            throw CodecException("payload too large (${envelope.payload.size} > $MAX_PAYLOAD_SIZE)")
        }
        val sigPresent = Flags.has(envelope.flags, Flags.SIGNATURE_PRESENT)
        if (sigPresent && (envelope.signature == null || envelope.signature.size != SIGNATURE_SIZE)) {
            throw CodecException("SIGNATURE_PRESENT flag set but signature missing or wrong length")
        }

        val sigLen = if (sigPresent) SIGNATURE_SIZE else 0
        val out = ByteArray(HEADER_SIZE + envelope.payload.size + sigLen)
        val buf = ByteBuffer.wrap(out).order(ByteOrder.BIG_ENDIAN)

        buf.put(VERSION)
        buf.put(envelope.type.raw)
        buf.put(envelope.ttl)
        buf.put(envelope.flags)

        buf.putInt(envelope.timestamp.toInt())  // toInt() preserves bit pattern for unsigned BE write

        buf.put(envelope.msgId)
        buf.put(envelope.senderPid)
        buf.put(envelope.destPid)

        buf.put(envelope.hopCount)
        buf.put(envelope.sprayRemaining)

        buf.putShort(envelope.payload.size.toShort())

        buf.put(envelope.payload)

        if (sigPresent && envelope.signature != null) {
            buf.put(envelope.signature)
        }

        return out
    }

    // ── Decode ────────────────────────────────────────────────────────

    /**
     * Parse the wire form back into an [Envelope]. Throws on truncated,
     * version-mismatched, or otherwise malformed input. Trailing padding
     * bytes (added by [pad]) are ignored — payload_len defines the real
     * boundary.
     */
    fun decode(bytes: ByteArray): Envelope {
        if (bytes.size < HEADER_SIZE) {
            throw CodecException("envelope truncated (less than header size)")
        }
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)

        val v = buf.get()
        if (v != VERSION) {
            throw CodecException("version mismatch — expected 0x%02X, got 0x%02X".format(VERSION, v))
        }

        val typeRaw = buf.get()
        val type = MessageType.fromRaw(typeRaw)
            ?: throw CodecException("unknown message type 0x%02X".format(typeRaw))
        val ttl = buf.get()
        val flags = buf.get()

        val timestamp = buf.int.toUInt()

        val msgId = ByteArray(16); buf.get(msgId)
        val senderId = ByteArray(16); buf.get(senderId)
        val destId = ByteArray(16); buf.get(destId)

        val hopCount = buf.get()
        val sprayRem = buf.get()

        val payloadLen = buf.short.toInt() and 0xFFFF
        val payloadEnd = HEADER_SIZE + payloadLen
        if (bytes.size < payloadEnd) {
            throw CodecException("envelope truncated (payload)")
        }
        val payload = ByteArray(payloadLen); buf.get(payload)

        var signature: ByteArray? = null
        if (Flags.has(flags, Flags.SIGNATURE_PRESENT)) {
            val sigEnd = payloadEnd + SIGNATURE_SIZE
            if (bytes.size < sigEnd) {
                throw CodecException("envelope truncated (signature)")
            }
            signature = ByteArray(SIGNATURE_SIZE); buf.get(signature)
        }

        return Envelope(
            type = type, ttl = ttl, flags = flags, timestamp = timestamp,
            msgId = msgId, senderPid = senderId, destPid = destId,
            hopCount = hopCount, sprayRemaining = sprayRem,
            payload = payload, signature = signature
        )
    }

    // ── Padding ───────────────────────────────────────────────────────

    /**
     * Pad an encoded envelope to the next [PADDING_TARGETS] size.
     * Defeats passive traffic analysis. Receivers strip via payload_len
     * in the header.
     */
    fun pad(encoded: ByteArray): ByteArray {
        val target = PADDING_TARGETS.firstOrNull { it >= encoded.size } ?: encoded.size
        if (target == encoded.size) return encoded
        val padded = ByteArray(target)
        System.arraycopy(encoded, 0, padded, 0, encoded.size)
        return padded
    }
}
