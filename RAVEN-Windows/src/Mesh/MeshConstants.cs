// MeshConstants.cs
//
// Single source of truth for protocol constants. ALL of these values must
// match the iOS Swift code byte-for-byte — see docs/MESH_PROTOCOL.md.
//
// If you change any constant here, you MUST also change the iOS code AND
// bump the protocol version in EncryptedMeshPayload.v.

using System;

namespace RAVEN.Windows.Mesh;

public static class MeshConstants
{
    // ── GATT spec (§A) ─────────────────────────────────────────────────

    /// <summary>The fixed RAVEN BLE service UUID. All RAVEN devices advertise this.</summary>
    public static readonly Guid ServiceUuid =
        new("12345678-1234-1234-1234-123456789ABC");

    /// <summary>Message TX/RX characteristic — notify + write + writeWithoutResponse.</summary>
    public static readonly Guid MessageCharacteristicUuid =
        new("12345678-1234-1234-1234-123456789ABD");

    /// <summary>Device-info characteristic — read; value is UTF-8 fingerprint.</summary>
    public static readonly Guid DeviceInfoCharacteristicUuid =
        new("12345678-1234-1234-1234-123456789ABE");

    /// <summary>BLE LocalName prefix. Full local name = "RAVEN-" + first 8 chars of fingerprint.</summary>
    public const string AdvertisementLocalNamePrefix = "RAVEN-";

    // ── Fragmentation layer (§B) ───────────────────────────────────────

    public const byte ChunkFlagUnchunked = 0x00;
    public const byte ChunkFlagChunked = 0x01;
    public const int ChunkHeaderSize = 6; // 4 bytes hash + 1 byte total + 1 byte index
    public const int MaxTotalChunks = 255;
    public const int DefaultMtuFallback = 180;
    public const int MinChunkPayload = 20;
    public const int InterChunkDelayMs = 15;
    public const int MaxChunkRetries = 15;
    public static readonly TimeSpan ReassemblyTimeout = TimeSpan.FromSeconds(30);
    public const int MaxPendingHashKeys = 64;

    // ── Crypto (§D) ────────────────────────────────────────────────────

    /// <summary>HKDF salt for ECDH key derivation. Constant — see §D.</summary>
    /// <remarks>
    /// FORWARD-SECRECY GAP: this salt being constant means every pair always derives
    /// the same key from the same X25519 secret. To preserve interop with iOS we
    /// keep it as-is for protocol v1; v2 should derive a per-session salt.
    /// </remarks>
    public static readonly byte[] HkdfSalt =
        System.Text.Encoding.UTF8.GetBytes("RAVEN-MESH");

    /// <summary>HKDF info parameter — empty.</summary>
    public static readonly byte[] HkdfInfo = Array.Empty<byte>();

    /// <summary>AES-256 key length in bytes.</summary>
    public const int AesKeyLength = 32;

    /// <summary>AES-GCM nonce length in bytes (matches Apple default).</summary>
    public const int AesGcmNonceLength = 12;

    /// <summary>AES-GCM tag length in bytes.</summary>
    public const int AesGcmTagLength = 16;

    /// <summary>Length of the envelope-instance nonce (the JSON `n` field). NOT the AES-GCM nonce.</summary>
    public const int EnvelopeNonceLength = 16;

    /// <summary>Ed25519 raw public key length.</summary>
    public const int Ed25519PublicKeyLength = 32;

    /// <summary>Ed25519 raw signature length.</summary>
    public const int Ed25519SignatureLength = 64;

    /// <summary>X25519 raw key length (private = public).</summary>
    public const int X25519KeyLength = 32;

    // ── Routing (§E) ───────────────────────────────────────────────────

    /// <summary>Initial spray budget for free tier.</summary>
    public const int SprayBudgetFreeTier = 5;

    /// <summary>Initial spray budget for RAVEN+ tier.</summary>
    public const int SprayBudgetPaidTier = 50;

    /// <summary>Protocol-max sprayCounter — relays MUST drop envelopes exceeding this.</summary>
    public const int MaxSprayCounter = 50;

    /// <summary>Default ttlSeconds for free tier (1 day).</summary>
    public const int TtlSecondsFreeTier = 86_400;

    /// <summary>Default ttlSeconds for RAVEN+ (3 days).</summary>
    public const int TtlSecondsPaidTier = 259_200;

    /// <summary>Default hopLimit for free tier.</summary>
    public const int HopLimitFreeTier = 10;

    /// <summary>Default hopLimit for RAVEN+ tier.</summary>
    public const int HopLimitPaidTier = 50;

    /// <summary>Protocol-max hopLimit.</summary>
    public const int MaxHopLimit = 50;

    /// <summary>Per-peer outbound rate limit (msgs/minute).</summary>
    public const int PerPeerRateLimitPerMinute = 60;

    // ── Dedup / replay (§E) ────────────────────────────────────────────

    public static readonly TimeSpan DedupRetention = TimeSpan.FromDays(30);
    public static readonly TimeSpan DedupCleanupInterval = TimeSpan.FromHours(6);
    public const int DedupMemoryCacheSize = 10_000;
    public const int UsedNoncesMaxSize = 100_000;

    // ── Background / lifecycle (§H) ────────────────────────────────────

    public static readonly TimeSpan PeriodicCleanupInterval = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan ConnectionCooldownAfterFail = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan ConnectionCooldownAfterSvcDiscoveryFail = TimeSpan.FromMinutes(5);

    // ── Frame discriminators (§B) ──────────────────────────────────────

    public const string FrameKindMeshPost = "mesh_post_v1";
    public const string FrameKindServerReceipt = "server_receipt_v1";
    public const string FrameKindInvBloom = "inv_bloom_v1";
    public const string FrameKindWant = "want_v1";

    // ── Protocol version (§J) ──────────────────────────────────────────

    /// <summary>Current protocol version. Bump on wire-incompatible changes.</summary>
    public const int ProtocolVersion = 1;
}
