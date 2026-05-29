//
//  BBERatchet.swift
//  RAVEN — BBE
//
//  Per-epoch ratcheting of the BBE discovery key and the catch-up
//  cache. Each conversation pair has its own ratchet state.
//
//  Ratchet recurrence (PDF §10):
//
//      K_BBE^(t+1) = HKDF-Expand(K_BBE^(t),
//                                info = "ATSAM/BBE/ratchet" || uint32(t+1),
//                                L = 32)
//
//  Forward-secrecy property: once `K_BBE^(t)` is wiped, no future
//  state compromise reveals the slot values that were emitted at
//  epoch t. This protects historical beacon emissions from "I stole
//  your phone today, now show me where you were last week" attacks.
//
//  Catch-up cache (PDF §10): we keep the last `catchUpWindow` ratchet
//  states in memory so a peer who missed up to that many epochs (e.g.
//  due to BLE outage, plane mode) can still be detected. Beyond that
//  the pair MUST re-pair OOB — silently extending the cache would
//  let an attacker pin the victim's clock.
//

import Foundation
import CryptoKit

/// Per-pair ratchet state. Holds the current `K_BBE^(t)` plus
/// up to `BBEConstants.catchUpWindow` prior states for receive-side
/// catch-up. Sendable so it can move between actors.
struct BBERatchetState: Sendable, Equatable {

    /// Pairing identifier (stable across epochs). 16 bytes.
    /// Typically `SHA256(K_pair_master).prefix(16)` so the
    /// identifier itself reveals nothing about either party's
    /// long-term keys.
    let pairingId: Data

    /// Current epoch number `t`.
    var epoch: UInt32

    /// Current per-epoch discovery key `K_BBE^(t)`. 32 bytes.
    var currentKey: Data

    /// Past discovery keys, indexed by absolute epoch number. Held
    /// only for the most recent `catchUpWindow` epochs; older keys
    /// are wiped on advance.
    var pastKeys: [UInt32: Data]

    /// Best-effort zeroize for stored key bytes. Called when a pair
    /// is deleted / re-paired so leftover Data buffers don't sit
    /// in memory longer than necessary.
    mutating func consumingZeroize() {
        currentKey.withUnsafeMutableBytes { buf in
            for i in 0..<buf.count { buf[i] = 0xFF }
            for i in 0..<buf.count { buf[i] = 0x00 }
        }
        currentKey = Data()
        for (k, var v) in pastKeys {
            v.withUnsafeMutableBytes { buf in
                for i in 0..<buf.count { buf[i] = 0xFF }
                for i in 0..<buf.count { buf[i] = 0x00 }
            }
            pastKeys[k] = nil
            _ = v
        }
    }
}

/// Stateless ratchet primitive — pure functions over the state
/// struct so it's easy to test and easy to persist.
enum BBERatchet {

    /// Initialise a fresh ratchet from the per-pair `K_BBE` (sub-key
    /// derived from the ATSAM key tree). The starting epoch `t` is
    /// usually `currentEpochFromClock()` — bootstrapping mid-stream
    /// is fine because both peers do the same thing.
    static func initial(pairingId: Data,
                        kBBE: Data,
                        startEpoch: UInt32) throws -> BBERatchetState {
        guard pairingId.count == 16 else {
            throw BBEError.internalInputError(reason: "pairingId must be 16 B")
        }
        guard kBBE.count == 32 else {
            throw BBEError.internalInputError(reason: "kBBE must be 32 B")
        }
        // K_BBE^(start) = HKDF(K_BBE, info = ratchetInfo || uint32(start), 32)
        let initialKey = try ratchetKey(previousKey: kBBE, toEpoch: startEpoch)
        return BBERatchetState(
            pairingId: pairingId,
            epoch: startEpoch,
            currentKey: initialKey,
            pastKeys: [:]
        )
    }

    /// Advance the ratchet by `n` epochs. Pushes the current key
    /// into `pastKeys`, computes `K_BBE^(t+1)`, ..., `K_BBE^(t+n)`,
    /// and trims `pastKeys` to the last `catchUpWindow` entries.
    static func advance(state: BBERatchetState, toEpoch target: UInt32) throws -> BBERatchetState {
        guard target >= state.epoch else {
            // Trying to go backward — caller bug. The catch-up
            // window handles delayed beacons via lookup, not via
            // ratchet-rewind.
            return state
        }
        var working = state

        while working.epoch < target {
            let nextEpoch = working.epoch &+ 1
            // Stash the current key as a past state for catch-up.
            working.pastKeys[working.epoch] = working.currentKey
            // Derive next key.
            working.currentKey = try ratchetKey(previousKey: working.currentKey,
                                               toEpoch: nextEpoch)
            working.epoch = nextEpoch
        }

        // Trim past keys to the catch-up window.
        let oldestKept = Int64(working.epoch) - Int64(BBEConstants.catchUpWindow)
        if oldestKept > 0 {
            let cutoff = UInt32(oldestKept)
            working.pastKeys = working.pastKeys.filter { $0.key >= cutoff }
        }

        return working
    }

    /// Returns the cached key for an epoch within the catch-up
    /// window, or `nil` if the epoch is outside the window.
    /// Convenience for receiver-side detect.
    static func cachedKey(state: BBERatchetState, forEpoch t: UInt32) -> Data? {
        if t == state.epoch { return state.currentKey }
        return state.pastKeys[t]
    }

    // MARK: - Pure HKDF step

    /// `K_BBE^(t+1) = HKDF-Expand(K_BBE^(t),
    ///                            info = ratchetInfo || uint32(t+1),
    ///                            L = 32)`
    static func ratchetKey(previousKey: Data, toEpoch nextEpoch: UInt32) throws -> Data {
        guard previousKey.count == 32 else {
            throw BBEError.internalInputError(reason: "ratchetKey: previousKey must be 32 B")
        }
        var info = Data(capacity: BBEConstants.ratchetInfo.count + 4)
        info.append(BBEConstants.ratchetInfo)
        info.append(uint32BE(nextEpoch))

        let derived = HKDF<SHA256>.expand(
            pseudoRandomKey: SymmetricKey(data: previousKey),
            info: info,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    // MARK: - Helpers

    /// Compute the current epoch from the wall clock. Both peers
    /// MUST source `unix_time_utc` from an NTP-synced clock or a
    /// recent peer-bound timestamp (PDF §3); without that, BBE is
    /// disabled at the policy layer.
    static func currentEpochFromClock() -> UInt32 {
        let now = Date().timeIntervalSince1970
        return UInt32(now / BBEConstants.epochSeconds)
    }

    /// Big-endian UInt32 → 4 bytes.
    static func uint32BE(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8)  & 0xFF),
            UInt8(value & 0xFF),
        ])
    }
}
