//
//  BBEPartition.swift
//  RAVEN — BBE (Stage 3)
//
//  Sequential stable-sort partitioning for BBE friend-to-beacon
//  assignment. Solves the v3 random-bucket overflow problem:
//
//      Bad random-bucket model (v3):
//          n_A = 1000 friends randomly placed into 36 buckets of
//          capacity N = 28. Expected max load:
//              n/m + sqrt(2(n/m)·ln(m)) ≈ 27.8 + 14.1 ≈ 42
//          Since 42 > 28, overflow is expected ⇒ some friends are
//          silently undiscoverable.
//
//      Stable sequential assignment (v3.1, this file):
//          Compute a stable sort key per (A, B_i) pair, sort all
//          friends by that key, then chunk into groups of size N.
//          Number of beacons per epoch: m_A = ceil(n_A / N).
//          Guarantee: every bucket has at most N entries by
//          construction. NO overflow possible.
//
//  Why a "stable" sort key:
//    • Both A and B independently compute the same sort_key for
//      their pair (it's derived from the per-pair K_root via HKDF),
//      so they agree on which partition holds them without
//      coordination.
//    • The key is constant across epochs (NOT ratcheted), so a
//      friend's partition does not change unless the friend set
//      changes. Stable bucketing = predictable receiver-side
//      detection cost.
//    • Across epochs, the order INSIDE each beacon is randomised
//      via the existing Fisher-Yates shuffle in `BBEBeacon.build`,
//      so observers cannot read the partition index from slot
//      position.
//
//  Reference: ATSAM PDF §11 (BBE Partitioning without Bucket
//  Overflow), and our v3.1 patch's m1 fix.
//

import Foundation
import CryptoKit

/// One paired friend as seen from A's side. Carries the per-pair
/// root key derived from the ATSAM key tree, which is what feeds
/// the stable sort key computation.
struct BBEPairedFriend: Sendable, Equatable, Hashable {

    /// Stable identifier for the pairing (16 B). Typically
    /// `SHA256(K_pair_master).prefix(16)`, but the partitioning
    /// algorithm treats it as opaque. Used only for the result
    /// API so callers can map back to their local friend record.
    let pairingId: Data

    /// Per-pair root key K_root^{A,B_i}. 32 bytes. Produced by
    /// `ATSAMHybridPairing.pairAsInitiator/Responder().root`.
    /// Treated as opaque secret here; the partitioner only uses
    /// it to derive a stable sort key.
    let kRoot: Data
}

/// One result partition: an ordered list of pairings, all of
/// which the sender will emit together as ONE BBE beacon
/// (containing up to `slotsPerBeacon` slots).
struct BBEPartitionGroup: Sendable, Equatable {
    /// Index of this partition within the epoch (0-based).
    let index: Int
    /// Pairings assigned to this partition. Guaranteed
    /// `≤ BBEConstants.slotsPerBeacon` entries.
    let members: [BBEPairedFriend]
}

enum BBEPartition {

    // MARK: - Sort-key derivation

    /// Compute the per-pair stable sort key.
    ///
    ///     pair_master = HKDF(K_root^{A,B_i},
    ///                       info = "ATSAM/BBE/pair-master",
    ///                       L = 32)
    ///     sort_key   = HMAC(pair_master,
    ///                       "ATSAM/BBE/stable-partition-sort")
    ///                  truncated to 8 bytes
    ///
    /// Both A and B independently compute the same value because
    /// they share `K_root` (correctness of ATSAM pairing) and use
    /// the same labels.
    static func sortKey(forPairing pairing: BBEPairedFriend) throws -> Data {
        guard pairing.kRoot.count == 32 else {
            throw BBEError.internalInputError(reason: "sortKey: kRoot must be 32 B")
        }

        // pair_master = HKDF-Expand(K_root, info = "ATSAM/BBE/pair-master", L = 32)
        let pairMasterInfo = Data(ATSAMConstants.KDFLabel.bbePairMaster.bytes)
        let pairMaster = HKDF<SHA256>.expand(
            pseudoRandomKey: SymmetricKey(data: pairing.kRoot),
            info: pairMasterInfo,
            outputByteCount: 32
        )

        // sort_key = HMAC(pair_master, "ATSAM/BBE/stable-partition-sort")
        let sortInput = Data(ATSAMConstants.KDFLabel.bbeStablePartitionSort.bytes)
        let mac = HMAC<SHA256>.authenticationCode(for: sortInput, using: pairMaster)
        let macBytes = Data(mac)

        // Truncate to 8 bytes for the sort comparator. 64 bits is
        // far more than enough to make accidental ties astronomically
        // rare (~2^-32 collision over 65k friends).
        return macBytes.prefix(8)
    }

    // MARK: - Partition assignment

    /// Partition `friends` into ≤ `BBEConstants.slotsPerBeacon`
    /// groups per partition. Returns the partitions in their
    /// canonical order (partition 0 first).
    ///
    /// Properties guaranteed by construction:
    ///   1. No partition exceeds `slotsPerBeacon` members
    ///      (no overflow, no silent undiscoverability).
    ///   2. The same friend lands in the same partition each
    ///      call (deterministic).
    ///   3. Both A and B compute identical partitions for any
    ///      pairing they share (correctness over the key tree).
    ///
    /// Lexicographic tie-breaker on `pairingId` if two `sort_key`
    /// values collide. With 64-bit keys + UInt8 byte comparison
    /// on pairingId, ties are astronomically rare but defined.
    static func partition(friends: [BBEPairedFriend]) throws -> [BBEPartitionGroup] {
        if friends.isEmpty { return [] }

        // 1. Derive sort keys.
        let keyed: [(friend: BBEPairedFriend, sortKey: Data)] = try friends.map {
            (friend: $0, sortKey: try sortKey(forPairing: $0))
        }

        // 2. Stable sort by sort_key; ties broken by pairingId.
        let sorted = keyed.sorted { lhs, rhs in
            // Compare sort_keys lexicographically (8 bytes).
            if lhs.sortKey != rhs.sortKey {
                return BBEPartition.lexLess(lhs.sortKey, rhs.sortKey)
            }
            // Tie-break by pairingId.
            return BBEPartition.lexLess(lhs.friend.pairingId, rhs.friend.pairingId)
        }

        // 3. Chunk into groups of size N = slotsPerBeacon.
        let n = BBEConstants.slotsPerBeacon
        var groups: [BBEPartitionGroup] = []
        groups.reserveCapacity((sorted.count + n - 1) / n)
        for (groupIdx, chunkStart) in stride(from: 0, to: sorted.count, by: n).enumerated() {
            let chunkEnd = Swift.min(chunkStart + n, sorted.count)
            let members = sorted[chunkStart..<chunkEnd].map { $0.friend }
            groups.append(BBEPartitionGroup(index: groupIdx, members: members))
        }

        return groups
    }

    /// Per-epoch beacon count: `m_A = ceil(n_A / N)`.
    /// Convenience for capacity planning + receiver duty-cycle
    /// estimates.
    static func beaconsPerEpoch(friendCount n_A: Int) -> Int {
        guard n_A > 0 else { return 0 }
        let n = BBEConstants.slotsPerBeacon
        return (n_A + n - 1) / n
    }

    // MARK: - Helpers

    /// Lexicographic less-than on `Data`. Byte-by-byte, shorter
    /// string wins on prefix equality. Used only for tie-breaking
    /// — not on the security-critical path.
    private static func lexLess(_ a: Data, _ b: Data) -> Bool {
        let aBytes = [UInt8](a)
        let bBytes = [UInt8](b)
        let minLen = Swift.min(aBytes.count, bBytes.count)
        for i in 0..<minLen {
            if aBytes[i] != bBytes[i] {
                return aBytes[i] < bBytes[i]
            }
        }
        return aBytes.count < bBytes.count
    }
}
