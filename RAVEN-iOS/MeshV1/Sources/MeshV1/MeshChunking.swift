// `MESH_PROTOCOL.md` §B — GATT chunk encoder + reassembler.
//
// Wire format:
//   flag(1)  rest...
//   0x00     <JSON bytes as-is>                                    -- unchunked
//   0x01     hash(4 LE) totalChunks(1) chunkIndex(1) payload(N)    -- chunked
//
// §I.1 — `messageHash` is sender-chosen and opaque to receivers (only used as
// a chunk-group key). Picking a deterministic 32-bit value (e.g. CRC32 of
// payload) gives stable per-sender keying without leaking entropy.
import Foundation

public enum Chunking {

    /// `[0x00] + jsonBytes`.
    public static func encodeUnchunked(_ json: Data) -> Data {
        var out = Data(capacity: json.count + 1)
        out.append(MeshConstants.chunkFlagUnchunked)
        out.append(json)
        return out
    }

    /// Chunked encoder. `chunkPayloadSize` is the bytes per chunk's PAYLOAD
    /// portion (NOT including the 1+6 header). Caller computes from the
    /// negotiated MTU.
    public static func encodeChunked(_ json: Data, chunkPayloadSize: Int, messageHash: UInt32) -> [Data] {
        precondition(chunkPayloadSize >= 1, "chunkPayloadSize must be >= 1")
        let total = min((json.count + chunkPayloadSize - 1) / chunkPayloadSize, MeshConstants.maxTotalChunks)
        precondition(total * chunkPayloadSize >= json.count, "payload doesn't fit in chunks")
        var packets: [Data] = []
        packets.reserveCapacity(total)
        for i in 0..<total {
            let start = i * chunkPayloadSize
            let end = min(start + chunkPayloadSize, json.count)
            var packet = Data(capacity: 1 + MeshConstants.chunkHeaderSize + (end - start))
            packet.append(MeshConstants.chunkFlagChunked)
            // hash little-endian
            var le = messageHash.littleEndian
            withUnsafeBytes(of: &le) { packet.append(contentsOf: $0) }
            packet.append(UInt8(total))
            packet.append(UInt8(i))
            packet.append(json.subdata(in: start..<end))
            packets.append(packet)
        }
        return packets
    }

    /// CRC32 of payload — stable per-sender chunk-group key. Matches Kotlin
    /// `java.util.zip.CRC32` so platforms agree on the value.
    public static func deriveMessageHash(_ payload: Data) -> UInt32 {
        // Standard CRC-32 (IEEE 802.3), polynomial 0xEDB88320 (reversed).
        var crc: UInt32 = 0xFFFFFFFF
        for byte in payload {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(0) &- (crc & 1)
                crc = (crc >> 1) ^ (0xEDB88320 & mask)
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    public struct ChunkHeader: Equatable {
        public let messageHash: UInt32
        public let totalChunks: Int
        public let chunkIndex: Int
    }

    public enum Decoded {
        case unchunked(Data)
        case chunk(ChunkHeader, Data)
    }

    public static func decode(_ packet: Data) -> Decoded {
        precondition(!packet.isEmpty, "empty packet")
        let flag = packet[packet.startIndex]
        if flag == MeshConstants.chunkFlagUnchunked {
            return .unchunked(packet.subdata(in: (packet.startIndex + 1)..<packet.endIndex))
        }
        precondition(flag == MeshConstants.chunkFlagChunked, "unknown chunk flag")
        precondition(packet.count >= 1 + MeshConstants.chunkHeaderSize, "chunk too short")
        let base = packet.startIndex
        let hash = packet.subdata(in: (base + 1)..<(base + 5)).withUnsafeBytes { buf -> UInt32 in
            // little-endian decode without alignment assumptions
            var v: UInt32 = 0
            for i in 0..<4 {
                v |= UInt32(buf[i]) << (8 * i)
            }
            return v
        }
        let total = Int(packet[base + 5])
        let index = Int(packet[base + 6])
        let payload = packet.subdata(in: (base + 7)..<packet.endIndex)
        return .chunk(ChunkHeader(messageHash: hash, totalChunks: total, chunkIndex: index), payload)
    }
}

/// Reassembles chunked GATT packets per (sender, messageHash). Stale buffers
/// are GC'd after `MeshConstants.reassemblyGcSeconds`. Caller drives `tick()`.
public final class ChunkReassembler {

    private final class Entry {
        let total: Int
        var parts: [Data?]
        var arrived: Int
        var firstSeenAt: TimeInterval
        init(total: Int, firstSeenAt: TimeInterval) {
            self.total = total
            self.parts = Array(repeating: nil, count: total)
            self.arrived = 0
            self.firstSeenAt = firstSeenAt
        }
    }

    private var buffers: [String: Entry] = [:]
    // Insertion-order tracker so we can evict oldest when over the max.
    private var insertionOrder: [String] = []
    private let now: () -> TimeInterval

    public init(now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.now = now
    }

    /// Returns the fully reassembled JSON when this chunk completes the
    /// message; `nil` otherwise.
    public func accept(senderDeviceId: String, header: Chunking.ChunkHeader, payload: Data) -> Data? {
        let key = "\(senderDeviceId)-\(header.messageHash)"
        let entry: Entry
        if let existing = buffers[key] {
            entry = existing
        } else {
            entry = Entry(total: header.totalChunks, firstSeenAt: now())
            buffers[key] = entry
            insertionOrder.append(key)
        }
        if header.totalChunks != entry.total { return nil }
        guard header.chunkIndex >= 0 && header.chunkIndex < entry.total else { return nil }
        if entry.parts[header.chunkIndex] != nil { return nil } // duplicate
        entry.parts[header.chunkIndex] = payload
        entry.arrived += 1
        guard entry.arrived == entry.total else { return nil }

        var out = Data()
        for p in entry.parts {
            guard let p else { return nil }
            out.append(p)
        }
        buffers.removeValue(forKey: key)
        if let idx = insertionOrder.firstIndex(of: key) {
            insertionOrder.remove(at: idx)
        }
        evictExcess()
        return out
    }

    /// Drop reassembly buffers older than `reassemblyGcSeconds`.
    public func tick() {
        let cutoff = now() - MeshConstants.reassemblyGcSeconds
        let keys = insertionOrder
        for key in keys {
            if let e = buffers[key], e.firstSeenAt < cutoff {
                buffers.removeValue(forKey: key)
                if let idx = insertionOrder.firstIndex(of: key) {
                    insertionOrder.remove(at: idx)
                }
            }
        }
    }

    private func evictExcess() {
        while buffers.count > MeshConstants.maxPendingHashKeys, let oldest = insertionOrder.first {
            buffers.removeValue(forKey: oldest)
            insertionOrder.removeFirst()
        }
    }
}
