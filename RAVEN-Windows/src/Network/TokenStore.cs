// TokenStore.cs
//
// Auth token persistence — DPAPI-protected JSON file.
// Same threat model as KeyStore.

using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace RAVEN.Windows.Network;

public sealed class TokenStore
{
    private readonly string _path;
    private readonly SemaphoreSlim _lock = new(1, 1);
    private TokenSnapshot? _cached;

    public TokenStore(string? baseDir = null)
    {
        baseDir ??= Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "RAVEN", "auth");
        Directory.CreateDirectory(baseDir);
        _path = Path.Combine(baseDir, "tokens.bin");
    }

    public async Task SaveAsync(string accessToken, string refreshToken)
    {
        await _lock.WaitAsync().ConfigureAwait(false);
        try
        {
            _cached = new TokenSnapshot { AccessToken = accessToken, RefreshToken = refreshToken };
            var json = JsonSerializer.SerializeToUtf8Bytes(_cached);
            var protectedBytes = Protect(json);
            await File.WriteAllBytesAsync(_path, protectedBytes).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    public async Task<string?> GetAccessAsync()
    {
        var snap = await GetSnapshotAsync().ConfigureAwait(false);
        return snap?.AccessToken;
    }

    public async Task<string?> GetRefreshAsync()
    {
        var snap = await GetSnapshotAsync().ConfigureAwait(false);
        return snap?.RefreshToken;
    }

    public async Task ClearAsync()
    {
        await _lock.WaitAsync().ConfigureAwait(false);
        try
        {
            _cached = null;
            if (File.Exists(_path)) File.Delete(_path);
        }
        finally
        {
            _lock.Release();
        }
    }

    private async Task<TokenSnapshot?> GetSnapshotAsync()
    {
        if (_cached is not null) return _cached;
        await _lock.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_cached is not null) return _cached;
            if (!File.Exists(_path)) return null;
            var protectedBytes = await File.ReadAllBytesAsync(_path).ConfigureAwait(false);
            var json = Unprotect(protectedBytes);
            _cached = JsonSerializer.Deserialize<TokenSnapshot>(json);
            return _cached;
        }
        catch
        {
            // Corrupt file — reset.
            try { File.Delete(_path); } catch { }
            return null;
        }
        finally
        {
            _lock.Release();
        }
    }

    // 🔴 hacker-audit 2026-05-19 — XOR fallback now fails hard in Release.
    //
    // PREVIOUSLY: the #if WINDOWS guard meant non-Windows builds (CI
    // runs the test suite on Linux; macOS dev workstations may compile
    // here too) silently dropped to `TestOnlyXor`. The XOR key
    // "raven-test-tokens" is a public constant in source — anyone with
    // 18 bytes of known plaintext (the JSON wrapper "{\"AccessToken\":")
    // recovers the keystream and decrypts every stored token in
    // microseconds.
    //
    // The risk is small in practice (Windows-only release build), but
    // an accidental cross-compile or a non-Windows CI artifact escape
    // ships defenceless storage. In #if !DEBUG we now throw so any
    // such path crashes at first use instead of silently misprotecting.
    private static byte[] Protect(byte[] data)
    {
#if WINDOWS
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            return ProtectedData.Protect(data, null, DataProtectionScope.CurrentUser);
#endif
#if DEBUG
        return TestOnlyXor(data);
#else
        throw new PlatformNotSupportedException(
            "TokenStore requires Windows DPAPI. Refusing to fall back to test-only XOR in Release.");
#endif
    }

    private static byte[] Unprotect(byte[] data)
    {
#if WINDOWS
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            return ProtectedData.Unprotect(data, null, DataProtectionScope.CurrentUser);
#endif
#if DEBUG
        return TestOnlyXor(data);
#else
        throw new PlatformNotSupportedException(
            "TokenStore requires Windows DPAPI. Refusing to fall back to test-only XOR in Release.");
#endif
    }

    private static byte[] TestOnlyXor(byte[] data)
    {
        var key = "raven-test-tokens"u8.ToArray();
        var output = new byte[data.Length];
        for (int i = 0; i < data.Length; i++) output[i] = (byte)(data[i] ^ key[i % key.Length]);
        return output;
    }

    private sealed class TokenSnapshot
    {
        public string AccessToken { get; set; } = string.Empty;
        public string RefreshToken { get; set; } = string.Empty;
    }
}
