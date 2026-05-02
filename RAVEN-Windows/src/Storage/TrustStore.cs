// TrustStore.cs
//
// Mirror of `Core/Storage/FriendDeviceRepository.swift`.
//
// For each known userId, stores one or more trusted Ed25519 public keys.
// Trust state is stored as a string column for forward compatibility:
//   "verified"    — confirmed via QR/SAS pairing
//   "tofu"        — first-seen, auto-trusted (PROTOCOL v1 behaviour, see §F)
//   "unverified"  — seen but never confirmed (RESERVED for v2)

using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging;

namespace RAVEN.Windows.Storage;

public enum TrustState
{
    Verified,
    Tofu,
    Unverified
}

public sealed record TrustedDevice(
    string UserId,
    byte[] Ed25519PublicKey,
    TrustState State,
    string? DisplayName,
    DateTime FirstSeenUtc);

public sealed class TrustStore
{
    private readonly ILogger<TrustStore> _log;
    private readonly SqliteConnection _conn;
    private readonly SemaphoreSlim _dbLock = new(1, 1);

    public TrustStore(ILogger<TrustStore> log, SqliteConnection conn)
    {
        _log = log;
        _conn = conn;
    }

    public async Task InitializeAsync()
    {
        await _dbLock.WaitAsync().ConfigureAwait(false);
        try
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText =
                @"CREATE TABLE IF NOT EXISTS friend_devices (
                    user_id    TEXT NOT NULL,
                    pubkey     BLOB NOT NULL,
                    state      TEXT NOT NULL,
                    name       TEXT,
                    first_seen INTEGER NOT NULL,
                    PRIMARY KEY(user_id, pubkey)
                  );
                  CREATE INDEX IF NOT EXISTS idx_friend_devices_user ON friend_devices(user_id);";
            await cmd.ExecuteNonQueryAsync().ConfigureAwait(false);
        }
        finally
        {
            _dbLock.Release();
        }
    }

    public async Task<List<TrustedDevice>> GetTrustedDevicesAsync(string userId)
    {
        await _dbLock.WaitAsync().ConfigureAwait(false);
        try
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText =
                "SELECT pubkey, state, name, first_seen FROM friend_devices WHERE user_id = $u";
            cmd.Parameters.AddWithValue("$u", userId);

            var results = new List<TrustedDevice>();
            using var reader = await cmd.ExecuteReaderAsync().ConfigureAwait(false);
            while (await reader.ReadAsync().ConfigureAwait(false))
            {
                var pubkey = (byte[])reader.GetValue(0);
                var state = ParseState(reader.GetString(1));
                var name = reader.IsDBNull(2) ? null : reader.GetString(2);
                var firstSeen = DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64(3)).UtcDateTime;
                results.Add(new TrustedDevice(userId, pubkey, state, name, firstSeen));
            }
            return results;
        }
        finally
        {
            _dbLock.Release();
        }
    }

    /// <summary>
    /// Add a trusted device for a user. Idempotent (same user+pubkey is a no-op).
    /// </summary>
    public async Task AddAsync(string userId, byte[] ed25519Pub, TrustState state, string? name = null)
    {
        await _dbLock.WaitAsync().ConfigureAwait(false);
        try
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText =
                @"INSERT OR IGNORE INTO friend_devices (user_id, pubkey, state, name, first_seen)
                  VALUES ($u, $pk, $st, $name, $ts)";
            cmd.Parameters.AddWithValue("$u", userId);
            cmd.Parameters.AddWithValue("$pk", ed25519Pub);
            cmd.Parameters.AddWithValue("$st", state.ToString().ToLowerInvariant());
            cmd.Parameters.AddWithValue("$name", (object?)name ?? DBNull.Value);
            cmd.Parameters.AddWithValue("$ts", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            await cmd.ExecuteNonQueryAsync().ConfigureAwait(false);
        }
        finally
        {
            _dbLock.Release();
        }
    }

    /// <summary>Promote a TOFU/unverified device to verified (after QR/SAS).</summary>
    public async Task PromoteToVerifiedAsync(string userId, byte[] ed25519Pub)
    {
        await _dbLock.WaitAsync().ConfigureAwait(false);
        try
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText =
                "UPDATE friend_devices SET state = 'verified' WHERE user_id = $u AND pubkey = $pk";
            cmd.Parameters.AddWithValue("$u", userId);
            cmd.Parameters.AddWithValue("$pk", ed25519Pub);
            await cmd.ExecuteNonQueryAsync().ConfigureAwait(false);
        }
        finally
        {
            _dbLock.Release();
        }
    }

    public async Task<bool> IsTrustedAsync(string userId, byte[] ed25519Pub)
    {
        var devices = await GetTrustedDevicesAsync(userId).ConfigureAwait(false);
        foreach (var dev in devices)
        {
            if (dev.Ed25519PublicKey.AsSpan().SequenceEqual(ed25519Pub.AsSpan()))
                return true;
        }
        return false;
    }

    private static TrustState ParseState(string s) => s.ToLowerInvariant() switch
    {
        "verified" => TrustState.Verified,
        "tofu" => TrustState.Tofu,
        _ => TrustState.Unverified,
    };
}
