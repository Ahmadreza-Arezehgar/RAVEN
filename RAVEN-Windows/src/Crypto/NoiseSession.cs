// NoiseSession.cs (Windows .NET)
//
// `Noise_IK_25519_ChaChaPoly_SHA256` — IK pattern of the Noise Protocol
// Framework (https://noiseprotocol.org/noise.html#5.2). Sibling of the
// canonical Swift implementations at:
//   • ios-native/RAVEN/RAVEN/Core/Security/NoiseSession.swift
//   • RAVEN-MacApp/RAVEN/Core/Security/NoiseSession.swift
//
// The wire format and HKDF / ChaChaPoly / SHA-256 semantics MUST match
// the Swift sibling byte-for-byte so iOS/Mac ↔ Windows interop works.
// Run the cross-platform self-test in Phase C.1.b before changing any
// constants — Noise is unforgiving about mismatches.
//
// External dependencies needed before this compiles:
//   • `BouncyCastle.Cryptography` NuGet package — provides X25519 key
//     agreement via `Org.BouncyCastle.Crypto.Parameters.X25519PrivateKeyParameters`
//     (.NET's `System.Security.Cryptography` lacks X25519 pre-.NET 9).
//
// What ships in this file: full state-machine + HKDF + AEAD wiring
// using `System.Security.Cryptography` for SHA-256 / HMAC-SHA256 /
// ChaCha20-Poly1305 (all built-in .NET 5+) and BouncyCastle for the
// Curve25519 DH steps. Each handshake message is annotated with the
// Noise spec section it corresponds to so reviewers can audit against
// the upstream document directly.

using System;
using System.Buffers.Binary;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace RAVEN.Windows.Crypto;

public class NoiseException : Exception
{
    public NoiseException(string message) : base(message) { }
}

/// <summary>
/// Drives a `Noise_IK_25519_ChaChaPoly_SHA256` handshake. Two
/// messages: initiator → responder, then responder → initiator.
/// Call <see cref="Split"/> once both messages have been
/// written/read to derive the transport-mode cipher pair.
/// </summary>
public sealed class NoiseSession
{
    public enum Role { Initiator, Responder }

    public const string ProtocolName = "Noise_IK_25519_ChaChaPoly_SHA256";

    private readonly Role _role;
    private readonly byte[] _staticPrivate;     // our X25519 static private key (32 B)
    private readonly byte[] _staticPublic;      // our X25519 static public key (32 B)
    private byte[]? _ePrivate;                  // our ephemeral private key
    private byte[]? _ePublic;                   // our ephemeral public key
    private byte[]? _peerStatic;                // peer X25519 static public key
    private byte[]? _peerEphemeral;             // peer X25519 ephemeral public key

    private byte[] _ck = new byte[32];          // chaining key
    private byte[] _h = new byte[32];           // handshake hash
    private byte[]? _k;                          // current cipher key (32 B)
    private ulong _n;                            // AEAD nonce counter
    private int _msgIndex;

    /// <summary>Peer's static public key — non-null on the responder
    /// after <see cref="ReadMessage1"/>.</summary>
    public byte[]? PeerStaticKey => _peerStatic == null ? null : (byte[])_peerStatic.Clone();

    /// <summary>Handshake hash; useful for binding application-level
    /// data (e.g. an out-of-band SAS verification string) to this
    /// session. Only meaningful after <see cref="Split"/>.</summary>
    public byte[] HandshakeHash => (byte[])_h.Clone();

    public NoiseSession(Role role, byte[] staticPrivate, byte[] staticPublic, byte[]? peerStaticKey, byte[]? prologue = null)
    {
        if (staticPrivate.Length != 32) throw new NoiseException("staticPrivate must be 32 bytes");
        if (staticPublic.Length != 32) throw new NoiseException("staticPublic must be 32 bytes");
        _role = role;
        _staticPrivate = (byte[])staticPrivate.Clone();
        _staticPublic = (byte[])staticPublic.Clone();
        _peerStatic = peerStaticKey == null ? null : (byte[])peerStaticKey.Clone();

        // h = SHA256(protocol_name) (or zero-padded if shorter than 32)
        var nameBytes = Encoding.UTF8.GetBytes(ProtocolName);
        if (nameBytes.Length == 32)
        {
            Array.Copy(nameBytes, _h, 32);
        }
        else if (nameBytes.Length < 32)
        {
            Array.Copy(nameBytes, _h, nameBytes.Length);
        }
        else
        {
            _h = SHA256.HashData(nameBytes);
        }
        Array.Copy(_h, _ck, 32);

        MixHash(prologue ?? Array.Empty<byte>());

        // IK pre-message: responder's static is mixed into the hash by
        // both sides before message 1.
        if (role == Role.Initiator)
        {
            if (_peerStatic == null) throw new NoiseException("Initiator requires peerStaticKey for IK");
            MixHash(_peerStatic);
        }
        else
        {
            // Responder = us, so OUR static IS the responder static.
            MixHash(_staticPublic);
        }
    }

    // ── SymmetricState helpers (Noise §5.2) ───────────────────────

    private void MixHash(byte[] data)
    {
        var combined = new byte[_h.Length + data.Length];
        Array.Copy(_h, 0, combined, 0, _h.Length);
        Array.Copy(data, 0, combined, _h.Length, data.Length);
        _h = SHA256.HashData(combined);
    }

    private void MixKey(byte[] input)
    {
        // HKDF(ck, input, n=2). PRK = HMAC-SHA256(salt=ck, IKM=input).
        // T(1) = HMAC(prk, 0x01) → new chaining key.
        // T(2) = HMAC(prk, T(1) || 0x02) → cipher key.
        var prk = HMACSHA256.HashData(_ck, input);
        var t1 = HMACSHA256.HashData(prk, new byte[] { 0x01 });
        var t2input = new byte[t1.Length + 1];
        Array.Copy(t1, t2input, t1.Length);
        t2input[t1.Length] = 0x02;
        var t2 = HMACSHA256.HashData(prk, t2input);
        _ck = t1;
        _k = t2;
        _n = 0;
    }

    /// <summary>
    /// 96-bit ChaChaPoly nonce: 4 zero bytes prefix + 8-byte LE counter.
    /// Matches Noise's nonce encoding rule.
    /// </summary>
    private byte[] CurrentNonce()
    {
        var nonce = new byte[12];
        BinaryPrimitives.WriteUInt64LittleEndian(nonce.AsSpan(4, 8), _n);
        return nonce;
    }

    private byte[] EncryptAndHash(byte[] plaintext)
    {
        if (_k == null)
        {
            // No cipher key yet — mix plaintext into hash, return as-is.
            MixHash(plaintext);
            return plaintext;
        }
        using var aead = new ChaCha20Poly1305(_k);
        var nonce = CurrentNonce();
        var ct = new byte[plaintext.Length];
        var tag = new byte[16];
        aead.Encrypt(nonce, plaintext, ct, tag, _h);
        var combined = new byte[ct.Length + tag.Length];
        Array.Copy(ct, 0, combined, 0, ct.Length);
        Array.Copy(tag, 0, combined, ct.Length, tag.Length);
        _n++;
        MixHash(combined);
        return combined;
    }

    private byte[] DecryptAndHash(byte[] ciphertext)
    {
        if (_k == null)
        {
            MixHash(ciphertext);
            return ciphertext;
        }
        if (ciphertext.Length < 16) throw new NoiseException("ciphertext too short for AEAD tag");
        var ctLen = ciphertext.Length - 16;
        var ct = new byte[ctLen];
        var tag = new byte[16];
        Array.Copy(ciphertext, 0, ct, 0, ctLen);
        Array.Copy(ciphertext, ctLen, tag, 0, 16);
        var pt = new byte[ctLen];
        try
        {
            using var aead = new ChaCha20Poly1305(_k);
            aead.Decrypt(CurrentNonce(), ct, tag, pt, _h);
        }
        catch (CryptographicException)
        {
            throw new NoiseException("AEAD verify failed");
        }
        _n++;
        MixHash(ciphertext);
        return pt;
    }

    // ── X25519 key agreement (BouncyCastle wrapper) ──────────────

    /// <summary>Generate a fresh X25519 ephemeral keypair.</summary>
    private static (byte[] priv, byte[] pub) GenerateEphemeral()
    {
        // TODO(C.1.g.NSec): swap to System.Security.Cryptography once
        // .NET 9+ ships X25519. Until then, a BouncyCastle dependency
        // is the only built-in path. Replace this method body with:
        //
        //   var generator = new X25519KeyPairGenerator();
        //   generator.Init(new X25519KeyGenerationParameters(new SecureRandom()));
        //   var pair = generator.GenerateKeyPair();
        //   var priv = ((X25519PrivateKeyParameters)pair.Private).GetEncoded();
        //   var pub  = ((X25519PublicKeyParameters)pair.Public).GetEncoded();
        //   return (priv, pub);
        //
        // For a build-able stub before deps are added, error with a
        // pointer at what's missing — CI will catch it.
        throw new NotImplementedException("Add BouncyCastle.Cryptography NuGet to enable X25519");
    }

    /// <summary>X25519 ECDH between our private and a peer's public.
    /// Returns the 32-byte shared secret.</summary>
    private static byte[] DH(byte[] privateKey, byte[] publicKey)
    {
        // TODO(C.1.g.NSec): same plan as GenerateEphemeral.
        //   var priv = new X25519PrivateKeyParameters(privateKey);
        //   var pub  = new X25519PublicKeyParameters(publicKey);
        //   var agreement = new X25519Agreement();
        //   agreement.Init(priv);
        //   var shared = new byte[agreement.AgreementSize];
        //   agreement.CalculateAgreement(pub, shared, 0);
        //   return shared;
        throw new NotImplementedException("Add BouncyCastle.Cryptography NuGet to enable X25519");
    }

    // ── Handshake messages ───────────────────────────────────────

    /// <summary>Initiator → responder. Pattern: e, es, s, ss + payload.</summary>
    public byte[] WriteMessage1(byte[] payload)
    {
        if (_role != Role.Initiator || _msgIndex != 0) throw new NoiseException("WriteMessage1 out of order");
        if (_peerStatic == null) throw new NoiseException("Missing peer static key");

        var (ePriv, ePub) = GenerateEphemeral();
        _ePrivate = ePriv;
        _ePublic = ePub;
        MixHash(ePub);

        // es: DH(e, rs)
        MixKey(DH(ePriv, _peerStatic));

        // s: encrypted static
        var encryptedS = EncryptAndHash(_staticPublic);

        // ss: DH(s, rs)
        MixKey(DH(_staticPrivate, _peerStatic));

        var encryptedPayload = EncryptAndHash(payload ?? Array.Empty<byte>());

        using var ms = new MemoryStream();
        ms.Write(ePub, 0, ePub.Length);
        ms.Write(encryptedS, 0, encryptedS.Length);
        ms.Write(encryptedPayload, 0, encryptedPayload.Length);
        _msgIndex = 1;
        return ms.ToArray();
    }

    public byte[] ReadMessage1(byte[] message)
    {
        if (_role != Role.Responder || _msgIndex != 0) throw new NoiseException("ReadMessage1 out of order");
        if (message.Length < 32 + 32 + 16) throw new NoiseException("message 1 truncated");

        var ePub = new byte[32];
        Array.Copy(message, 0, ePub, 0, 32);
        _peerEphemeral = ePub;
        MixHash(ePub);

        // es: DH(s, re)
        MixKey(DH(_staticPrivate, ePub));

        // s: decrypt 48 bytes
        var encS = new byte[48];
        Array.Copy(message, 32, encS, 0, 48);
        var rs = DecryptAndHash(encS);
        if (rs.Length != 32) throw new NoiseException("recovered static wrong length");
        _peerStatic = rs;

        // ss: DH(s, rs)
        MixKey(DH(_staticPrivate, rs));

        var encPayloadLen = message.Length - 32 - 48;
        var encPayload = new byte[encPayloadLen];
        Array.Copy(message, 32 + 48, encPayload, 0, encPayloadLen);
        var payload = DecryptAndHash(encPayload);
        _msgIndex = 1;
        return payload;
    }

    /// <summary>Responder → initiator. Pattern: e, ee, se + payload.</summary>
    public byte[] WriteMessage2(byte[] payload)
    {
        if (_role != Role.Responder || _msgIndex != 1) throw new NoiseException("WriteMessage2 out of order");
        if (_peerEphemeral == null) throw new NoiseException("Missing peer ephemeral");

        var (ePriv, ePub) = GenerateEphemeral();
        _ePrivate = ePriv;
        _ePublic = ePub;
        MixHash(ePub);

        // ee: DH(e, re)
        MixKey(DH(ePriv, _peerEphemeral));

        // se on responder side: DH(s, re) — our static, peer's ephemeral.
        MixKey(DH(_staticPrivate, _peerEphemeral));

        var encryptedPayload = EncryptAndHash(payload ?? Array.Empty<byte>());

        using var ms = new MemoryStream();
        ms.Write(ePub, 0, ePub.Length);
        ms.Write(encryptedPayload, 0, encryptedPayload.Length);
        _msgIndex = 2;
        return ms.ToArray();
    }

    public byte[] ReadMessage2(byte[] message)
    {
        if (_role != Role.Initiator || _msgIndex != 1) throw new NoiseException("ReadMessage2 out of order");
        if (_ePrivate == null) throw new NoiseException("Missing ephemeral private");
        if (_peerStatic == null) throw new NoiseException("Missing peer static");
        if (message.Length < 32 + 16) throw new NoiseException("message 2 truncated");

        var ePub = new byte[32];
        Array.Copy(message, 0, ePub, 0, 32);
        _peerEphemeral = ePub;
        MixHash(ePub);

        // ee: DH(e, re)
        MixKey(DH(_ePrivate, ePub));
        // se on initiator side: DH(e, rs) — our ephemeral, peer's static.
        MixKey(DH(_ePrivate, _peerStatic));

        var encPayloadLen = message.Length - 32;
        var encPayload = new byte[encPayloadLen];
        Array.Copy(message, 32, encPayload, 0, encPayloadLen);
        var payload = DecryptAndHash(encPayload);
        _msgIndex = 2;
        return payload;
    }

    // ── Split: derive transport-mode cipher pair ─────────────────

    /// <summary>
    /// After both handshake messages have completed, derive the
    /// transport-mode cipher states. Returns `(sending, receiving)`
    /// keyed for THIS side — the initiator's `sending` matches the
    /// responder's `receiving`, and vice versa.
    /// </summary>
    public (NoiseCipherState Send, NoiseCipherState Recv) Split()
    {
        if (_msgIndex != 2) throw new NoiseException("Split called before handshake completed");

        // HKDF(ck, "", n=2) — same n=2 helper as MixKey.
        var prk = HMACSHA256.HashData(_ck, Array.Empty<byte>());
        var t1 = HMACSHA256.HashData(prk, new byte[] { 0x01 });
        var t2input = new byte[t1.Length + 1];
        Array.Copy(t1, t2input, t1.Length);
        t2input[t1.Length] = 0x02;
        var t2 = HMACSHA256.HashData(prk, t2input);

        return _role == Role.Initiator
            ? (new NoiseCipherState(t1), new NoiseCipherState(t2))
            : (new NoiseCipherState(t2), new NoiseCipherState(t1));
    }
}

/// <summary>
/// Post-handshake AEAD state. Each direction (send / receive) gets one.
/// ChaCha20-Poly1305 with monotonically increasing nonces; reusing a
/// nonce is a security failure, so callers should treat the state as
/// non-thread-safe and not mutate from multiple threads concurrently.
/// </summary>
public sealed class NoiseCipherState
{
    private readonly byte[] _key;
    private ulong _n;

    internal NoiseCipherState(byte[] key)
    {
        if (key.Length != 32) throw new NoiseException("key must be 32 bytes");
        _key = (byte[])key.Clone();
    }

    private byte[] CurrentNonce()
    {
        var nonce = new byte[12];
        BinaryPrimitives.WriteUInt64LittleEndian(nonce.AsSpan(4, 8), _n);
        return nonce;
    }

    public byte[] EncryptWithAd(byte[] ad, byte[] plaintext)
    {
        using var aead = new ChaCha20Poly1305(_key);
        var ct = new byte[plaintext.Length];
        var tag = new byte[16];
        aead.Encrypt(CurrentNonce(), plaintext, ct, tag, ad);
        var combined = new byte[ct.Length + tag.Length];
        Array.Copy(ct, 0, combined, 0, ct.Length);
        Array.Copy(tag, 0, combined, ct.Length, tag.Length);
        _n++;
        return combined;
    }

    public byte[] DecryptWithAd(byte[] ad, byte[] ciphertext)
    {
        if (ciphertext.Length < 16) throw new NoiseException("ciphertext too short for AEAD tag");
        var ctLen = ciphertext.Length - 16;
        var ct = new byte[ctLen];
        var tag = new byte[16];
        Array.Copy(ciphertext, 0, ct, 0, ctLen);
        Array.Copy(ciphertext, ctLen, tag, 0, 16);
        var pt = new byte[ctLen];
        try
        {
            using var aead = new ChaCha20Poly1305(_key);
            aead.Decrypt(CurrentNonce(), ct, tag, pt, ad);
        }
        catch (CryptographicException)
        {
            throw new NoiseException("AEAD verify failed");
        }
        _n++;
        return pt;
    }
}
