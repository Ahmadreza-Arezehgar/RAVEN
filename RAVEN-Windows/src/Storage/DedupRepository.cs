// DedupRepository.cs
//
// Mirror of `Core/Mesh/MeshDedupRepository.swift`.
// Two-tier dedup: in-memory FIFO (fast path) + SQLite (persistent, 30-day retention).
//
// Dedup keys are namespaced strings — see docs/MESH_PROTOCOL.md §E:
//   "frame:<mid>" | "stop:<id>" | "ack:<relayKey>" | "enc:<nonce>" | <clientMessageId> | <postId>

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging;
using RAVEN.Windows.Mesh;

namespace RAVEN.Windows.Storage;

/// <summary>
/// Tracks which mesh envelopes the local node has already seen, so we don't
/// re-process or re-relay the same envelope twice.
///
/// Concurrency: thread-safe. Uses a <see cref="SemaphoreSlim"/> on the SQLite
/// connection because SqliteConnection is single-threaded.
/// </summary>
public sealed class DedupRepository : IAsyncDisposable
{
    private readonly ILogger<DedupRepository> _log;
    private readonly SqliteConnection _conn;
    private readonly SemaphoreSlim _dbLock = new(1, 1);

    /// <summary>FIFO eviction; oldest entries dropped when over capacity.</summary>
    private readonly ConcurrentDictionary<string, DateTime> _memoryCache = new();
    private readonly object _evictionLock = new();

    private CancellationTokenSource? _cleanupCts;

    public DedupRepository(ILogger<DedupRepository> log, SqliteConnection conn)
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
                @"CREATE TABLE IF NOT EXISTS mesh_dedup (
                    dedup_id TEXT PRIMARY KEY,
                    seen_at  INTEGER NOT NULL
                  );
                  CREATE INDEX IF NOT EXISTS idx_mesh_dedup_seen_at ON mesh_dedup(seen_at);";
            await cmd.ExecuteNonQueryAsync().ConfigureAwait(false);
        }
        finally
        {
            _dbLock.Release();
        }

        // Periodic cleanup every 6 hours (matches iOS).
        _cleanupCts = new CancellationTokenSource();
        _ = Task.Run(async () =>
        {
            while (!_cleanupCts.IsCancellationRequested)
            {
                try { await Task.Delay(MeshConstants.DedupCleanupInterval, _cleanupCts.Token); }
                catch (OperationCanceledException) { return; }
                await CleanupAsync().ConfigureAwait(false);
            }
        });
    }

    /// <summary>
    /// Atomically claim a dedup ID. Returns true if this is the first time
    /// we've seen it (caller should process); false if already claimed
    /// (caller should drop).
    ///
    /// **Important:** the claim happens BEFORE any await, so concurrent
    /// callers with the same ID can't both win. Mirrors the iOS
    /// "claim-before-await" pattern.
    /// </summary>
    public async Task<bool> ClaimAsync(string dedupId)
    {
        if (string.IsNullOrEmpty(dedupId)) return false;

        var now = DateTime.UtcNow;

        // Step 1: in-memory claim (atomic via TryAdd).
        if (!_memoryCache.TryAdd(dedupId, now))
        {
            return false; // someone else already claimed it in-memory
        }

        EnforceMemoryCap();

        // Step 2: check persistent DB (in case the memory cache was evicted
        // since the original sighting).
        try
        {
            await _dbLock.WaitAsync().ConfigureAwait(false);
            try
            {
                using var checkCmd = _conn.CreateCommand();
                checkCmd.CommandText = "SELECT 1 FROM mesh_dedup WHERE dedup_id = $id LIMIT 1";
                checkCmd.Parameters.AddWithValue("$id", dedupId);
                var existing = await checkCmd.ExecuteScalarAsync().ConfigureAwait(false);
                if (existing is not null)
                {
                    // Already persisted — leave the memory entry (so future calls also
                    // hit the fast path) and return false.
                    return false;
                }

                // Insert into DB.
                using var insertCmd = _conn.CreateCommand();
                insertCmd.CommandText = "INSERT INTO mesh_dedup (dedup_id, seen_at) VALUES ($id, $ts)";
                insertCmd.Parameters.AddWithValue("$id", dedupId);
                insertCmd.Parameters.AddWithValue("$ts", new DateTimeOffset(now).ToUnixTimeMilliseconds());
                await insertCmd.ExecuteNonQueryAsync().ConfigureAwait(false);

                return true;
            }
            finally
            {
                _dbLock.Release();
            }
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "DedupRepository ClaimAsync failed for {DedupId}", dedupId);
            // On DB error, fall back to in-memory only.
            return true;
        }
    }

    private void EnforceMemoryCap()
    {
        if (_memoryCache.Count <= MeshConstants.DedupMemoryCacheSize) return;
        lock (_evictionLock)
        {
            if (_memoryCache.Count <= MeshConstants.DedupMemoryCacheSize) return;
            var sorted = _memoryCache.ToArray();
            Array.Sort(sorted, (a, b) => a.Value.CompareTo(b.Value));
            // Drop oldest 10% to amortise.
            var dropCount = MeshConstants.DedupMemoryCacheSize / 10;
            for (int i = 0; i < dropCount; i++)
            {
                _memoryCache.TryRemove(sorted[i].Key, out _);
            }
        }
    }

    /// <summary>Drop entries older than the dedup retention window.</summary>
    public async Task CleanupAsync()
    {
        var cutoff = DateTime.UtcNow - MeshConstants.DedupRetention;
        await _dbLock.WaitAsync().ConfigureAwait(false);
        try
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "DELETE FROM mesh_dedup WHERE seen_at < $cutoff";
            cmd.Parameters.AddWithValue("$cutoff", new DateTimeOffset(cutoff).ToUnixTimeMilliseconds());
            var deleted = await cmd.ExecuteNonQueryAsync().ConfigureAwait(false);
            if (deleted > 0)
                _log.LogInformation("DedupRepository cleanup: removed {Count} expired entries", deleted);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "DedupRepository cleanup failed");
        }
        finally
        {
            _dbLock.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_cleanupCts is not null)
        {
            _cleanupCts.Cancel();
            _cleanupCts.Dispose();
        }
        await _dbLock.WaitAsync().ConfigureAwait(false);
        _dbLock.Release();
        _dbLock.Dispose();
    }
}
