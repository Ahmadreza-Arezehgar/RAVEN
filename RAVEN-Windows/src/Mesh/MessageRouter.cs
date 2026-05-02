// MessageRouter.cs
//
// Mirror of `Core/Mesh/MessageRouter.swift`.
//
// On send: tries server-route AND mesh-route in parallel (dual-path) when
// the server is reachable. Otherwise mesh-only. Same clientMessageId
// dedupes server-side; first-delivery-wins.
//
// On receive: dispatches by frame type (DM, post, ACK, stop) and feeds
// dedup + verify + (optionally) re-broadcast.

using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;
using RAVEN.Windows.Crypto;
using RAVEN.Windows.Network;
using RAVEN.Windows.Storage;

namespace RAVEN.Windows.Mesh;

public sealed class MessageRouter
{
    private readonly ILogger<MessageRouter> _log;
    private readonly BleEngine _ble;
    private readonly ApiClient _api;
    private readonly RealtimeWebSocket _realtime;
    private readonly DedupRepository _dedup;
    private readonly TrustStore _trust;
    private readonly KeyStore _keyStore;

    /// <summary>Set this from the network monitor — if false, we go mesh-only.</summary>
    public bool ServerReachable { get; set; } = true;

    /// <summary>Tier-dependent spray budget (5 free, 50 paid).</summary>
    public int SprayBudget { get; set; } = MeshConstants.SprayBudgetFreeTier;

    /// <summary>Tier-dependent hop limit (10 free, 50 paid).</summary>
    public int HopLimit { get; set; } = MeshConstants.HopLimitFreeTier;

    /// <summary>Tier-dependent TTL (1d free, 3d paid).</summary>
    public int TtlSeconds { get; set; } = MeshConstants.TtlSecondsFreeTier;

    // ─── Live mesh stats (read by the UI's Account / diagnostics view) ──

    private long _framesRelayed;
    private long _bridgeUplinks;
    public long FramesRelayed => Interlocked.Read(ref _framesRelayed);
    public long BridgeUplinks => Interlocked.Read(ref _bridgeUplinks);

    public MessageRouter(
        ILogger<MessageRouter> log,
        BleEngine ble,
        ApiClient api,
        RealtimeWebSocket realtime,
        DedupRepository dedup,
        TrustStore trust,
        KeyStore keyStore)
    {
        _log = log;
        _ble = ble;
        _api = api;
        _realtime = realtime;
        _dedup = dedup;
        _trust = trust;
        _keyStore = keyStore;

        _ble.OnInboundPacket += HandleInboundFromBle;
        _realtime.OnTextMessage += HandleInboundFromRealtime;
    }

    // ─── SEND ────────────────────────────────────────────────────────

    /// <summary>
    /// Send a DM. Routes by server availability + media type:
    ///   - text/location/system + online → dual-path (server + mesh).
    ///   - text/location/system + offline → mesh-only.
    ///   - media (image/file/voice) → server only; queue if offline.
    /// </summary>
    public async Task SendDmAsync(SecureMeshEnvelope env, string recipientX25519PubBase64, CancellationToken ct = default)
    {
        var keys = await _keyStore.LoadOrCreateAsync().ConfigureAwait(false);
        env.SenderPublicKey = Convert.ToBase64String(keys.Ed25519PublicKey);
        env.OriginDeviceId = keys.Fingerprint;
        if (env.RoutePath.Count == 0) env.RoutePath.Add(keys.Fingerprint);
        env.Nonce = Convert.ToBase64String(MeshCrypto.RandomBytes(MeshConstants.EnvelopeNonceLength));
        env.Timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        env.SprayCounter = SprayBudget;
        env.HopLimit = HopLimit;
        env.HopCount = 0;
        env.TtlSeconds = TtlSeconds;
        env.NeedsForwarding = true;

        if (IsMediaType(env.MessageType))
        {
            // Media doesn't go through mesh — server only.
            if (!ServerReachable)
            {
                _log.LogInformation("Media DM queued (offline): {Id}", env.ClientMessageId);
                // TODO: persist outbox row.
                return;
            }
            await SendViaServerAsync(env, ct).ConfigureAwait(false);
            return;
        }

        // Text / location / system: dual-path or mesh-only.
        var serverTask = ServerReachable ? SendViaServerAsync(env, ct) : Task.CompletedTask;
        var meshTask = SendViaMeshAsync(env, recipientX25519PubBase64, ct);

        await Task.WhenAll(serverTask, meshTask).ConfigureAwait(false);
    }

    private static bool IsMediaType(int t) => t is 1 or 2 or 3 or 7 or 8 or 9;

    private async Task SendViaServerAsync(SecureMeshEnvelope env, CancellationToken ct)
    {
        try
        {
            // Fire-and-forget POST to /api/messages/send.
            var resp = await _api.SendAuthenticatedAsync(System.Net.Http.HttpMethod.Post, "/api/messages/send",
                new { client_message_id = env.ClientMessageId, recipient_id = env.RecipientId, /* … */ }, ct)
                .ConfigureAwait(false);
            resp.Dispose();
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Server send failed for {Id}", env.ClientMessageId);
        }
    }

    private async Task SendViaMeshAsync(SecureMeshEnvelope env, string recipientX25519PubBase64, CancellationToken ct)
    {
        try
        {
            var keys = await _keyStore.LoadOrCreateAsync().ConfigureAwait(false);

            // Encrypt with X25519 ECDH → HKDF → AES-GCM.
            var peerPub = Convert.FromBase64String(recipientX25519PubBase64);
            var aesKey = MeshCrypto.DeriveSharedKey(keys.X25519PrivateKey, peerPub);
            try
            {
                // Plaintext = sorted-keys JSON of the SecureMeshEnvelope.
                var plaintextJson = CanonicalJson.SerializeSorted(env);
                var combined = MeshCrypto.AesGcmSealCombined(aesKey, System.Text.Encoding.UTF8.GetBytes(plaintextJson));

                // Sign the envelope's signing-data (immutable fields).
                var sig = MeshCrypto.Ed25519Sign(keys.Ed25519PrivateKey, env.SigningData());

                var payload = new EncryptedMeshPayload
                {
                    CombinedCiphertext = Convert.ToBase64String(combined),
                    Nonce = Convert.ToBase64String(MeshCrypto.ExtractAuthenticNonce(combined)),
                    SenderAgreementPublicKey = Convert.ToBase64String(keys.X25519PublicKey),
                    Version = MeshConstants.ProtocolVersion,
                    Signature = Convert.ToBase64String(sig),
                    SignerEd25519PublicKey = Convert.ToBase64String(keys.Ed25519PublicKey),
                };

                var payloadBytes = JsonSerializer.SerializeToUtf8Bytes(payload, MeshJson.DefaultOptions);
                await _ble.BroadcastAsync(payloadBytes, ct).ConfigureAwait(false);
            }
            finally
            {
                System.Security.Cryptography.CryptographicOperations.ZeroMemory(aesKey);
            }
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Mesh send failed for {Id}", env.ClientMessageId);
        }
    }

    // ─── RECEIVE (BLE) ───────────────────────────────────────────────

    private async void HandleInboundFromBle(InboundPacketEvent ev)
    {
        try
        {
            using var doc = JsonDocument.Parse(ev.Payload);
            var root = doc.RootElement;

            // Frame type dispatch (see §B).
            if (root.TryGetProperty("c", out _) && root.TryGetProperty("spk", out _))
            {
                await HandleEncryptedDmAsync(ev.Payload, root).ConfigureAwait(false);
            }
            else if (root.TryGetProperty("e", out _) && root.TryGetProperty("s", out _))
            {
                await HandleSignedDmAsync(ev.Payload, root).ConfigureAwait(false);
            }
            else if (root.TryGetProperty("k", out var kElem) &&
                     kElem.GetString() == MeshConstants.FrameKindMeshPost)
            {
                await HandleMeshPostAsync(ev.Payload, root).ConfigureAwait(false);
            }
            else if (root.TryGetProperty("type", out var typeElem) && typeElem.GetString() == "STOP")
            {
                await HandleStopAsync(ev.Payload, root).ConfigureAwait(false);
            }
            else if (root.TryGetProperty("isACK", out _) || root.TryGetProperty("status", out _))
            {
                await HandleAckAsync(ev.Payload, root).ConfigureAwait(false);
            }
            else
            {
                _log.LogDebug("Unknown frame type from {Sender}", ev.SenderFingerprint);
            }
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Failed to dispatch inbound packet from {Sender}", ev.SenderFingerprint);
        }
    }

    private async Task HandleEncryptedDmAsync(byte[] raw, JsonElement root)
    {
        var nonce = root.GetProperty("n").GetString() ?? string.Empty;
        if (!await _dedup.ClaimAsync($"enc:{nonce}").ConfigureAwait(false)) return;

        var payload = JsonSerializer.Deserialize<EncryptedMeshPayload>(raw, MeshJson.DefaultOptions);
        if (payload is null) return;

        var keys = await _keyStore.LoadOrCreateAsync().ConfigureAwait(false);
        try
        {
            var peerAgreementPub = Convert.FromBase64String(payload.SenderAgreementPublicKey);
            var aesKey = MeshCrypto.DeriveSharedKey(keys.X25519PrivateKey, peerAgreementPub);
            try
            {
                var plaintext = MeshCrypto.AesGcmOpenCombined(aesKey, Convert.FromBase64String(payload.CombinedCiphertext));
                var env = JsonSerializer.Deserialize<SecureMeshEnvelope>(plaintext, MeshJson.DefaultOptions);
                if (env is null) return;

                // Verify Ed25519 signature if present.
                if (!string.IsNullOrEmpty(payload.Signature) && !string.IsNullOrEmpty(payload.SignerEd25519PublicKey))
                {
                    var sigOk = MeshCrypto.Ed25519Verify(
                        Convert.FromBase64String(payload.SignerEd25519PublicKey),
                        env.SigningData(),
                        Convert.FromBase64String(payload.Signature));
                    if (!sigOk)
                    {
                        _log.LogWarning("Encrypted DM signature INVALID for {Id} — dropping", env.ClientMessageId);
                        return;
                    }
                    await TrustOrRejectAsync(env.SenderId, payload.SignerEd25519PublicKey).ConfigureAwait(false);
                }

                await DispatchInboundDmAsync(env).ConfigureAwait(false);

                // Forwarding logic (relay).
                if (env.NeedsForwarding && env.IsValidForRelay(keys.Fingerprint))
                {
                    await RelayAsync(raw).ConfigureAwait(false);
                }
            }
            finally
            {
                System.Security.Cryptography.CryptographicOperations.ZeroMemory(aesKey);
            }
        }
        catch (System.Security.Cryptography.CryptographicException)
        {
            // Not for us (wrong recipient) — that's fine; we can't decrypt it,
            // BUT we still serve two roles for the mesh:
            //   1. RELAY: forward via BLE so other peers can pick it up.
            //   2. BRIDGE: if we're online, also POST the opaque ciphertext
            //      to the server so an offline recipient can pick it up later.
            // Both happen with zero-knowledge — we never see the plaintext.
            await RelayAsync(raw).ConfigureAwait(false);
            await TryBridgeUplinkAsync(raw).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Bridge an opaque encrypted DM envelope to the server (best effort).
    /// The server treats it as a delivery candidate and queues it for the
    /// recipient's next online connection. Idempotency-keyed by the
    /// envelope nonce so duplicate uplinks are deduped server-side.
    /// </summary>
    private async Task TryBridgeUplinkAsync(byte[] rawCiphertextEnvelope)
    {
        if (!ServerReachable) return;
        try
        {
            using var doc = JsonDocument.Parse(rawCiphertextEnvelope);
            var root = doc.RootElement;
            if (!root.TryGetProperty("n", out var nonceElem)) return;
            var nonce = nonceElem.GetString();
            if (string.IsNullOrEmpty(nonce)) return;

            var resp = await _api.SendAuthenticatedAsync(
                System.Net.Http.HttpMethod.Post,
                "/api/mesh/bridge-envelope",
                new
                {
                    envelope_b64 = Convert.ToBase64String(rawCiphertextEnvelope),
                    idempotency_key = $"bridge-enc-{nonce}",
                    path_used = "mesh-bridge",
                }).ConfigureAwait(false);
            resp.Dispose();
            Interlocked.Increment(ref _bridgeUplinks);
            _log.LogDebug("Bridged opaque envelope (nonce={Nonce}) to server", nonce[..Math.Min(8, nonce.Length)]);
        }
        catch (Exception ex)
        {
            _log.LogDebug(ex, "Bridge uplink failed (best-effort, will be retried by other peers)");
        }
    }

    private async Task HandleSignedDmAsync(byte[] raw, JsonElement root)
    {
        var payload = JsonSerializer.Deserialize<SignedMeshPayload>(raw, MeshJson.DefaultOptions);
        if (payload is null) return;

        if (!await _dedup.ClaimAsync(payload.Envelope.ClientMessageId).ConfigureAwait(false)) return;

        var sigOk = MeshCrypto.Ed25519Verify(
            Convert.FromBase64String(payload.SignerPublicKey),
            payload.Envelope.SigningData(),
            Convert.FromBase64String(payload.Signature));
        if (!sigOk)
        {
            _log.LogWarning("Signed DM signature INVALID for {Id} — dropping", payload.Envelope.ClientMessageId);
            return;
        }
        await TrustOrRejectAsync(payload.Envelope.SenderId, payload.SignerPublicKey).ConfigureAwait(false);

        await DispatchInboundDmAsync(payload.Envelope).ConfigureAwait(false);

        var keys = await _keyStore.LoadOrCreateAsync().ConfigureAwait(false);
        if (payload.Envelope.NeedsForwarding && payload.Envelope.IsValidForRelay(keys.Fingerprint))
            await RelayAsync(raw).ConfigureAwait(false);
    }

    private async Task HandleMeshPostAsync(byte[] raw, JsonElement root)
    {
        var post = JsonSerializer.Deserialize<MeshPostEnvelope>(raw, MeshJson.DefaultOptions);
        if (post is null || string.IsNullOrEmpty(post.PostId)) return;

        if (!await _dedup.ClaimAsync($"post:{post.PostId}").ConfigureAwait(false)) return;

        if (!string.IsNullOrEmpty(post.Signature) && !string.IsNullOrEmpty(post.SignerPublicKey))
        {
            var ok = MeshCrypto.Ed25519Verify(
                Convert.FromBase64String(post.SignerPublicKey),
                post.SigningData(),
                Convert.FromBase64String(post.Signature));
            if (!ok)
            {
                _log.LogWarning("Mesh post signature INVALID for {Id}", post.PostId);
                return;
            }
        }

        // TODO: persist post into local feed table; surface UI event.
        _log.LogInformation("Received mesh post {Id} from {Author}", post.PostId, post.AuthorUsername);

        var keys = await _keyStore.LoadOrCreateAsync().ConfigureAwait(false);
        if (post.HopCount < post.TtlHops && !post.RoutePath.Contains(keys.Fingerprint))
            await RelayAsync(raw).ConfigureAwait(false);
    }

    private async Task HandleAckAsync(byte[] raw, JsonElement root)
    {
        var ack = JsonSerializer.Deserialize<MeshACKEnvelope>(raw, MeshJson.DefaultOptions);
        if (ack is null) return;
        if (!await _dedup.ClaimAsync($"ack:{ack.RelayKey()}").ConfigureAwait(false)) return;

        if (string.IsNullOrEmpty(ack.Signature) || string.IsNullOrEmpty(ack.SignerPublicKey))
        {
            _log.LogWarning("Unsigned ACK rejected: {Id}", ack.OriginalMessageId);
            return;
        }
        var ok = MeshCrypto.Ed25519Verify(
            Convert.FromBase64String(ack.SignerPublicKey),
            ack.SigningData(),
            Convert.FromBase64String(ack.Signature));
        if (!ok) return;

        // TODO: update local message status to delivered/read; surface UI event.
        _log.LogInformation("ACK {Status} for {Id}", ack.Status, ack.OriginalMessageId);

        // Bridge uplink: if we're online and the ACK isn't for us, POST to server.
        var keys = await _keyStore.LoadOrCreateAsync().ConfigureAwait(false);
        if (ServerReachable && ack.RecipientId != /* ourUserId */ string.Empty)
        {
            try
            {
                await _api.BridgeAckDeliveredAsync(ack.OriginalMessageId, ack.SenderId, ack.RecipientId)
                    .ConfigureAwait(false);
            }
            catch { /* best effort */ }
        }

        // Relay if hops remaining.
        if (ack.HopCount < ack.HopLimit && !ack.RoutePath.Contains(keys.Fingerprint))
        {
            ack.HopCount++;
            ack.RoutePath.Add(keys.Fingerprint);
            var rebroadcast = JsonSerializer.SerializeToUtf8Bytes(ack, MeshJson.DefaultOptions);
            await _ble.BroadcastAsync(rebroadcast).ConfigureAwait(false);
        }
    }

    private async Task HandleStopAsync(byte[] raw, JsonElement root)
    {
        var stop = JsonSerializer.Deserialize<StopCommand>(raw, MeshJson.DefaultOptions);
        if (stop is null) return;
        if (!await _dedup.ClaimAsync($"stop:{stop.MessageId}").ConfigureAwait(false)) return;
        // Verify
        var ok = MeshCrypto.Ed25519Verify(
            Convert.FromBase64String(stop.SignerPublicKey),
            stop.SigningData(),
            Convert.FromBase64String(stop.Signature));
        if (!ok) return;
        // TODO: mark messageId as stopped in our outbox so we don't re-send.
        _log.LogInformation("STOP received for {Id}", stop.MessageId);
    }

    private async Task TrustOrRejectAsync(string userId, string signerEd25519PubBase64)
    {
        var signerPub = Convert.FromBase64String(signerEd25519PubBase64);
        var trustedDevs = await _trust.GetTrustedDevicesAsync(userId).ConfigureAwait(false);
        if (trustedDevs.Count == 0)
        {
            // TOFU — auto-trust (PROTOCOL v1 behaviour).
            await _trust.AddAsync(userId, signerPub, TrustState.Tofu, name: "mesh-tofu").ConfigureAwait(false);
            return;
        }
        // Already known — match the key. (If no match, the verify call has
        // already returned true here, meaning sender used a key we don't
        // know but signed correctly — protocol v1 accepts; v2 should reject.)
    }

    private Task DispatchInboundDmAsync(SecureMeshEnvelope env)
    {
        // TODO: persist to local DB, raise inbox UI event, send local ACK.
        _log.LogInformation("Inbound DM {Id} from {Sender}: {Text}",
            env.ClientMessageId, env.SenderId, env.Text);
        return Task.CompletedTask;
    }

    private async Task RelayAsync(byte[] raw)
    {
        // TODO: spray-and-wait counter decrement, route-path append, peer selection.
        // For now just rebroadcast as-is.
        Interlocked.Increment(ref _framesRelayed);
        await _ble.BroadcastAsync(raw).ConfigureAwait(false);
    }

    /// <summary>
    /// Send a group message — encrypts the body with the group AES key, then
    /// addresses the resulting envelope to each member individually via the
    /// standard X25519 path. One outbound envelope per recipient.
    /// </summary>
    public async Task SendGroupMessageAsync(GroupInfo group, string plaintextBody, CancellationToken ct = default)
    {
        // 1. Seal the body with the group key (AES-GCM).
        var sealedBody = GroupCrypto.SealBodyWithGroupKey(group.GroupKey, plaintextBody);

        // 2. For each member except us, build + send an individually-addressed envelope.
        var keys = await _keyStore.LoadOrCreateAsync().ConfigureAwait(false);
        var ourEd25519 = Convert.ToBase64String(keys.Ed25519PublicKey);

        foreach (var member in group.Members)
        {
            // Skip ourselves.
            if (Convert.ToBase64String(member.Ed25519PublicKey) == ourEd25519) continue;

            var env = new SecureMeshEnvelope
            {
                ClientMessageId = Guid.NewGuid().ToString(),
                RoomId = group.GroupId,
                SenderId = "self", // TODO: replace with our user id once auth is wired
                SenderName = "self",
                RecipientId = member.UserId,
                MessageType = 0,
                Text = sealedBody,
                IsGroup = true,
            };

            var recipientX25519 = Convert.ToBase64String(member.X25519PublicKey);
            await SendDmAsync(env, recipientX25519, ct).ConfigureAwait(false);
        }
    }

    // ─── RECEIVE (online WebSocket) ──────────────────────────────────

    private void HandleInboundFromRealtime(string text)
    {
        // TODO: parse server-side envelope, dispatch into local DB + UI.
        _log.LogDebug("WS inbound: {Text}", text.Length > 100 ? text[..100] + "..." : text);
    }
}

// ─── Helpers ────────────────────────────────────────────────────────

internal static class CanonicalJson
{
    /// <summary>Serialise an object with sorted JSON keys (matches Swift `.sortedKeys`).</summary>
    public static string SerializeSorted<T>(T obj)
    {
        // Round-trip through JsonNode and then sort keys recursively.
        var raw = JsonSerializer.Serialize(obj, MeshJson.DefaultOptions);
        using var doc = JsonDocument.Parse(raw);
        var sb = new System.Text.StringBuilder();
        WriteSorted(doc.RootElement, sb);
        return sb.ToString();
    }

    private static void WriteSorted(JsonElement el, System.Text.StringBuilder sb)
    {
        switch (el.ValueKind)
        {
            case JsonValueKind.Object:
                sb.Append('{');
                var props = el.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal).ToArray();
                for (int i = 0; i < props.Length; i++)
                {
                    if (i > 0) sb.Append(',');
                    sb.Append('"').Append(JsonEscape(props[i].Name)).Append("\":");
                    WriteSorted(props[i].Value, sb);
                }
                sb.Append('}');
                break;
            case JsonValueKind.Array:
                sb.Append('[');
                bool first = true;
                foreach (var it in el.EnumerateArray())
                {
                    if (!first) sb.Append(',');
                    first = false;
                    WriteSorted(it, sb);
                }
                sb.Append(']');
                break;
            case JsonValueKind.String:
                sb.Append('"').Append(JsonEscape(el.GetString() ?? string.Empty)).Append('"');
                break;
            case JsonValueKind.Number:
            case JsonValueKind.True:
            case JsonValueKind.False:
            case JsonValueKind.Null:
                sb.Append(el.GetRawText());
                break;
        }
    }

    private static string JsonEscape(string s)
    {
        var sb = new System.Text.StringBuilder(s.Length + 2);
        foreach (var ch in s)
        {
            switch (ch)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (ch < 0x20)
                        sb.Append("\\u").Append(((int)ch).ToString("X4"));
                    else
                        sb.Append(ch);
                    break;
            }
        }
        return sb.ToString();
    }
}

internal static class EnvelopeRelayExtensions
{
    public static bool IsValidForRelay(this SecureMeshEnvelope env, string myFingerprint)
    {
        if (env.HopCount >= env.HopLimit) return false;
        if (env.SprayCounter <= 0) return false;
        if (env.RoutePath.Contains(myFingerprint)) return false;
        var ageSec = (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0) - env.Timestamp;
        if (ageSec > env.TtlSeconds) return false;
        return true;
    }
}
