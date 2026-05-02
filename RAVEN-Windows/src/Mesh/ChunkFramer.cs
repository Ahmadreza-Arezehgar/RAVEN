// ChunkFramer.cs
//
// BLE wire-frame fragmentation layer. Mirrors the iOS BLEMeshEngine
// chunk encoder/decoder. See docs/MESH_PROTOCOL.md §B.
//
// Wire format per packet:
//   1 byte: flag (0x00 = unchunked, 0x01 = chunked)
//   if chunked:
//     4 bytes: messageHash UInt32 little-endian (opaque chunk-group key)
//     1 byte:  totalChunks (1..255)
//     1 byte:  chunkIndex (0-based)
//     N bytes: chunk payload (raw JSON slice)

using System;
using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Security.Cryptography;

namespace RAVEN.Windows.Mesh;

public static class ChunkFramer
{
    /// <summary>
    /// Encode a payload as one or more BLE packets.
    /// </summary>
    /// <param name="payload">The full JSON bytes to send.</param>
    /// <param name="maxPacketSize">Per-packet size limit from BLE MTU negotiation.</param>
    /// <returns>One packet if it fits, otherwise multiple chunked packets.</returns>
    public static List<byte[]> EncodeForBle(byte[] payload, int maxPacketSize)
    {
        if (payload is null) throw new ArgumentNullException(nameof(payload));
        if (maxPacketSize < MeshConstants.MinChunkPayload + MeshConstants.ChunkHeaderSize + 1)
        {
            // Not enough room for a chunked packet — bump up.
            maxPacketSize = MeshConstants.MinChunkPayload + MeshConstants.ChunkHeaderSize + 1;
        }

        // If payload + 1 unchunked-flag fits in a single packet, send unchunked.
        if (payload.Length + 1 <= maxPacketSize)
        {
            var single = new byte[payload.Length + 1];
            single[0] = MeshConstants.ChunkFlagUnchunked;
            Buffer.BlockCopy(payload, 0, single, 1, payload.Length);
            return new List<byte[]>(1) { single };
        }

        // Chunked mode.
        var maxChunkPayload = maxPacketSize - 1 - MeshConstants.ChunkHeaderSize;
        var totalChunks = (int)Math.Ceiling(payload.Length / (double)maxChunkPayload);

        if (totalChunks > MeshConstants.MaxTotalChunks)
            throw new InvalidOperationException(
                $"Payload too large: needs {totalChunks} chunks, max is {MeshConstants.MaxTotalChunks}.");

        // Use first 4 bytes of SHA-256(payload) as the messageHash. Stable across
        // chunks of the same payload and across implementations (unlike Swift's
        // randomized Data.hashValue — see §I item 1). The receiver doesn't validate
        // this; it's only used as a chunk-group key.
        var hash = SHA256.HashData(payload);
        var messageHash = BinaryPrimitives.ReadUInt32LittleEndian(hash.AsSpan(0, 4));

        var packets = new List<byte[]>(totalChunks);
        for (int i = 0; i < totalChunks; i++)
        {
            var offset = i * maxChunkPayload;
            var size = Math.Min(maxChunkPayload, payload.Length - offset);
            var packet = new byte[1 + MeshConstants.ChunkHeaderSize + size];

            packet[0] = MeshConstants.ChunkFlagChunked;
            BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(1, 4), messageHash);
            packet[5] = (byte)totalChunks;
            packet[6] = (byte)i;
            Buffer.BlockCopy(payload, offset, packet, 1 + MeshConstants.ChunkHeaderSize, size);

            packets.Add(packet);
        }
        return packets;
    }

    /// <summary>
    /// Stateful reassembler. One instance per local node; tracks in-flight
    /// chunk groups across all peers.
    /// </summary>
    public sealed class Reassembler
    {
        private readonly ConcurrentDictionary<string, GroupState> _groups = new();
        private readonly TimeSpan _timeout = MeshConstants.ReassemblyTimeout;

        /// <summary>
        /// Feed a packet. Returns the fully-reassembled JSON payload when the last
        /// chunk arrives, or null while still waiting for more chunks.
        /// </summary>
        /// <param name="senderDeviceId">Sender's fingerprint (used for the group key).</param>
        /// <param name="packet">A raw BLE packet (with the leading flag byte).</param>
        public byte[]? Feed(string senderDeviceId, byte[] packet)
        {
            if (packet is null || packet.Length == 0) return null;

            var flag = packet[0];
            if (flag == MeshConstants.ChunkFlagUnchunked)
            {
                if (packet.Length < 2) return null;
                var payload = new byte[packet.Length - 1];
                Buffer.BlockCopy(packet, 1, payload, 0, payload.Length);
                return payload;
            }

            if (flag != MeshConstants.ChunkFlagChunked) return null;
            if (packet.Length < 1 + MeshConstants.ChunkHeaderSize) return null;

            var hash = BinaryPrimitives.ReadUInt32LittleEndian(packet.AsSpan(1, 4));
            int totalChunks = packet[5];
            int chunkIndex = packet[6];
            if (totalChunks == 0 || chunkIndex >= totalChunks) return null;

            var chunkPayload = new byte[packet.Length - 1 - MeshConstants.ChunkHeaderSize];
            Buffer.BlockCopy(packet, 1 + MeshConstants.ChunkHeaderSize, chunkPayload, 0, chunkPayload.Length);

            var groupKey = $"{senderDeviceId}-{hash}";
            var state = _groups.GetOrAdd(groupKey, _ => new GroupState(totalChunks));

            // Reset stale state (timeout).
            if (DateTime.UtcNow - state.CreatedAt > _timeout)
            {
                state = new GroupState(totalChunks);
                _groups[groupKey] = state;
            }

            state.Chunks[chunkIndex] = chunkPayload;
            state.ReceivedCount++;

            if (state.ReceivedCount < totalChunks) return null;

            // All chunks present — concatenate.
            var totalLen = 0;
            for (int i = 0; i < totalChunks; i++)
            {
                if (state.Chunks[i] is null) return null; // missing chunk
                totalLen += state.Chunks[i]!.Length;
            }
            var assembled = new byte[totalLen];
            var pos = 0;
            for (int i = 0; i < totalChunks; i++)
            {
                Buffer.BlockCopy(state.Chunks[i]!, 0, assembled, pos, state.Chunks[i]!.Length);
                pos += state.Chunks[i]!.Length;
            }

            _groups.TryRemove(groupKey, out _);
            return assembled;
        }

        /// <summary>Drop stale reassembly buffers. Call from a periodic 30s timer.</summary>
        public void GcStale()
        {
            var cutoff = DateTime.UtcNow - _timeout;
            foreach (var (key, state) in _groups)
            {
                if (state.CreatedAt < cutoff)
                    _groups.TryRemove(key, out _);
            }
        }

        private sealed class GroupState
        {
            public byte[]?[] Chunks { get; }
            public int ReceivedCount { get; set; }
            public DateTime CreatedAt { get; } = DateTime.UtcNow;

            public GroupState(int totalChunks)
            {
                Chunks = new byte[totalChunks][];
            }
        }
    }
}
