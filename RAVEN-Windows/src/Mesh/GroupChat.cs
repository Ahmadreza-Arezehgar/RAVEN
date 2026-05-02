// GroupChat.cs
//
// Group chat support — mirrors `Core/Storage/GroupRepository.swift` +
// `Core/Mesh/MeshCryptoService.swift` group-key handling.
//
// Model:
//   - A group has an integer `keyVersion` (gkv) and a 32-byte AES key.
//   - The group key is rotated when membership changes.
//   - Senders encrypt the message body with AES-GCM(groupKey) — the
//     ciphertext goes in the `txt` field of SecureMeshEnvelope.
//   - Outer envelope is THEN encrypted to each recipient via the normal
//     X25519+HKDF+AES-GCM path. So a 5-member group = 5 outbound
//     envelopes, each addressed to one member.
//
// This is the simple "one envelope per recipient" model. A more efficient
// approach (single ciphertext + per-recipient key wraps) is a v2 task.

using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging;
using RAVEN.Windows.Crypto;

namespace RAVEN.Windows.Mesh;

public sealed record GroupMember(
    string UserId,
    byte[] X25519PublicKey,
    byte[] Ed25519PublicKey,
    string DisplayName);

public sealed class GroupInfo
{
    public string GroupId { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
    public int KeyVersion { get; set; }
    public byte[] GroupKey { get; set; } = Array.Empty<byte>();
    public List<GroupMember> Members { get; init; } = new();
}

/// <summary>
/// Repository for groups + group keys.
/// </summary>
public sealed class GroupRepository
{
    private readonly ILogger<GroupRepository> _log;
    private readonly SqliteConnection _conn;
    private readonly SemaphoreSlim _dbLock = new(1, 1);

    public GroupRepository(ILogger<GroupRepository> log, SqliteConnection conn)
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
            cmd.CommandText = @"
                CREATE TABLE IF NOT EXISTS groups (
                    group_id     TEXT PRIMARY KEY,
                    name         TEXT NOT NULL,
                    key_version  INTEGER NOT NULL DEFAULT 1,
                    group_key    BLOB NOT NULL,
                    created_at   INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS group_members (
                    group_id      TEXT NOT NULL,
                    user_id       TEXT NOT NULL,
                    x25519_pub    BLOB NOT NULL,
                    ed25519_pub   BLOB NOT NULL,
                    display_name  TEXT NOT NULL,
                    PRIMARY KEY(group_id, user_id),
                    FOREIGN KEY(group_id) REFERENCES groups(group_id) ON DELETE CASCADE
                );
            ";
            await cmd.ExecuteNonQueryAsync().ConfigureAwait(false);
        }
        finally
        {
            _dbLock.Release();
        }
    }

    public async Task<GroupInfo?> GetAsync(string groupId)
    {
        await _dbLock.WaitAsync().ConfigureAwait(false);
        try
        {
            using var cmdG = _conn.CreateCommand();
            cmdG.CommandText = "SELECT group_id, name, key_version, group_key FROM groups WHERE group_id=$g";
            cmdG.Parameters.AddWithValue("$g", groupId);
            using var rdrG = await cmdG.ExecuteReaderAsync().ConfigureAwait(false);
            if (!await rdrG.ReadAsync().ConfigureAwait(false)) return null;

            var info = new GroupInfo
            {
                GroupId = rdrG.GetString(0),
                Name = rdrG.GetString(1),
                KeyVersion = rdrG.GetInt32(2),
                GroupKey = (byte[])rdrG.GetValue(3),
            };
            await rdrG.CloseAsync().ConfigureAwait(false);

            using var cmdM = _conn.CreateCommand();
            cmdM.CommandText = "SELECT user_id, x25519_pub, ed25519_pub, display_name FROM group_members WHERE group_id=$g";
            cmdM.Parameters.AddWithValue("$g", groupId);
            using var rdrM = await cmdM.ExecuteReaderAsync().ConfigureAwait(false);
            while (await rdrM.ReadAsync().ConfigureAwait(false))
            {
                info.Members.Add(new GroupMember(
                    rdrM.GetString(0),
                    (byte[])rdrM.GetValue(1),
                    (byte[])rdrM.GetValue(2),
                    rdrM.GetString(3)));
            }
            return info;
        }
        finally
        {
            _dbLock.Release();
        }
    }

    /// <summary>
    /// Create a new group with a fresh AES-256 key (key version 1).
    /// </summary>
    public async Task CreateAsync(string groupId, string name, IEnumerable<GroupMember> members)
    {
        var key = MeshCrypto.RandomBytes(32);
        await _dbLock.WaitAsync().ConfigureAwait(false);
        try
        {
            using var tx = _conn.BeginTransaction();

            using var cmdG = _conn.CreateCommand();
            cmdG.Transaction = tx;
            cmdG.CommandText = @"
                INSERT OR REPLACE INTO groups (group_id, name, key_version, group_key, created_at)
                VALUES ($g, $n, 1, $k, $ts)";
            cmdG.Parameters.AddWithValue("$g", groupId);
            cmdG.Parameters.AddWithValue("$n", name);
            cmdG.Parameters.AddWithValue("$k", key);
            cmdG.Parameters.AddWithValue("$ts", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            await cmdG.ExecuteNonQueryAsync().ConfigureAwait(false);

            foreach (var m in members)
            {
                using var cmdM = _conn.CreateCommand();
                cmdM.Transaction = tx;
                cmdM.CommandText = @"
                    INSERT OR REPLACE INTO group_members (group_id, user_id, x25519_pub, ed25519_pub, display_name)
                    VALUES ($g, $u, $xp, $ep, $dn)";
                cmdM.Parameters.AddWithValue("$g", groupId);
                cmdM.Parameters.AddWithValue("$u", m.UserId);
                cmdM.Parameters.AddWithValue("$xp", m.X25519PublicKey);
                cmdM.Parameters.AddWithValue("$ep", m.Ed25519PublicKey);
                cmdM.Parameters.AddWithValue("$dn", m.DisplayName);
                await cmdM.ExecuteNonQueryAsync().ConfigureAwait(false);
            }

            tx.Commit();
        }
        finally
        {
            _dbLock.Release();
        }
        _log.LogInformation("Group {Id} created with {N} members", groupId, members.Count());
    }

    /// <summary>
    /// Rotate the group key — done when membership changes.
    /// Bumps keyVersion and replaces the AES key.
    /// </summary>
    public async Task RotateKeyAsync(string groupId)
    {
        var key = MeshCrypto.RandomBytes(32);
        await _dbLock.WaitAsync().ConfigureAwait(false);
        try
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = @"
                UPDATE groups
                SET key_version = key_version + 1,
                    group_key   = $k
                WHERE group_id = $g";
            cmd.Parameters.AddWithValue("$g", groupId);
            cmd.Parameters.AddWithValue("$k", key);
            await cmd.ExecuteNonQueryAsync().ConfigureAwait(false);
        }
        finally
        {
            _dbLock.Release();
        }
        _log.LogInformation("Group {Id} key rotated", groupId);
    }
}

/// <summary>
/// Helpers to encrypt/decrypt the inner group payload with the group AES key.
/// The OUTER envelope (with senderId / recipientId / signature) is still
/// per-member via the standard X25519 path.
/// </summary>
public static class GroupCrypto
{
    /// <summary>Seal the plaintext body with the group's AES key. Returns base64(combined).</summary>
    public static string SealBodyWithGroupKey(byte[] groupKey, string plaintextText)
    {
        var pt = System.Text.Encoding.UTF8.GetBytes(plaintextText);
        var combined = MeshCrypto.AesGcmSealCombined(groupKey, pt);
        return Convert.ToBase64String(combined);
    }

    /// <summary>Open a group-encrypted body. Returns the plaintext text.</summary>
    public static string OpenBodyWithGroupKey(byte[] groupKey, string base64Combined)
    {
        var combined = Convert.FromBase64String(base64Combined);
        var pt = MeshCrypto.AesGcmOpenCombined(groupKey, combined);
        return System.Text.Encoding.UTF8.GetString(pt);
    }
}
