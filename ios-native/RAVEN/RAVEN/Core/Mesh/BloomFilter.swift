// BloomFilter.swift
// RAVEN
//
// Compact Bloom filter for inventory exchange during mesh anti-entropy.
// Used to efficiently summarise which messages a peer already has.
//

import Foundation

/// Space-efficient probabilistic set for mesh inventory exchange
/// Uses k independent hash seeds via FNV-1a to keep implementation portable.
struct BloomFilter: Codable {
    
    // MARK: - Storage
    
    /// Bit array stored as bytes
    private(set) var bits: [UInt8]
    
    /// Number of bits in the filter
    let bitCount: Int
    
    /// Number of hash functions
    let hashCount: Int
    
    /// Number of items inserted
    private(set) var itemCount: Int = 0
    
    // MARK: - Init
    
    /// Create a Bloom filter sized for `expectedItems` at `falsePositiveRate`.
    /// Defaults: 1000 items at 1% FPR → ~1.2 KB.
    init(expectedItems: Int = 1000, falsePositiveRate: Double = 0.01) {
        // m = ceil(-(n * ln(p)) / (ln(2))^2)
        let n = Double(max(expectedItems, 1))
        let p = max(falsePositiveRate, 0.0001)
        let m = Int(ceil(-(n * log(p)) / pow(log(2), 2)))
        
        // k = ceil((m/n) * ln(2))
        let k = Int(ceil((Double(m) / n) * log(2)))
        
        self.bitCount = m
        self.hashCount = max(k, 1)
        self.bits = [UInt8](repeating: 0, count: (m + 7) / 8)
    }
    
    /// Create from raw components (for deserialization)
    init(bits: [UInt8], bitCount: Int, hashCount: Int, itemCount: Int) {
        self.bits = bits
        self.bitCount = bitCount
        self.hashCount = hashCount
        self.itemCount = itemCount
    }
    
    // MARK: - Insert
    
    /// Insert an item (typically a message ID string)
    mutating func insert(_ item: String) {
        let data = Data(item.utf8)
        for i in 0..<hashCount {
            let idx = hashIndex(data: data, seed: UInt32(i))
            setBit(idx)
        }
        itemCount += 1
    }
    
    // MARK: - Query
    
    /// Check if the filter might contain the item.
    /// Returns `false` → definitely NOT in set.
    /// Returns `true`  → probably in set (false positive possible).
    func mightContain(_ item: String) -> Bool {
        let data = Data(item.utf8)
        for i in 0..<hashCount {
            let idx = hashIndex(data: data, seed: UInt32(i))
            if !getBit(idx) { return false }
        }
        return true
    }
    
    // MARK: - Serialization
    
    /// Compact binary representation for BLE transmission
    func toData() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func fromData(_ data: Data) -> BloomFilter? {
        try? JSONDecoder().decode(BloomFilter.self, from: data)
    }
    
    // MARK: - Private
    
    /// FNV-1a hash with a seed, mapped to [0, bitCount)
    private func hashIndex(data: Data, seed: UInt32) -> Int {
        var hash: UInt64 = 14695981039346656037 &+ UInt64(seed) &* 6364136223846793005
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return Int(hash % UInt64(bitCount))
    }
    
    private mutating func setBit(_ index: Int) {
        let byteIndex = index / 8
        let bitIndex = index % 8
        bits[byteIndex] |= (1 << bitIndex)
    }
    
    private func getBit(_ index: Int) -> Bool {
        let byteIndex = index / 8
        let bitIndex = index % 8
        return (bits[byteIndex] & (1 << bitIndex)) != 0
    }
    
    // MARK: - CodingKeys
    
    enum CodingKeys: String, CodingKey {
        case bits = "b"
        case bitCount = "bc"
        case hashCount = "hc"
        case itemCount = "ic"
    }
    
    // MARK: - Safe Decoding (prevents Remote DoS via division-by-zero)
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bc = try container.decode(Int.self, forKey: .bitCount)
        let hc = try container.decode(Int.self, forKey: .hashCount)
        let bitsArray = try container.decode([UInt8].self, forKey: .bits)
        // Validate: bitCount & hashCount positive, bits array large enough to hold bitCount bits
        guard bc > 0, hc > 0, bitsArray.count * 8 >= bc else {
            throw DecodingError.dataCorruptedError(
                forKey: .bitCount,
                in: container,
                debugDescription: "Invalid Bloom filter: bitCount=\(bc), hashCount=\(hc), bits.count=\(bitsArray.count)"
            )
        }
        self.bitCount = bc
        self.hashCount = hc
        self.bits = bitsArray
        self.itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount) ?? 0
    }
}
