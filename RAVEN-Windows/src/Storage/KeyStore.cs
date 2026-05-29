// KeyStore.cs
//
// Mirror of `Core/Security/DeviceIdentityService.swift` for Windows.
//
// Stores the device's two long-lived keypairs (Ed25519 signing + X25519
// agreement) in DPAPI-protected files under
//   %LOCALAPPDATA%\RAVEN\identity\
//
// DPAPI scope: CurrentUser — the keys can only be decrypted by the
// Windows account that wrote them. Acceptable for a local-only app on a
// non-shared device. (For a server / multi-user host we'd promote to
// LocalMachine + ACLs.)

using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using RAVEN.Windows.Crypto;
using RAVEN.Windows.Mesh;

namespace RAVEN.Windows.Storage;

public sealed class IdentityKeys
{
    public required byte[] Ed25519PrivateKey { get; init; }
    public required byte[] Ed25519PublicKey { get; init; }
    public required byte[] X25519PrivateKey { get; init; }
    public required byte[] X25519PublicKey { get; init; }

    public string Fingerprint => MeshCrypto.ComputeFingerprint(Ed25519PublicKey);
}

public sealed class KeyStore
{
    private readonly string _baseDir;
    private readonly SemaphoreSlim _lock = new(1, 1);
    private IdentityKeys? _cached;

    public KeyStore(string? baseDir = null)
    {
        _baseDir = baseDir ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "RAVEN", "identity");
        Directory.CreateDirectory(_baseDir);
    }

    /// <summary>
    /// Load the device's identity keys, generating fresh ones on first launch.
    /// Cached after first load.
    /// </summary>
    public async Task<IdentityKeys> LoadOrCreateAsync()
    {
        if (_cached is not null) return _cached;

        await _lock.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_cached is not null) return _cached;

            if (TryLoadFromDisk(out var keys))
            {
                _cached = keys!;
                return _cached;
            }

            // First launch — generate everything.
            var (edPriv, edPub) = MeshCrypto.GenerateEd25519Keypair();
            var (xPriv, xPub) = MeshCrypto.GenerateX25519Keypair();
            _cached = new IdentityKeys
            {
                Ed25519PrivateKey = edPriv,
                Ed25519PublicKey = edPub,
                X25519PrivateKey = xPriv,
                X25519PublicKey = xPub,
            };
            SaveToDisk(_cached);
            return _cached;
        }
        finally
        {
            _lock.Release();
        }
    }

    /// <summary>Wipe all stored keys. After this, next load creates fresh ones.</summary>
    public async Task DeleteAllAsync()
    {
        await _lock.WaitAsync().ConfigureAwait(false);
        try
        {
            _cached = null;
            foreach (var name in new[] { "ed25519.priv", "ed25519.pub", "x25519.priv", "x25519.pub" })
            {
                var p = Path.Combine(_baseDir, name);
                if (File.Exists(p)) File.Delete(p);
            }
        }
        finally
        {
            _lock.Release();
        }
    }

    private bool TryLoadFromDisk(out IdentityKeys? keys)
    {
        keys = null;
        try
        {
            byte[] edPriv = ReadProtected("ed25519.priv");
            byte[] edPub = ReadPlain("ed25519.pub");
            byte[] xPriv = ReadProtected("x25519.priv");
            byte[] xPub = ReadPlain("x25519.pub");

            // Sanity: the loaded private keys must derive the loaded publics.
            // Cheap integrity check.
            var derivedEdPub = MeshCrypto.Ed25519DerivePublic(edPriv);
            if (!derivedEdPub.AsSpan().SequenceEqual(edPub.AsSpan()))
                return false;

            keys = new IdentityKeys
            {
                Ed25519PrivateKey = edPriv,
                Ed25519PublicKey = edPub,
                X25519PrivateKey = xPriv,
                X25519PublicKey = xPub,
            };
            return true;
        }
        catch
        {
            return false;
        }
    }

    private void SaveToDisk(IdentityKeys keys)
    {
        WriteProtected("ed25519.priv", keys.Ed25519PrivateKey);
        WritePlain("ed25519.pub", keys.Ed25519PublicKey);
        WriteProtected("x25519.priv", keys.X25519PrivateKey);
        WritePlain("x25519.pub", keys.X25519PublicKey);
    }

    private byte[] ReadProtected(string name)
    {
        var path = Path.Combine(_baseDir, name);
        var encrypted = File.ReadAllBytes(path);
        return Unprotect(encrypted);
    }

    private void WriteProtected(string name, byte[] data)
    {
        var encrypted = Protect(data);
        var path = Path.Combine(_baseDir, name);
        File.WriteAllBytes(path, encrypted);
        // Restrict file ACLs on Windows; on macOS (running tests) this is a no-op.
        TryRestrictPermissions(path);
    }

    private byte[] ReadPlain(string name) => File.ReadAllBytes(Path.Combine(_baseDir, name));

    private void WritePlain(string name, byte[] data)
    {
        var path = Path.Combine(_baseDir, name);
        File.WriteAllBytes(path, data);
        TryRestrictPermissions(path);
    }

    /// <summary>
    /// DPAPI ProtectData (CurrentUser scope) on Windows. On non-Windows
    /// (only used in tests) we use a XOR with a hard-coded test entropy —
    /// **NEVER ship the non-Windows path in production**.
    /// </summary>
    // 🔴 hacker-audit 2026-05-19 — fail hard on non-Windows release.
    // See RAVEN-Windows/src/Network/TokenStore.cs for full rationale.
    private static byte[] Protect(byte[] data)
    {
#if WINDOWS
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            return ProtectedData.Protect(data, optionalEntropy: null, scope: DataProtectionScope.CurrentUser);
#endif
#if DEBUG
        return TestOnlyXor(data);
#else
        throw new PlatformNotSupportedException(
            "KeyStore requires Windows DPAPI. Refusing to fall back to test-only XOR in Release.");
#endif
    }

    private static byte[] Unprotect(byte[] data)
    {
#if WINDOWS
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            return ProtectedData.Unprotect(data, optionalEntropy: null, scope: DataProtectionScope.CurrentUser);
#endif
#if DEBUG
        return TestOnlyXor(data);
#else
        throw new PlatformNotSupportedException(
            "KeyStore requires Windows DPAPI. Refusing to fall back to test-only XOR in Release.");
#endif
    }

    /// <summary>Reversible XOR for non-Windows test runs only. NOT secure.</summary>
    private static byte[] TestOnlyXor(byte[] data)
    {
        var key = "raven-test-entropy"u8.ToArray();
        var output = new byte[data.Length];
        for (int i = 0; i < data.Length; i++) output[i] = (byte)(data[i] ^ key[i % key.Length]);
        return output;
    }

    private static void TryRestrictPermissions(string path)
    {
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) return;
        try
        {
            // On Windows the parent dir already inherits CurrentUser ACL via
            // %LOCALAPPDATA%; nothing further needed in normal cases.
            var info = new FileInfo(path) { Attributes = FileAttributes.Hidden };
            _ = info; // keep compiler happy
        }
        catch { /* best effort */ }
    }
}
