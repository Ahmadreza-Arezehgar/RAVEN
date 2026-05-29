// EncryptedDb.cs
//
// SQLCipher-backed local database. Mirrors `Core/Storage/DatabaseService.swift`.
//
// Key handling:
//   - 32-byte random key generated on first launch.
//   - Stored DPAPI-protected at %LOCALAPPDATA%\RAVEN\db\db.key
//   - Hex-encoded when passed to SQLCipher via `PRAGMA key = "x'...'"`.
//
// The database file lives at %LOCALAPPDATA%\RAVEN\db\raven.db.

using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;
using RAVEN.Windows.Crypto;

namespace RAVEN.Windows.Storage;

public sealed class EncryptedDb : IAsyncDisposable
{
    private readonly string _baseDir;
    public string DbPath { get; }
    public SqliteConnection Connection { get; }

    public EncryptedDb(string? baseDir = null)
    {
        _baseDir = baseDir ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "RAVEN", "db");
        Directory.CreateDirectory(_baseDir);
        DbPath = Path.Combine(_baseDir, "raven.db");

        var keyHex = LoadOrCreateKeyHex();
        var connStr = new SqliteConnectionStringBuilder
        {
            DataSource = DbPath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Private,
            Pooling = false,
            Password = $"x'{keyHex}'", // SQLCipher hex-key form
        }.ToString();

        Connection = new SqliteConnection(connStr);
    }

    public async Task OpenAsync()
    {
        await Connection.OpenAsync().ConfigureAwait(false);

        // Force SQLCipher to attempt a read so a wrong-key situation surfaces.
        using var cmd = Connection.CreateCommand();
        cmd.CommandText = "SELECT count(*) FROM sqlite_master";
        await cmd.ExecuteScalarAsync().ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        if (Connection.State == System.Data.ConnectionState.Open)
            await Connection.CloseAsync().ConfigureAwait(false);
        await Connection.DisposeAsync().ConfigureAwait(false);
    }

    private string LoadOrCreateKeyHex()
    {
        var keyPath = Path.Combine(_baseDir, "db.key");
        if (File.Exists(keyPath))
        {
            var encrypted = File.ReadAllBytes(keyPath);
            var raw = Unprotect(encrypted);
            return Convert.ToHexString(raw).ToLowerInvariant();
        }

        // First launch — generate a 32-byte random key.
        var key = MeshCrypto.RandomBytes(32);
        var protected_ = Protect(key);
        File.WriteAllBytes(keyPath, protected_);
        return Convert.ToHexString(key).ToLowerInvariant();
    }

    // 🔴 hacker-audit 2026-05-19 — fail hard on non-Windows release.
    // See RAVEN-Windows/src/Network/TokenStore.cs for full rationale.
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
            "EncryptedDb requires Windows DPAPI. Refusing to fall back to test-only XOR in Release.");
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
            "EncryptedDb requires Windows DPAPI. Refusing to fall back to test-only XOR in Release.");
#endif
    }

    private static byte[] TestOnlyXor(byte[] data)
    {
        var key = "raven-test-db"u8.ToArray();
        var output = new byte[data.Length];
        for (int i = 0; i < data.Length; i++) output[i] = (byte)(data[i] ^ key[i % key.Length]);
        return output;
    }
}
