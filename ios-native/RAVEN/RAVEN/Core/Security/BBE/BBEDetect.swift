//
//  BBEDetect.swift
//  RAVEN — BBE
//
//  Receiver-side: given a parsed beacon plus the local set of active
//  pairings, decide which (if any) of "my friends" emitted it.
//
//  PDF §14 / §15 important reminder: a BBE hit is a CANDIDATE event,
//  NOT a verified-friend event. Ghost Handshake (Stage 4) issues a
//  fresh challenge-response MAC on top before the UI says "Alice is
//  nearby". This file therefore returns a `BBECandidate` value — the
//  word "candidate" is intentional and load-bearing.
//

import Foundation

/// One detected candidate. The pair-id identifies WHICH local
/// pairing matched; `BBECandidate` does NOT carry the friend's
/// real name, phone, or username — those come from a separate
/// directory lookup AFTER Ghost Handshake confirms liveness.
struct BBECandidate: Sendable, Equatable, Hashable {
    /// The pairing this beacon matched (stable across epochs).
    let pairingId: Data

    /// The epoch the matching slot was derived for. May be
    /// `current epoch` or any of the catch-up epochs in scope.
    let matchedEpoch: UInt32

    /// Convenience: nonce from the inbound beacon, for downstream
    /// Ghost Handshake binding.
    let beaconNonce: Data
}

enum BBEDetect {

    /// Try to identify a matching pairing for `beacon`. Iterates
    /// over all active ratchet states + their catch-up windows,
    /// computes the expected slot in each (epoch, K_BBE) tuple,
    /// and returns every match found.
    ///
    /// Returns an empty array if nothing matches (this is the
    /// COMMON case — most BBE beacons we hear in radio range
    /// belong to strangers and will not match any of our pairings).
    ///
    /// Cost per beacon: `O(M · catchUpWindow · slotsPerBeacon)` HMAC
    /// operations. With M=1000 pairings, 12 epochs, 28 slots ≈
    /// 336 000 HMACs/beacon. Each HMAC is ~6 µs on A17 ⇒ 2 s per
    /// beacon. PER-BEACON. Excessive.
    ///
    /// REAL receivers MUST do at most one HMAC per (pairing, epoch)
    /// — see `match()` below which does this correctly: compute the
    /// pairing's expected slot ONCE, then membership-test against
    /// the beacon's slot set. Cost: M · catchUpWindow · slot-compute.
    /// At 1000 · 12 ≈ 12 000 HMACs ≈ 72 ms per beacon — acceptable.
    static func detect(beacon: BBEBeacon,
                       activePairings: [BBERatchetState],
                       currentLocalEpoch: UInt32) throws -> [BBECandidate] {
        guard !activePairings.isEmpty else {
            // Allowed to be empty — receiver might have no friends
            // paired yet. Surface so caller can short-circuit.
            return []
        }

        // Reject beacons outside our clock-skew window before doing
        // any HMAC work.
        let lowestAcceptable = (currentLocalEpoch >= UInt32(BBEConstants.clockSkewWindowPast))
            ? currentLocalEpoch - UInt32(BBEConstants.clockSkewWindowPast)
            : 0
        let highestAcceptable = currentLocalEpoch &+ UInt32(BBEConstants.clockSkewWindowFuture)
        guard beacon.epoch >= lowestAcceptable && beacon.epoch <= highestAcceptable else {
            // Window check is informational at receive time — we
            // *could* still try matching against the catch-up cache.
            // Per ATSAM §3, we hard-drop beacons more than
            // `clockSkewWindowPast` epochs old to defeat long-buffer
            // replay.
            throw BBEError.epochOutOfWindow(beacon: beacon.epoch, local: currentLocalEpoch)
        }

        // Build a fast lookup set of the beacon's slots. O(N) build,
        // O(1) membership test. Slot-equality is constant-time per
        // entry, but we use Set hashing for the bulk filter and only
        // confirm with constant-time equality for the rare hit case.
        let beaconSlotSet: Set<Data> = Set(beacon.slots)

        var candidates: [BBECandidate] = []
        candidates.reserveCapacity(2)  // most beacons match 0 or 1 pairings

        for state in activePairings {
            // Try the beacon's claimed epoch against this pairing's
            // current key first (the common case), then walk the
            // catch-up cache if there's a window mismatch.
            if let expected = try slotFor(state: state,
                                          epoch: beacon.epoch,
                                          nonce: beacon.nonce) {
                if beaconSlotSet.contains(expected) {
                    candidates.append(BBECandidate(
                        pairingId: state.pairingId,
                        matchedEpoch: beacon.epoch,
                        beaconNonce: beacon.nonce
                    ))
                }
            }
        }

        return candidates
    }

    /// Helper: compute the slot a given ratchet state would emit
    /// for a (epoch, nonce). Returns nil if the epoch is outside
    /// the state's cache.
    private static func slotFor(state: BBERatchetState,
                                epoch: UInt32,
                                nonce: Data) throws -> Data? {
        // Locate the right K_BBE^(epoch). Either current, or in
        // the catch-up cache.
        let key: Data?
        if epoch == state.epoch {
            key = state.currentKey
        } else {
            key = state.pastKeys[epoch]
        }
        guard let kBBE = key else {
            return nil
        }
        return try BBESlot.slot(epochKey: kBBE, epoch: epoch, nonce: nonce)
    }
}
