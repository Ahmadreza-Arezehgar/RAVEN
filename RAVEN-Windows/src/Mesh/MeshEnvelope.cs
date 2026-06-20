// MeshEnvelope.cs
//
// Wire-compatible JSON envelopes for the RAVEN mesh protocol.
// Mirror of `ios-native/RAVEN/RAVEN/Core/Mesh/MeshEnvelope.swift` and
// `MeshCryptoService.swift` — see docs/MESH_PROTOCOL.md §C.
//
// CRITICAL: every JSON property name and the canonical signingData() byte
// form here MUST match iOS byte-for-byte. Any mismatch breaks signature
// verification and the message gets dropped.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RAVEN.Windows.Mesh;

// ──────────────────────────────────────────────────────────────────────
// MARK: - SecureMeshEnvelope (the inner DM payload)
// ──────────────────────────────────────────────────────────────────────

/// <summary>
/// The DM envelope. Same field names + types as iOS `SecureMeshEnvelope`.
/// Property ordering follows the iOS Swift `CodingKeys` declaration so that
/// default JSON serialization produces the same byte layout.
/// </summary>
public sealed class SecureMeshEnvelope
{
    [JsonPropertyName("id")] public string ClientMessageId { get; set; } = string.Empty;
    [JsonPropertyName("rm")] public string RoomId { get; set; } = string.Empty;
    [JsonPropertyName("sid")] public string SenderId { get; set; } = string.Empty;
    [JsonPropertyName("sn")] public string SenderName { get; set; } = string.Empty;
    [JsonPropertyName("rid")] public string RecipientId { get; set; } = string.Empty;
    [JsonPropertyName("t")] public int MessageType { get; set; }
    [JsonPropertyName("txt"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Text { get; set; }
    [JsonPropertyName("ts")] public double Timestamp { get; set; }
    [JsonPropertyName("sc")] public int SprayCounter { get; set; }
    [JsonPropertyName("hc")] public int HopCount { get; set; }
    [JsonPropertyName("hl")] public int HopLimit { get; set; }
    [JsonPropertyName("rp")] public List<string> RoutePath { get; set; } = new();
    [JsonPropertyName("od")] public string OriginDeviceId { get; set; } = string.Empty;
    [JsonPropertyName("nf")] public bool NeedsForwarding { get; set; }
    [JsonPropertyName("ttl")] public int TtlSeconds { get; set; }

    /// <summary>Base64 of 16-byte random envelope-instance nonce. NOT the AES-GCM nonce.</summary>
    [JsonPropertyName("n")] public string Nonce { get; set; } = string.Empty;

    /// <summary>Base64 of sender's Ed25519 public key (envelope-internal).</summary>
    [JsonPropertyName("spk")] public string SenderPublicKey { get; set; } = string.Empty;

    [JsonPropertyName("mu"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? MediaUrl { get; set; }
    [JsonPropertyName("tu"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ThumbnailUrl { get; set; }
    [JsonPropertyName("fn"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? FileName { get; set; }
    [JsonPropertyName("mt"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? MimeType { get; set; }
    [JsonPropertyName("fs"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? FileSize { get; set; }
    [JsonPropertyName("ad"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? AudioDuration { get; set; }

    [JsonPropertyName("rtid"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ReplyToMessageId { get; set; }
    [JsonPropertyName("rttp"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ReplyToTextPreview { get; set; }
    [JsonPropertyName("rtsn"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ReplyToSenderName { get; set; }

    [JsonPropertyName("ib"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? IsBridged { get; set; }
    [JsonPropertyName("ig"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? IsGroup { get; set; }

    [JsonPropertyName("gf"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public GeoFence? GeoFence { get; set; }

    // Round 26 — sealed-media metadata (JSON "msl"). Bound into SigningData
    // (iOS appends it unconditionally between audioDuration and replyToMessageId).
    [JsonPropertyName("msl"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? MediaSealed { get; set; }

    // Round 46 — group key version (JSON "gkv") + payload-kind discriminator
    // (JSON "pk"). Both bound into SigningData when set.
    [JsonPropertyName("gkv"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? GroupKeyVersion { get; set; }

    [JsonPropertyName("pk"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? PayloadKind { get; set; }

    // Sealed-sender v2 (task_a1157777) — 24-hex identity-hash tokens that ride
    // the SIGNED wire so a relay can verify a sealed broadcast without knowing
    // the sender. SealFormat is the signed discriminator (null/absent ⇒ v1,
    // 2 ⇒ sealed). MUST mirror iOS SecureMeshEnvelope.
    [JsonPropertyName("sih"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SenderIdHash { get; set; }

    [JsonPropertyName("rih"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? RecipientIdHash { get; set; }

    [JsonPropertyName("sf"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? SealFormat { get; set; }

    /// <summary>
    /// Canonical bytes-to-sign for Ed25519. MUST match iOS
    /// `SecureMeshEnvelope.signingData()` byte-for-byte (see §D Rule 1).
    ///
    /// Format (UTF-8, '|' delimiter):
    ///   clientMessageId | roomId | senderId | senderName | recipientId |
    ///   {type as decimal} | nonce | senderPublicKey | {Int64(ts*1000)} |
    ///   originDeviceId | text | mediaUrl | thumbnailUrl | fileName |
    ///   mimeType | {fileSize or empty} | {audioDuration or empty} |
    ///   replyToMessageId | replyToTextPreview | replyToSenderName
    /// + if GeoFence present: | h3Cell | radiusInCells | {bool as "true"/"false"}
    ///
    /// Mutable DTN fields (sc, hc, hl, rp, nf, ttl, ib) are EXCLUDED.
    /// Missing optionals are empty strings between pipes.
    /// </summary>
    public byte[] SigningData()
    {
        var sb = new StringBuilder();

        Append(sb, ClientMessageId);
        AppendPipe(sb, RoomId);
        // Sealed-sender v2 fork (task_a1157777) — MUST match iOS
        // SecureMeshEnvelope.signingData(): sealFormat==2 signs over the
        // identity HASHES that ride the wire (raw ids stripped), senderName
        // dropped; absent ⇒ v1 raw-id form, byte-identical to before.
        if (SealFormat == 2)
        {
            AppendPipe(sb, SenderIdHash ?? string.Empty);    // pos 3 = hash
            AppendPipe(sb, string.Empty);                     // pos 4 = senderName dropped
            AppendPipe(sb, RecipientIdHash ?? string.Empty);  // pos 5 = hash
        }
        else
        {
            AppendPipe(sb, SenderId);
            AppendPipe(sb, SenderName);
            AppendPipe(sb, RecipientId);
        }
        AppendPipe(sb, MessageType.ToString(CultureInfo.InvariantCulture));
        AppendPipe(sb, Nonce);
        AppendPipe(sb, SenderPublicKey);
        AppendPipe(sb, ((long)Math.Round(Timestamp * 1000.0)).ToString(CultureInfo.InvariantCulture));
        AppendPipe(sb, OriginDeviceId);
        AppendPipe(sb, Text ?? string.Empty);
        AppendPipe(sb, MediaUrl ?? string.Empty);
        AppendPipe(sb, ThumbnailUrl ?? string.Empty);
        AppendPipe(sb, FileName ?? string.Empty);
        AppendPipe(sb, MimeType ?? string.Empty);
        AppendPipe(sb, FileSize.HasValue ? FileSize.Value.ToString(CultureInfo.InvariantCulture) : string.Empty);
        AppendPipe(sb, AudioDuration.HasValue ? AudioDuration.Value.ToString(CultureInfo.InvariantCulture) : string.Empty);
        // Round 26 — sealed-media blob, bound so a relay can't substitute
        // attacker ciphertext. iOS appends this UNCONDITIONALLY (empty when nil),
        // between audioDuration and replyToMessageId.
        AppendPipe(sb, MediaSealed ?? string.Empty);
        AppendPipe(sb, ReplyToMessageId ?? string.Empty);
        AppendPipe(sb, ReplyToTextPreview ?? string.Empty);
        AppendPipe(sb, ReplyToSenderName ?? string.Empty);

        if (GeoFence is not null)
        {
            AppendPipe(sb, GeoFence.H3Cell);
            AppendPipe(sb, GeoFence.RadiusInCells.ToString(CultureInfo.InvariantCulture));
            // Swift bool `description` → "true" / "false". MUST match exactly.
            AppendPipe(sb, GeoFence.DeliverOnlyInside ? "true" : "false");
        }

        // Round 46 — bind groupKeyVersion + payloadKind. iOS appends each only
        // when set, gkv before pk, as literal "gkv:<n>" / "pk:<s>".
        if (GroupKeyVersion.HasValue)
        {
            AppendPipe(sb, "gkv:" + GroupKeyVersion.Value.ToString(CultureInfo.InvariantCulture));
        }
        if (!string.IsNullOrEmpty(PayloadKind))
        {
            AppendPipe(sb, "pk:" + PayloadKind);
        }

        // Sealed-sender v2 — bind the discriminator LAST (after gkv/pk) so a
        // relay can't flip sf:2 → absent to re-read a sealed frame as v1.
        if (SealFormat == 2)
        {
            AppendPipe(sb, "sf:2");
        }

        return Encoding.UTF8.GetBytes(sb.ToString());
    }

    private static void Append(StringBuilder sb, string value) => sb.Append(value);
    private static void AppendPipe(StringBuilder sb, string value) { sb.Append('|'); sb.Append(value); }
}

public sealed class GeoFence
{
    [JsonPropertyName("h3Cell")] public string H3Cell { get; set; } = string.Empty;
    [JsonPropertyName("radiusInCells")] public int RadiusInCells { get; set; }
    [JsonPropertyName("deliverOnlyInside")] public bool DeliverOnlyInside { get; set; }
}

// ──────────────────────────────────────────────────────────────────────
// MARK: - SignedMeshPayload (DM, signed, unencrypted)
// ──────────────────────────────────────────────────────────────────────

public sealed class SignedMeshPayload
{
    [JsonPropertyName("e")] public SecureMeshEnvelope Envelope { get; set; } = new();
    [JsonPropertyName("s")] public string Signature { get; set; } = string.Empty; // base64 Ed25519
    [JsonPropertyName("spk")] public string SignerPublicKey { get; set; } = string.Empty; // base64 Ed25519

    [JsonPropertyName("os"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? OriginalSenderSignature { get; set; }

    [JsonPropertyName("ospk"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? OriginalSenderPublicKey { get; set; }
}

// ──────────────────────────────────────────────────────────────────────
// MARK: - EncryptedMeshPayload (DM, encrypted)
// ──────────────────────────────────────────────────────────────────────

public sealed class EncryptedMeshPayload
{
    /// <summary>Base64 AES-256-GCM combined output (nonce ‖ ciphertext ‖ tag).</summary>
    [JsonPropertyName("c")] public string CombinedCiphertext { get; set; } = string.Empty;

    /// <summary>Base64 12-byte nonce (untrusted JSON-level — used for outer dedup).</summary>
    [JsonPropertyName("n")] public string Nonce { get; set; } = string.Empty;

    /// <summary>Base64 sender's X25519 agreement public key (NOT Ed25519).</summary>
    [JsonPropertyName("spk")] public string SenderAgreementPublicKey { get; set; } = string.Empty;

    /// <summary>Protocol version. Currently 1.</summary>
    [JsonPropertyName("v")] public int Version { get; set; } = MeshConstants.ProtocolVersion;

    /// <summary>Optional Ed25519 signature over the embedded SecureMeshEnvelope.signingData().</summary>
    [JsonPropertyName("s"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Signature { get; set; }

    /// <summary>Optional Ed25519 signer public key (CAUTION: 'ssk' — NOT 'spk').</summary>
    [JsonPropertyName("ssk"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SignerEd25519PublicKey { get; set; }
}

// ──────────────────────────────────────────────────────────────────────
// MARK: - MeshPostEnvelope (broadcast post)
// ──────────────────────────────────────────────────────────────────────

public sealed class MeshPostEnvelope
{
    [JsonPropertyName("k")] public string Kind { get; set; } = MeshConstants.FrameKindMeshPost;
    [JsonPropertyName("pid")] public string PostId { get; set; } = string.Empty;
    [JsonPropertyName("aid")] public string AuthorId { get; set; } = string.Empty;
    [JsonPropertyName("aun")] public string AuthorUsername { get; set; } = string.Empty;

    [JsonPropertyName("aav"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? AuthorAvatar { get; set; }

    [JsonPropertyName("ca")] public double CreatedAt { get; set; }
    [JsonPropertyName("sc")] public string Scope { get; set; } = "public";
    [JsonPropertyName("txt")] public string Text { get; set; } = string.Empty;
    [JsonPropertyName("th")] public int TtlHops { get; set; }
    [JsonPropertyName("ts")] public int TtlSeconds { get; set; }
    [JsonPropertyName("hc")] public int HopCount { get; set; }
    [JsonPropertyName("rp")] public List<string> RoutePath { get; set; } = new();
    [JsonPropertyName("od")] public string OriginDeviceId { get; set; } = string.Empty;
    [JsonPropertyName("is")] public string InitialSend { get; set; } = "internet";

    [JsonPropertyName("sig"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Signature { get; set; }

    [JsonPropertyName("spk"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SignerPublicKey { get; set; }

    [JsonPropertyName("rs"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? ShowOnRavenShot { get; set; }

    [JsonPropertyName("lat"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? Latitude { get; set; }

    [JsonPropertyName("lng"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? Longitude { get; set; }

    /// <summary>
    /// Canonical bytes-to-sign — UTF-8 of pipe-delimited:
    ///   POST | postId | authorId | authorUsername | authorAvatar | text |
    ///   {Int64(createdAt*1000)} | scope | signerPublicKey
    /// </summary>
    public byte[] SigningData()
    {
        var sb = new StringBuilder();
        sb.Append("POST");
        sb.Append('|'); sb.Append(PostId);
        sb.Append('|'); sb.Append(AuthorId);
        sb.Append('|'); sb.Append(AuthorUsername);
        sb.Append('|'); sb.Append(AuthorAvatar ?? string.Empty);
        sb.Append('|'); sb.Append(Text);
        sb.Append('|'); sb.Append(((long)Math.Round(CreatedAt * 1000.0)).ToString(CultureInfo.InvariantCulture));
        sb.Append('|'); sb.Append(Scope);
        sb.Append('|'); sb.Append(SignerPublicKey ?? string.Empty);
        return Encoding.UTF8.GetBytes(sb.ToString());
    }
}

// ──────────────────────────────────────────────────────────────────────
// MARK: - MeshACKEnvelope (delivery / read receipts)
// ──────────────────────────────────────────────────────────────────────

public sealed class MeshACKEnvelope
{
    [JsonPropertyName("originalMessageId")] public string OriginalMessageId { get; set; } = string.Empty;
    [JsonPropertyName("senderId")] public string SenderId { get; set; } = string.Empty;
    [JsonPropertyName("recipientId")] public string RecipientId { get; set; } = string.Empty;
    [JsonPropertyName("status")] public string Status { get; set; } = "delivered"; // "delivered" | "read"
    [JsonPropertyName("timestamp")] public double Timestamp { get; set; }

    [JsonPropertyName("pathUsed"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? PathUsed { get; set; }

    [JsonPropertyName("hopCount")] public int HopCount { get; set; }
    [JsonPropertyName("hopLimit")] public int HopLimit { get; set; } = MeshConstants.HopLimitFreeTier;
    [JsonPropertyName("routePath")] public List<string> RoutePath { get; set; } = new();
    [JsonPropertyName("originDeviceId")] public string OriginDeviceId { get; set; } = string.Empty;
    [JsonPropertyName("isACK")] public bool IsAck { get; set; } = true;
    [JsonPropertyName("signature")] public string Signature { get; set; } = string.Empty;
    [JsonPropertyName("signerPublicKey")] public string SignerPublicKey { get; set; } = string.Empty;

    /// <summary>
    /// Canonical bytes-to-sign:
    ///   originalMessageId | senderId | recipientId | status | {Int64(timestamp*1000)}
    /// </summary>
    public byte[] SigningData()
    {
        var sb = new StringBuilder();
        sb.Append(OriginalMessageId);
        sb.Append('|'); sb.Append(SenderId);
        sb.Append('|'); sb.Append(RecipientId);
        sb.Append('|'); sb.Append(Status);
        sb.Append('|'); sb.Append(((long)Math.Round(Timestamp * 1000.0)).ToString(CultureInfo.InvariantCulture));
        return Encoding.UTF8.GetBytes(sb.ToString());
    }

    /// <summary>Dedup relay key — "<msgId>|<senderId>|<recipientId>|<status>".</summary>
    public string RelayKey() => $"{OriginalMessageId}|{SenderId}|{RecipientId}|{Status}";
}

// ──────────────────────────────────────────────────────────────────────
// MARK: - StopCommand
// ──────────────────────────────────────────────────────────────────────

public sealed class StopCommand
{
    [JsonPropertyName("type")] public string Type { get; set; } = "STOP";
    [JsonPropertyName("messageId")] public string MessageId { get; set; } = string.Empty;
    [JsonPropertyName("timestamp")] public double Timestamp { get; set; }
    [JsonPropertyName("signature")] public string Signature { get; set; } = string.Empty;
    [JsonPropertyName("signerPublicKey")] public string SignerPublicKey { get; set; } = string.Empty;

    /// <summary>Signing bytes: STOP | messageId | {Int64(timestamp*1000)}</summary>
    public byte[] SigningData()
    {
        var sb = new StringBuilder();
        sb.Append("STOP");
        sb.Append('|'); sb.Append(MessageId);
        sb.Append('|'); sb.Append(((long)Math.Round(Timestamp * 1000.0)).ToString(CultureInfo.InvariantCulture));
        return Encoding.UTF8.GetBytes(sb.ToString());
    }
}

// ──────────────────────────────────────────────────────────────────────
// MARK: - JSON helpers
// ──────────────────────────────────────────────────────────────────────

public static class MeshJson
{
    /// <summary>JSON options matching iOS default `JSONEncoder` (no sorted keys, no whitespace).</summary>
    public static readonly JsonSerializerOptions DefaultOptions = new()
    {
        WriteIndented = false,
        PropertyNamingPolicy = null, // we declare names explicitly
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// <summary>JSON options matching iOS `.sortedKeys` (used inside AES-GCM seal and for MeshMessageFrame signing).</summary>
    public static readonly JsonSerializerOptions SortedKeysOptions = new()
    {
        WriteIndented = false,
        PropertyNamingPolicy = null,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        // .NET 8 doesn't have a built-in `SortedKeys` option, but since we
        // declare property names explicitly and System.Text.Json serializes
        // in declaration order, we manually emit sorted keys via
        // CanonicalSortedJson.Serialize(...) where strict canonical form is required.
    };
}
