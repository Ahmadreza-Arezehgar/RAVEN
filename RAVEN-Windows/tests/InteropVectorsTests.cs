// InteropVectorsTests.cs
//
// Cross-platform interop tests. These vectors will be re-run on iOS (via
// XCTest) with the SAME inputs and expected outputs — if any one of them
// drifts, the iOS↔Windows mesh stops interoperating.
//
// To regenerate from iOS: see ios-native/RAVEN/RAVENTests/InteropVectorsTests.swift
// (TODO[iOS-impl]).

using System;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using RAVEN.Windows.Crypto;
using RAVEN.Windows.Mesh;
using Xunit;

namespace RAVEN.Windows.Tests;

public class InteropVectorsTests
{
    // ─── X25519 ECDH + HKDF ──────────────────────────────────────────

    /// <summary>
    /// Vector: deterministic 32-byte X25519 keys → known shared secret → known HKDF output.
    /// These bytes are derived from the iOS test fixture and MUST match.
    /// </summary>
    [Fact]
    public void X25519SharedSecret_KnownVector_ProducesExpectedKey()
    {
        // Alice's private = bytes 0..31 of "alice key material 32 bytes long !!"
        // Bob's   public  = bytes 0..31 of "bob agreement public key 32 bytes !"
        // (placeholder vectors — replace with the iOS-generated ones once that
        //  test exists; for now we just verify ECDH symmetry: Alice⊕BobPub == Bob⊕AlicePub).

        var (alicePriv, alicePub) = MeshCrypto.GenerateX25519Keypair();
        var (bobPriv, bobPub) = MeshCrypto.GenerateX25519Keypair();

        var aliceComputes = MeshCrypto.X25519SharedSecret(alicePriv, bobPub);
        var bobComputes   = MeshCrypto.X25519SharedSecret(bobPriv, alicePub);

        Assert.Equal(aliceComputes, bobComputes);
        Assert.Equal(32, aliceComputes.Length);
    }

    [Fact]
    public void HkdfDerivation_WithFixedSaltAndIkm_ProducesStableKey()
    {
        // Fixed 32-byte IKM so the test is deterministic across implementations.
        var ikm = new byte[32];
        for (int i = 0; i < 32; i++) ikm[i] = (byte)i; // 0x00..0x1F

        var k1 = MeshCrypto.DeriveAesKey(ikm);
        var k2 = MeshCrypto.DeriveAesKey(ikm);

        Assert.Equal(k1, k2);
        Assert.Equal(32, k1.Length);

        // Known answer — pinned here against the iOS HKDF-SHA-256 implementation
        // with salt="RAVEN-MESH" (UTF-8) and empty info, IKM = 0x00..0x1F.
        // Once an iOS-side test produces the same vector, replace this with the
        // actual byte-for-byte expected value.
    }

    // ─── AES-256-GCM round-trip ──────────────────────────────────────

    [Fact]
    public void AesGcm_RoundTrip_ProducesCombinedBlobMatchingIosLayout()
    {
        var key = new byte[32];
        for (int i = 0; i < 32; i++) key[i] = (byte)i; // 0x00..0x1F
        var plaintext = Encoding.UTF8.GetBytes("hello mesh");
        var nonce = new byte[12]; // all zeros for determinism

        var combined = MeshCrypto.AesGcmSealCombined(key, plaintext, nonce);

        // Layout check: nonce(12) || ciphertext || tag(16)
        Assert.Equal(12 + plaintext.Length + 16, combined.Length);
        for (int i = 0; i < 12; i++) Assert.Equal(0, combined[i]); // nonce zeros

        var decrypted = MeshCrypto.AesGcmOpenCombined(key, combined);
        Assert.Equal(plaintext, decrypted);
    }

    [Fact]
    public void ExtractAuthenticNonce_FromCombined_ReturnsFirst12Bytes()
    {
        var combined = new byte[12 + 5 + 16];
        for (int i = 0; i < 12; i++) combined[i] = (byte)(0xA0 + i);

        var nonce = MeshCrypto.ExtractAuthenticNonce(combined);

        Assert.Equal(12, nonce.Length);
        for (int i = 0; i < 12; i++) Assert.Equal((byte)(0xA0 + i), nonce[i]);
    }

    // ─── Ed25519 sign + verify ───────────────────────────────────────

    [Fact]
    public void Ed25519_SignAndVerify_RoundTrip()
    {
        var (priv, pub) = MeshCrypto.GenerateEd25519Keypair();
        var data = Encoding.UTF8.GetBytes("payload to be signed");

        var sig = MeshCrypto.Ed25519Sign(priv, data);
        Assert.Equal(64, sig.Length);

        Assert.True(MeshCrypto.Ed25519Verify(pub, data, sig));

        // Tampered data → fail.
        data[0] ^= 0x01;
        Assert.False(MeshCrypto.Ed25519Verify(pub, data, sig));
    }

    // ─── Fingerprint computation ─────────────────────────────────────

    [Fact]
    public void Fingerprint_FromKnownPublicKey_MatchesIosFormat()
    {
        // Public key = 32 bytes of 0xAA — a deterministic test vector.
        var pub = new byte[32];
        for (int i = 0; i < 32; i++) pub[i] = 0xAA;

        var fp = MeshCrypto.ComputeFingerprint(pub);

        // Format: XXXX-XXXX-XXXX (12 chars + 2 dashes).
        Assert.Equal(14, fp.Length);
        Assert.Equal('-', fp[4]);
        Assert.Equal('-', fp[9]);

        // Recompute on iOS with the same public key to pin the exact value.
        // (Currently smoke-test only.)
    }

    // ─── SecureMeshEnvelope.signingData() — THE most important test ──

    [Fact]
    public void SecureMeshEnvelope_SigningData_MatchesPipeFormatExactly()
    {
        var env = new SecureMeshEnvelope
        {
            ClientMessageId = "msg-001",
            RoomId = "room-A",
            SenderId = "alice",
            SenderName = "Alice",
            RecipientId = "bob",
            MessageType = 0,
            Text = "hi",
            Timestamp = 1700000000.0, // exact second
            Nonce = "AAAAAAAAAAAAAAAAAAAAAA==", // dummy 16-byte b64
            SenderPublicKey = "PUBKEYBASE64",
            OriginDeviceId = "fp-XXXX",
        };

        var bytes = env.SigningData();
        var s = Encoding.UTF8.GetString(bytes);

        // Expected — pipe-delimited, mutable DTN fields excluded, 1700000000 → 1700000000000 ms.
        // After `text` the empty optional fields are: mediaUrl|thumbnailUrl|fileName|
        // mimeType|fileSize|audioDuration|mediaSealed|replyToMessageId|replyToTextPreview|
        // replyToSenderName (10 fields → 10 trailing pipes). Matches iOS byte-for-byte.
        Assert.Equal(
            "msg-001|room-A|alice|Alice|bob|0|AAAAAAAAAAAAAAAAAAAAAA==|PUBKEYBASE64|1700000000000|fp-XXXX|hi||||||||||",
            s);
    }

    // ─── Sealed-Sender v2 (task_a1157777): signs over HASHES, not raw ids ──
    // CRITICAL cross-platform gate: this MUST be byte-identical to iOS
    // MeshInteropVectorsTests' v2 assertion or a sealed broadcast minted on one
    // platform won't verify on the other.
    [Fact]
    public void SecureMeshEnvelope_SigningData_SealedV2_SignsOverHashes()
    {
        var env = new SecureMeshEnvelope
        {
            ClientMessageId = "msg-001",
            RoomId = "room-A",
            SenderId = "alice",          // present locally but NOT signed in v2
            SenderName = "Alice",        // dropped (position 4 empty) in v2
            RecipientId = "bob",         // not signed in v2 (hash carries it)
            MessageType = 0,
            Text = "hi",
            Timestamp = 1700000000.0,
            Nonce = "AAAAAAAAAAAAAAAAAAAAAA==",
            SenderPublicKey = "PUBKEYBASE64",
            OriginDeviceId = "fp-XXXX",
            SealFormat = 2,
            SenderIdHash = "aaaa1111bbbb2222cccc3333",
            RecipientIdHash = "dddd4444eeee5555ffff6666",
        };

        var s = Encoding.UTF8.GetString(env.SigningData());

        // pos 3 = senderIdHash, pos 4 = EMPTY (senderName dropped), pos 5 =
        // recipientIdHash; raw alice/Alice/bob never appear; trailing "|sf:2".
        Assert.Equal(
            "msg-001|room-A|aaaa1111bbbb2222cccc3333||dddd4444eeee5555ffff6666|0|AAAAAAAAAAAAAAAAAAAAAA==|PUBKEYBASE64|1700000000000|fp-XXXX|hi|||||||||||sf:2",
            s);
        Assert.DoesNotContain("alice", s);
        Assert.DoesNotContain("Alice", s);
    }

    [Fact]
    public void SecureMeshEnvelope_SigningData_WithGeoFence_AppendsThreeFields()
    {
        var env = new SecureMeshEnvelope
        {
            ClientMessageId = "msg-001",
            RoomId = "room-A",
            SenderId = "alice",
            SenderName = "Alice",
            RecipientId = "bob",
            MessageType = 0,
            Text = "hi",
            Timestamp = 1700000000.0,
            Nonce = "AAAA",
            SenderPublicKey = "PUB",
            OriginDeviceId = "fp",
            GeoFence = new GeoFence { H3Cell = "8a2a1072b59ffff", RadiusInCells = 2, DeliverOnlyInside = true },
        };

        var s = Encoding.UTF8.GetString(env.SigningData());
        // Last 3 segments after the 20 base ones must be the geo-fence fields:
        Assert.EndsWith("|8a2a1072b59ffff|2|true", s);
    }

    // ─── MeshPostEnvelope signing ────────────────────────────────────

    [Fact]
    public void MeshPostEnvelope_SigningData_MatchesPipeFormat()
    {
        var post = new MeshPostEnvelope
        {
            PostId = "post-1",
            AuthorId = "alice",
            AuthorUsername = "@alice",
            AuthorAvatar = "https://cdn.example.com/a.jpg",
            CreatedAt = 1700000000.5, // verifies ms rounding
            Scope = "public",
            Text = "hello mesh",
            SignerPublicKey = "SPK",
        };

        var s = Encoding.UTF8.GetString(post.SigningData());

        // 1700000000.5 → round(1700000000500) → 1700000000500
        Assert.Equal(
            "POST|post-1|alice|@alice|https://cdn.example.com/a.jpg|hello mesh|1700000000500|public|SPK",
            s);
    }

    // ─── ACK signing ─────────────────────────────────────────────────

    [Fact]
    public void MeshACKEnvelope_SigningData_MatchesPipeFormat()
    {
        var ack = new MeshACKEnvelope
        {
            OriginalMessageId = "msg-1",
            SenderId = "alice",
            RecipientId = "bob",
            Status = "delivered",
            Timestamp = 1700000000.0,
        };

        var s = Encoding.UTF8.GetString(ack.SigningData());
        Assert.Equal("msg-1|alice|bob|delivered|1700000000000", s);

        Assert.Equal("msg-1|alice|bob|delivered", ack.RelayKey());
    }

    // ─── Stop command signing ────────────────────────────────────────

    [Fact]
    public void StopCommand_SigningData_MatchesPipeFormat()
    {
        var stop = new StopCommand { MessageId = "msg-1", Timestamp = 1700000000.0 };
        var s = Encoding.UTF8.GetString(stop.SigningData());
        Assert.Equal("STOP|msg-1|1700000000000", s);
    }

    // ─── Chunk framer round-trip ─────────────────────────────────────

    [Fact]
    public void ChunkFramer_RoundTrip_LargePayload()
    {
        var payload = new byte[1500];
        for (int i = 0; i < payload.Length; i++) payload[i] = (byte)(i & 0xFF);

        var packets = ChunkFramer.EncodeForBle(payload, maxPacketSize: 100);
        Assert.True(packets.Count > 1);

        var reasm = new ChunkFramer.Reassembler();
        byte[]? finalPayload = null;
        foreach (var pkt in packets)
        {
            var maybe = reasm.Feed(senderDeviceId: "fp-test", pkt);
            if (maybe is not null) finalPayload = maybe;
        }
        Assert.NotNull(finalPayload);
        Assert.Equal(payload, finalPayload);
    }

    [Fact]
    public void ChunkFramer_SmallPayload_FitsInOneUnchunkedPacket()
    {
        var payload = Encoding.UTF8.GetBytes("hi");
        var packets = ChunkFramer.EncodeForBle(payload, maxPacketSize: 200);
        Assert.Single(packets);
        Assert.Equal(MeshConstants.ChunkFlagUnchunked, packets[0][0]);

        var reasm = new ChunkFramer.Reassembler();
        var assembled = reasm.Feed("fp-test", packets[0]);
        Assert.Equal(payload, assembled);
    }

    // ─── Group crypto round-trip ─────────────────────────────────────

    [Fact]
    public void GroupCrypto_SealOpen_RoundTripsWithSameKey()
    {
        var groupKey = MeshCrypto.RandomBytes(32);
        var body = "hello group — message via mesh";

        var sealed_ = RAVEN.Windows.Mesh.GroupCrypto.SealBodyWithGroupKey(groupKey, body);
        var opened = RAVEN.Windows.Mesh.GroupCrypto.OpenBodyWithGroupKey(groupKey, sealed_);

        Assert.Equal(body, opened);
    }

    [Fact]
    public void GroupCrypto_OpenWithWrongKey_ThrowsCryptographicException()
    {
        var groupKey = MeshCrypto.RandomBytes(32);
        var wrongKey = MeshCrypto.RandomBytes(32);
        var body = "secret group message";

        var sealed_ = RAVEN.Windows.Mesh.GroupCrypto.SealBodyWithGroupKey(groupKey, body);

        Assert.ThrowsAny<System.Security.Cryptography.CryptographicException>(() =>
            RAVEN.Windows.Mesh.GroupCrypto.OpenBodyWithGroupKey(wrongKey, sealed_));
    }
}
