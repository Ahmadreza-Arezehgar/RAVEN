// MeshCrypto.cs
//
// Cryptographic primitives for the RAVEN mesh protocol. All operations
// here MUST be byte-for-byte interoperable with the iOS Swift code in
// `ios-native/RAVEN/RAVEN/Core/Security/MeshCryptoService.swift` and
// `DeviceIdentityService.swift`.
//
// See docs/MESH_PROTOCOL.md §D for the full spec.

using System;
using System.Security.Cryptography;
using Org.BouncyCastle.Crypto.Agreement;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Security;
using RAVEN.Windows.Mesh;

namespace RAVEN.Windows.Crypto;

/// <summary>
/// Stateless wrappers around the protocol's crypto primitives:
/// X25519 ECDH, HKDF-SHA-256, AES-256-GCM, Ed25519 sign/verify.
///
/// All public-key wire formats are 32 raw bytes (no DER/SPKI wrappers),
/// base64-encoded at the JSON layer.
/// </summary>
public static class MeshCrypto
{
    // ─── Random ────────────────────────────────────────────────────────

    /// <summary>Cryptographically-strong random bytes — wraps CNG.</summary>
    public static byte[] RandomBytes(int length)
    {
        var buf = new byte[length];
        RandomNumberGenerator.Fill(buf);
        return buf;
    }

    // ─── X25519 (key agreement) ────────────────────────────────────────

    /// <summary>Generate a fresh X25519 keypair. Returns (privateKey, publicKey) — 32 bytes each.</summary>
    public static (byte[] privateKey, byte[] publicKey) GenerateX25519Keypair()
    {
        var generator = new X25519KeyPairGenerator();
        generator.Init(new X25519KeyGenerationParameters(new SecureRandom()));
        var pair = generator.GenerateKeyPair();

        var priv = ((X25519PrivateKeyParameters)pair.Private).GetEncoded();
        var pub = ((X25519PublicKeyParameters)pair.Public).GetEncoded();

        return (priv, pub);
    }

    /// <summary>
    /// Derive the X25519 shared secret. Returns 32 raw bytes.
    /// Equivalent of Apple `Curve25519.KeyAgreement.PrivateKey.sharedSecretFromKeyAgreement(with:)`.
    /// </summary>
    public static byte[] X25519SharedSecret(byte[] myPrivate, byte[] peerPublic)
    {
        ArgumentNullException.ThrowIfNull(myPrivate);
        ArgumentNullException.ThrowIfNull(peerPublic);
        if (myPrivate.Length != MeshConstants.X25519KeyLength)
            throw new ArgumentException($"X25519 private key must be {MeshConstants.X25519KeyLength} bytes", nameof(myPrivate));
        if (peerPublic.Length != MeshConstants.X25519KeyLength)
            throw new ArgumentException($"X25519 public key must be {MeshConstants.X25519KeyLength} bytes", nameof(peerPublic));

        var privParams = new X25519PrivateKeyParameters(myPrivate, 0);
        var pubParams = new X25519PublicKeyParameters(peerPublic, 0);

        var agreement = new X25519Agreement();
        agreement.Init(privParams);

        var secret = new byte[agreement.AgreementSize];
        agreement.CalculateAgreement(pubParams, secret, 0);
        return secret;
    }

    // ─── HKDF-SHA-256 ──────────────────────────────────────────────────

    /// <summary>
    /// HKDF-SHA-256 with the protocol's fixed salt + empty info.
    /// Mirrors `MeshCryptoService.deriveSharedKey` on iOS — see §D.
    /// </summary>
    public static byte[] DeriveAesKey(byte[] sharedSecret)
    {
        // .NET 8 has built-in HKDF. SHA-256, salt = "RAVEN-MESH", info = empty,
        // output 32 bytes.
        return HKDF.DeriveKey(
            hashAlgorithmName: HashAlgorithmName.SHA256,
            ikm: sharedSecret,
            outputLength: MeshConstants.AesKeyLength,
            salt: MeshConstants.HkdfSalt,
            info: MeshConstants.HkdfInfo);
    }

    /// <summary>One-shot: derive the AES-256-GCM key for a peer from raw key material.</summary>
    public static byte[] DeriveSharedKey(byte[] myX25519Private, byte[] peerX25519Public)
    {
        var secret = X25519SharedSecret(myX25519Private, peerX25519Public);
        try
        {
            return DeriveAesKey(secret);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(secret);
        }
    }

    // ─── AES-256-GCM ───────────────────────────────────────────────────

    /// <summary>
    /// Encrypt with AES-256-GCM and return the iOS-compatible <c>combined</c> blob:
    /// <c>nonce(12) || ciphertext || tag(16)</c>.
    ///
    /// AAD is empty — matching iOS. (See §I item 3 — empty AAD is a known weakness.)
    /// </summary>
    public static byte[] AesGcmSealCombined(byte[] key, byte[] plaintext, byte[]? nonce = null)
    {
        if (key.Length != MeshConstants.AesKeyLength)
            throw new ArgumentException($"Key must be {MeshConstants.AesKeyLength} bytes", nameof(key));

        nonce ??= RandomBytes(MeshConstants.AesGcmNonceLength);
        if (nonce.Length != MeshConstants.AesGcmNonceLength)
            throw new ArgumentException($"Nonce must be {MeshConstants.AesGcmNonceLength} bytes", nameof(nonce));

        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[MeshConstants.AesGcmTagLength];

        using var aes = new AesGcm(key, MeshConstants.AesGcmTagLength);
        aes.Encrypt(nonce, plaintext, ciphertext, tag, associatedData: ReadOnlySpan<byte>.Empty);

        // Combined output: nonce || ciphertext || tag
        var combined = new byte[nonce.Length + ciphertext.Length + tag.Length];
        Buffer.BlockCopy(nonce, 0, combined, 0, nonce.Length);
        Buffer.BlockCopy(ciphertext, 0, combined, nonce.Length, ciphertext.Length);
        Buffer.BlockCopy(tag, 0, combined, nonce.Length + ciphertext.Length, tag.Length);
        return combined;
    }

    /// <summary>
    /// Open an iOS-style combined AES-256-GCM blob: <c>nonce(12) || ciphertext || tag(16)</c>.
    /// Returns plaintext, or throws <see cref="CryptographicException"/> on tag mismatch.
    /// </summary>
    public static byte[] AesGcmOpenCombined(byte[] key, byte[] combined)
    {
        if (key.Length != MeshConstants.AesKeyLength)
            throw new ArgumentException($"Key must be {MeshConstants.AesKeyLength} bytes", nameof(key));
        if (combined.Length < MeshConstants.AesGcmNonceLength + MeshConstants.AesGcmTagLength)
            throw new ArgumentException("Combined blob too short", nameof(combined));

        var nonce = new byte[MeshConstants.AesGcmNonceLength];
        var tag = new byte[MeshConstants.AesGcmTagLength];
        var ciphertextLen = combined.Length - nonce.Length - tag.Length;
        var ciphertext = new byte[ciphertextLen];

        Buffer.BlockCopy(combined, 0, nonce, 0, nonce.Length);
        Buffer.BlockCopy(combined, nonce.Length, ciphertext, 0, ciphertextLen);
        Buffer.BlockCopy(combined, nonce.Length + ciphertextLen, tag, 0, tag.Length);

        var plaintext = new byte[ciphertextLen];
        using var aes = new AesGcm(key, MeshConstants.AesGcmTagLength);
        aes.Decrypt(nonce, ciphertext, tag, plaintext, associatedData: ReadOnlySpan<byte>.Empty);
        return plaintext;
    }

    /// <summary>
    /// Extract the authentic 12-byte nonce from a combined AES-GCM blob.
    /// Use this for replay tracking — NEVER trust the JSON `n` field.
    /// </summary>
    public static byte[] ExtractAuthenticNonce(byte[] combined)
    {
        if (combined.Length < MeshConstants.AesGcmNonceLength)
            throw new ArgumentException("Blob too short to contain nonce", nameof(combined));
        var nonce = new byte[MeshConstants.AesGcmNonceLength];
        Buffer.BlockCopy(combined, 0, nonce, 0, nonce.Length);
        return nonce;
    }

    // ─── Ed25519 (signing) ─────────────────────────────────────────────

    /// <summary>Generate a fresh Ed25519 keypair. Returns (privateKey, publicKey) — 32 bytes each.</summary>
    public static (byte[] privateKey, byte[] publicKey) GenerateEd25519Keypair()
    {
        var generator = new Ed25519KeyPairGenerator();
        generator.Init(new Ed25519KeyGenerationParameters(new SecureRandom()));
        var pair = generator.GenerateKeyPair();

        var priv = ((Ed25519PrivateKeyParameters)pair.Private).GetEncoded();
        var pub = ((Ed25519PublicKeyParameters)pair.Public).GetEncoded();
        return (priv, pub);
    }

    /// <summary>
    /// Derive the Ed25519 public key from a 32-byte raw private key.
    /// </summary>
    public static byte[] Ed25519DerivePublic(byte[] privateKey)
    {
        if (privateKey.Length != MeshConstants.Ed25519PublicKeyLength)
            throw new ArgumentException("Ed25519 private key must be 32 bytes", nameof(privateKey));
        var priv = new Ed25519PrivateKeyParameters(privateKey, 0);
        return priv.GeneratePublicKey().GetEncoded();
    }

    /// <summary>Sign data with Ed25519. Returns 64-byte raw signature.</summary>
    public static byte[] Ed25519Sign(byte[] privateKey, byte[] data)
    {
        if (privateKey.Length != MeshConstants.Ed25519PublicKeyLength)
            throw new ArgumentException("Ed25519 private key must be 32 bytes", nameof(privateKey));

        var signer = new Ed25519Signer();
        signer.Init(forSigning: true, new Ed25519PrivateKeyParameters(privateKey, 0));
        signer.BlockUpdate(data, 0, data.Length);
        return signer.GenerateSignature();
    }

    /// <summary>Verify an Ed25519 signature. Constant-time per BouncyCastle's implementation.</summary>
    public static bool Ed25519Verify(byte[] publicKey, byte[] data, byte[] signature)
    {
        if (publicKey.Length != MeshConstants.Ed25519PublicKeyLength) return false;
        if (signature.Length != MeshConstants.Ed25519SignatureLength) return false;

        try
        {
            var verifier = new Ed25519Signer();
            verifier.Init(forSigning: false, new Ed25519PublicKeyParameters(publicKey, 0));
            verifier.BlockUpdate(data, 0, data.Length);
            return verifier.VerifySignature(signature);
        }
        catch
        {
            return false;
        }
    }

    // ─── Fingerprint (§D) ──────────────────────────────────────────────

    /// <summary>
    /// Compute the device fingerprint string from an Ed25519 public key.
    /// Format: "XXXX-XXXX-XXXX" (12 chars + 2 dashes).
    ///
    /// Algorithm (mirrors iOS DeviceIdentityService.fingerprintForPublicKey):
    /// 1. SHA-256 of the public key bytes.
    /// 2. Take first 9 bytes, base64-encode.
    /// 3. Strip '+' and '/', truncate to 12 chars.
    /// 4. Insert '-' every 4 chars.
    /// </summary>
    public static string ComputeFingerprint(byte[] ed25519PublicKey)
    {
        if (ed25519PublicKey.Length != MeshConstants.Ed25519PublicKeyLength)
            throw new ArgumentException("Ed25519 public key must be 32 bytes", nameof(ed25519PublicKey));

        var hash = SHA256.HashData(ed25519PublicKey);
        var first9 = hash.AsSpan(0, 9).ToArray();
        var b64 = Convert.ToBase64String(first9)
            .Replace("+", string.Empty)
            .Replace("/", string.Empty);

        var truncated = b64.Length >= 12 ? b64[..12] : b64.PadRight(12, 'A');

        // Insert dashes every 4 chars: "XXXX-XXXX-XXXX"
        return $"{truncated[..4]}-{truncated[4..8]}-{truncated[8..12]}";
    }

    // ─── Pairing verification code (§F) ────────────────────────────────

    /// <summary>
    /// Compute the deterministic 6-digit pairing code shared between two devices.
    /// Both devices compute the same value because public keys are sorted.
    /// </summary>
    public static string ComputePairingCode(byte[] pub1, byte[] pub2, byte[] nonce)
    {
        // Sort by base64 of the raw bytes (lexicographic).
        var b1 = Convert.ToBase64String(pub1);
        var b2 = Convert.ToBase64String(pub2);
        var (lo, hi) = string.CompareOrdinal(b1, b2) <= 0 ? (pub1, pub2) : (pub2, pub1);

        var concatenated = new byte[lo.Length + hi.Length + nonce.Length];
        Buffer.BlockCopy(lo, 0, concatenated, 0, lo.Length);
        Buffer.BlockCopy(hi, 0, concatenated, lo.Length, hi.Length);
        Buffer.BlockCopy(nonce, 0, concatenated, lo.Length + hi.Length, nonce.Length);

        var hash = SHA256.HashData(concatenated);

        // First 4 bytes as big-endian uint32, mod 1_000_000.
        uint code = (uint)((hash[0] << 24) | (hash[1] << 16) | (hash[2] << 8) | hash[3]);
        var digits = code % 1_000_000;
        return digits.ToString("D6");
    }
}
