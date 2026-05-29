// RumProtocolV2.cs
//
// RAVEN Universal Mesh — protocol v2 (Windows native).
//
// BYTE-IDENTICAL sibling of:
//   • ios-native/RAVEN/RAVEN/Core/Mesh/RUMProtocolV2.swift (canonical)
//   • RAVEN-MacApp/RAVEN/Core/Mesh/RUMProtocolV2.swift
//   • RAVEN-Android/RumProtocolV2.kt
//
// Any change here MUST land in all four siblings together. See
// `docs/MESH_PROTOCOL.md §V2` for the protocol spec and the test
// vectors all four platforms must round-trip.

using System;
using System.Buffers.Binary;
using System.Security.Cryptography;

namespace RAVEN.Windows.Mesh;

public static class RumProtocolV2
{
    // ── Wire constants ────────────────────────────────────────────────

    /// <summary>Version byte stamped into every v2 envelope.</summary>
    public const byte Version = 0x02;

    /// <summary>Service UUID for v2 GATT advertising.</summary>
    public static readonly Guid ServiceUuid =
        new("12345678-2345-2345-2345-123456789ABC");

    /// <summary>Message TX/RX characteristic.</summary>
    public static readonly Guid MessageCharacteristicUuid =
        new("12345678-2345-2345-2345-123456789ABD");

    /// <summary>Capabilities characteristic — read-only big-endian uint32.</summary>
    public static readonly Guid CapabilitiesCharacteristicUuid =
        new("12345678-2345-2345-2345-123456789ABE");

    // ── Envelope layout ───────────────────────────────────────────────
    //
    //   0 ..  1  version          uint8 (always 0x02)
    //   1 ..  2  type             uint8 — see MessageType
    //   2 ..  3  ttl              uint8 (0–MaxTtl; relays decrement)
    //   3 ..  4  flags            uint8 — see Flags
    //   4 ..  8  timestamp        uint32 BE — unix seconds
    //   8 .. 24  msg_id           16 bytes — UUID v4 binary
    //  24 .. 40  sender_pid       16 bytes — SHA-256(sender_pubkey)[:16]
    //  40 .. 56  dest_pid         16 bytes — SHA-256(dest_pubkey)[:16]
    //                              or `BroadcastPeerId`
    //  56 .. 57  hop_count        uint8 — relays increment
    //  57 .. 58  spray_remaining  uint8 — Spray-and-Wait copy budget
    //  58 .. 60  payload_len      uint16 BE
    //  60 ..  N  payload          payload_len bytes
    //  N .. N+64 signature        Ed25519 (only if Flags.SignaturePresent)
    //  N+64 .. M  pq_signature    ML-DSA-65 (3293 B, only if Flags.PqHybridSig
    //                              — reserved for C.4, not emitted today)

    public const int HeaderSize = 60;
    public const int SignatureSize = 64;
    /// <summary>
    /// ML-DSA-65 signature size (FIPS 204 final). Reserved alongside
    /// <see cref="Flags.PqHybridSig"/>; receivers only consume these
    /// bytes when the flag is set, so existing readers ignore them
    /// and stay compatible.
    /// </summary>
    public const int PqSignatureSize = 3_293;
    public const int MaxPayloadSize = 32_768;
    public static readonly int[] PaddingTargets = { 256, 512, 1024, 2048, 4096, 8192 };

    // ── Type discriminator ────────────────────────────────────────────

    public enum MessageType : byte
    {
        Text       = 0,
        Image      = 1,
        Voice      = 2,
        File       = 3,
        Location   = 4,
        System     = 5,
        Ack        = 6,
        Stop       = 7,
        PostShare  = 8,
        Ephemeral  = 9,

        /// <summary>
        /// Noise IK handshake message 1 — initiator's ephemeral, encrypted
        /// static, plus an optional payload (typically the chat text for
        /// 1-RTT delivery). Receiver routes the bytes to its
        /// `NoiseSessionStore.processInboundHandshake1` equivalent.
        /// </summary>
        NoiseHandshake1 = 10,

        /// <summary>
        /// Noise IK handshake message 2 — responder's ephemeral and an
        /// optional reply payload. Receiver routes the bytes to
        /// `NoiseSessionStore.finishHandshakeAsInitiator`.
        /// </summary>
        NoiseHandshake2 = 11,

        // ── Post-quantum hybrid (C.4) — reserved, gated on `PqEnabled` ──
        //
        // Hybrid IK pattern: classical X25519 chaining mixed with ML-KEM-768
        // KEM output. An attacker has to break BOTH lattice and DH to read
        // anything. The constants are reserved here today (May 2026) so the
        // four code-base copies of this enum stay aligned even though we
        // don't emit these message types until .NET 10 ships System.Security
        // .Cryptography.MLKem768. See `docs/RUM_V2_ROADMAP.md` §C.4.

        /// <summary>
        /// Hybrid handshake message 1 — initiator side.
        /// Payload layout: `[X25519 ephemeral pubkey | ML-KEM-768 encaps
        /// pubkey | legacy IK message-1 body]`.
        /// </summary>
        PqNoiseHandshake1 = 12,

        /// <summary>
        /// Hybrid handshake message 2 — responder side.
        /// Payload layout: `[X25519 ephemeral pubkey | ML-KEM-768 ciphertext
        /// against initiator's ephemeral PQ pubkey | legacy IK message-2
        /// body]`.
        /// </summary>
        PqNoiseHandshake2 = 13,

        // ── Mesh security hardening (Phase E) — reserved, off-by-default ──
        //
        // See `docs/RUM_V2_ROADMAP.md` §E for the threat model + per-phase
        // design. These constants are reserved here today (May 2026) so the
        // four code-base copies of this enum stay aligned even though we
        // don't emit these types until the matching feature flag in
        // SecurityConstants is flipped on per-phase.

        /// <summary>
        /// Decoy envelope emitted on idle (Phase E.1). Receivers AEAD-verify
        /// then drop silently. The payload is random bytes inside a real
        /// Noise IK ciphertext so passive observers can't distinguish it
        /// from a real frame by size, flag pattern, or signature shape.
        /// </summary>
        Cover = 14,

        /// <summary>
        /// Announces a peer-ID rotation event (Phase E.4) so peers can
        /// re-derive the expected pseudonym map without waiting for the
        /// next real message. Encrypted inside the Noise transport AEAD.
        /// </summary>
        PeerIdRotate = 15,
    }

    // ── Flag bits ─────────────────────────────────────────────────────

    [Flags]
    public enum Flags : byte
    {
        None              = 0,
        Encrypted         = 1 << 0,
        Bridged           = 1 << 1,
        Group             = 1 << 2,
        AckRequired       = 1 << 3,
        NeedsForwarding   = 1 << 4,
        SignaturePresent  = 1 << 5,

        /// <summary>
        /// Payload is encrypted with a Noise IK transport-mode cipher
        /// (`NoiseSessionStore.encrypt`) instead of the v1
        /// AES-GCM-with-static-ECDH path that <see cref="Encrypted"/>
        /// signals. Receivers route the payload to
        /// `NoiseSessionStore.decrypt`.
        /// </summary>
        NoiseTransport    = 1 << 6,

        /// <summary>
        /// Envelope trailer carries an ML-DSA-65 signature in addition
        /// to the Ed25519 sig signalled by <see cref="SignaturePresent"/>.
        /// Verifiers MUST require both to validate — falling back to
        /// "either one" defeats the hybrid guarantee. Reserved for C.4.
        /// </summary>
        PqHybridSig       = 1 << 7,
    }

    // ── Capabilities ──────────────────────────────────────────────────

    [Flags]
    public enum Capabilities : uint
    {
        None          = 0,
        V2Protocol    = 1u << 0,
        BleTransport  = 1u << 1,
        WifiAware     = 1u << 2,
        Multipeer     = 1u << 3,
        WifiDirect    = 1u << 4,
        ServerBridge  = 1u << 5,
        CanBeBridge   = 1u << 6,

        /// <summary>
        /// Peer can run the hybrid X25519 + ML-KEM-768 IK handshake.
        /// Negotiation rule: prefer hybrid iff BOTH sides advertise this.
        /// Reserved for C.4 — senders only assert when <see cref="PqEnabled"/>.
        /// </summary>
        PqHybridKEM   = 1u << 7,

        /// <summary>
        /// Peer can verify + emit <see cref="Flags.PqHybridSig"/>
        /// (ML-DSA-65 trailer signature). Independent of
        /// <see cref="PqHybridKEM"/> — a platform might land sig support
        /// first (smaller, no handshake-size penalty).
        /// </summary>
        PqHybridSig   = 1u << 8,

        // ── Phase E — Mesh security hardening ─────────────────────────
        //
        // See `docs/RUM_V2_ROADMAP.md` §E. Each bit advertises that this
        // peer supports a specific hardening sub-phase. Engines must NEVER
        // assert a bit whose feature flag in SecurityConstants is off —
        // that'd cause peers to expect behaviour we don't actually deliver.

        /// <summary>
        /// Peer emits cover-traffic frames (<see cref="MessageType.Cover"/>)
        /// during idle periods (Phase E.1). Informational — receivers
        /// always accept cover frames regardless of this bit.
        /// </summary>
        CoverTraffic    = 1u << 9,

        /// <summary>
        /// Peer can produce + verify the hop-by-hop HMAC chain trailer
        /// (Phase E.2). Requires v3 envelope. Two peers both with this
        /// bit negotiate envelope v3; otherwise stay on v2.
        /// </summary>
        HopAuth         = 1u << 10,

        /// <summary>
        /// Peer binds + checks a monotonic message counter inside the
        /// Noise transport AEAD's associated data (Phase E.3). Receivers
        /// drop messages whose counter doesn't strictly increase per
        /// session.
        /// </summary>
        MonotonicCounter = 1u << 11,

        /// <summary>
        /// Peer derives + recognises rotating pseudonymous peer IDs
        /// (Phase E.4). Requires v3 envelope. Two peers both with this
        /// bit negotiate v3 + rotating IDs; otherwise the connection
        /// falls back to stable IDs and accepts the metadata leak.
        /// </summary>
        RotatingPeerId  = 1u << 12,
    }

    // ── Routing constants ─────────────────────────────────────────────

    public const byte DefaultSprayCopies = 4;
    public const byte DefaultTtl = 7;
    public const byte MaxTtl = 15;

    /// <summary>
    /// Master switch for post-quantum hybrid mode (C.4).
    ///
    /// When <c>false</c> (today, May 2026): the protocol module reserves
    /// bits + message types but no client emits <c>PqHybrid*</c>
    /// capabilities or PQ handshake frames. Engines must NEVER advertise
    /// the PQ caps with this flag off — that'd cause peers to try a
    /// hybrid handshake we can't complete.
    ///
    /// Flip to <c>true</c> once <c>PqNoiseSession.IsAvailable</c> is true
    /// on enough platforms (Apple's CryptoKit ML-KEM ship, Android API 35
    /// rollout, .NET 10 release).
    /// </summary>
    public const bool PqEnabled = false;

    // ── Peer ID helpers ───────────────────────────────────────────────

    /// <summary>
    /// Derive the 16-byte stable peer ID from a Curve25519 static public
    /// key. SAME derivation as iOS/Mac/Android — verify against the test
    /// vector in docs/MESH_PROTOCOL.md.
    /// </summary>
    public static byte[] PeerIdFromPublicKey(ReadOnlySpan<byte> publicKey)
    {
        Span<byte> hash = stackalloc byte[32];
        SHA256.HashData(publicKey, hash);
        return hash[..16].ToArray();
    }

    /// <summary>All-0xFF peer ID = "broadcast to everyone in mesh".</summary>
    public static readonly byte[] BroadcastPeerId = Enumerable.Repeat((byte)0xFF, 16).ToArray();

    // ── Envelope ──────────────────────────────────────────────────────

    public sealed record Envelope(
        MessageType Type,
        byte Ttl,
        Flags Flags,
        uint Timestamp,
        byte[] MsgId,
        byte[] SenderPid,
        byte[] DestPid,
        byte HopCount,
        byte SprayRemaining,
        byte[] Payload,
        byte[]? Signature
    );

    // ── Errors ────────────────────────────────────────────────────────

    public class CodecException : Exception
    {
        public CodecException(string message) : base(message) { }
    }

    // ── Encode ────────────────────────────────────────────────────────

    /// <summary>
    /// Serialize an envelope to its wire form. Throws <see cref="CodecException"/>
    /// if any 16-byte ID is the wrong length or the payload exceeds
    /// <see cref="MaxPayloadSize"/>.
    /// </summary>
    public static byte[] Encode(Envelope envelope)
    {
        if (envelope.MsgId.Length != 16 ||
            envelope.SenderPid.Length != 16 ||
            envelope.DestPid.Length != 16)
        {
            throw new CodecException("envelope IDs must each be 16 bytes");
        }
        if (envelope.Payload.Length > MaxPayloadSize)
        {
            throw new CodecException($"payload too large ({envelope.Payload.Length} > {MaxPayloadSize})");
        }
        if ((envelope.Flags & Flags.SignaturePresent) != 0 &&
            envelope.Signature is not { Length: SignatureSize })
        {
            throw new CodecException("SignaturePresent flag set but signature missing or wrong length");
        }

        int sigLen = envelope.Signature?.Length ?? 0;
        var out_ = new byte[HeaderSize + envelope.Payload.Length + sigLen];
        var span = out_.AsSpan();

        span[0] = Version;
        span[1] = (byte)envelope.Type;
        span[2] = envelope.Ttl;
        span[3] = (byte)envelope.Flags;

        BinaryPrimitives.WriteUInt32BigEndian(span.Slice(4, 4), envelope.Timestamp);

        envelope.MsgId.CopyTo(span.Slice(8, 16));
        envelope.SenderPid.CopyTo(span.Slice(24, 16));
        envelope.DestPid.CopyTo(span.Slice(40, 16));

        span[56] = envelope.HopCount;
        span[57] = envelope.SprayRemaining;

        BinaryPrimitives.WriteUInt16BigEndian(span.Slice(58, 2), (ushort)envelope.Payload.Length);

        envelope.Payload.CopyTo(span.Slice(HeaderSize, envelope.Payload.Length));

        if ((envelope.Flags & Flags.SignaturePresent) != 0 && envelope.Signature is not null)
        {
            envelope.Signature.CopyTo(span.Slice(HeaderSize + envelope.Payload.Length, SignatureSize));
        }

        return out_;
    }

    // ── Decode ────────────────────────────────────────────────────────

    /// <summary>
    /// Parse the wire form back into an <see cref="Envelope"/>. Throws on
    /// truncated, version-mismatched, or otherwise malformed input.
    /// Trailing padding bytes (added by <see cref="Pad"/>) are ignored —
    /// payload_len defines the real boundary.
    /// </summary>
    public static Envelope Decode(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < HeaderSize)
            throw new CodecException("envelope truncated (less than header size)");

        byte v = bytes[0];
        if (v != Version)
            throw new CodecException($"version mismatch — expected 0x{Version:X2}, got 0x{v:X2}");

        byte typeRaw = bytes[1];
        if (!Enum.IsDefined(typeof(MessageType), typeRaw))
            throw new CodecException($"unknown message type 0x{typeRaw:X2}");
        var type = (MessageType)typeRaw;
        byte ttl = bytes[2];
        var flags = (Flags)bytes[3];

        uint timestamp = BinaryPrimitives.ReadUInt32BigEndian(bytes.Slice(4, 4));

        var msgId    = bytes.Slice(8, 16).ToArray();
        var senderId = bytes.Slice(24, 16).ToArray();
        var destId   = bytes.Slice(40, 16).ToArray();

        byte hopCount = bytes[56];
        byte sprayRem = bytes[57];

        ushort payloadLen = BinaryPrimitives.ReadUInt16BigEndian(bytes.Slice(58, 2));
        int payloadEnd = HeaderSize + payloadLen;
        if (bytes.Length < payloadEnd)
            throw new CodecException("envelope truncated (payload)");

        var payload = bytes.Slice(HeaderSize, payloadLen).ToArray();

        byte[]? signature = null;
        if ((flags & Flags.SignaturePresent) != 0)
        {
            int sigEnd = payloadEnd + SignatureSize;
            if (bytes.Length < sigEnd)
                throw new CodecException("envelope truncated (signature)");
            signature = bytes.Slice(payloadEnd, SignatureSize).ToArray();
        }

        return new Envelope(
            type, ttl, flags, timestamp,
            msgId, senderId, destId,
            hopCount, sprayRem,
            payload, signature
        );
    }

    // ── Padding ───────────────────────────────────────────────────────

    /// <summary>
    /// Pad an encoded envelope to the next <see cref="PaddingTargets"/>
    /// size. Defeats passive traffic analysis. Receivers strip via
    /// payload_len in the header.
    /// </summary>
    public static byte[] Pad(byte[] encoded)
    {
        int target = encoded.Length;
        foreach (var t in PaddingTargets)
        {
            if (t >= encoded.Length) { target = t; break; }
        }
        if (target == encoded.Length) return encoded;
        var padded = new byte[target];
        encoded.CopyTo(padded, 0);
        return padded;
    }
}
