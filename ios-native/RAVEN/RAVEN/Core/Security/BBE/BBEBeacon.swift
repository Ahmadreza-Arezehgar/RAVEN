//
//  BBEBeacon.swift
//  RAVEN — BBE
//
//  Beacon wire format and pure-data emit/parse. NO radio I/O — that
//  belongs to `BLEMeshEngine` / `WiFiAwareTransport` in Stage 3. This
//  file converts between a `BBEBeacon` Swift value and the canonical
//  byte sequence that travels over the air.
//
//  Wire layout (PDF §9, exact):
//
//      0     4    magic        "BBE1"
//      4     1    version       0x31
//      5     4    epoch t       UInt32 big-endian
//      9    16    nonce r       fresh per-beacon CSPRNG bytes
//     25   224    slot field    28 × 8-byte slots, CSPRNG-shuffled
//
//      Total: 249 bytes (fits a single BLE 5 AUX_ADV_IND payload).
//
//  Privacy property: real friend slots and random-padding slots
//  occupy positions in the same shuffled list, so a passive
//  observer cannot tell which positions matter even if they know
//  the protocol structure.
//

import Foundation

/// One parsed BBE beacon. Held in-memory as a Swift value so
/// callers don't need to manipulate raw bytes.
struct BBEBeacon: Equatable, Hashable, Sendable {

    /// Epoch number `t` this beacon was emitted for.
    let epoch: UInt32

    /// 16-byte beacon nonce `r`. Fresh per emission.
    let nonce: Data

    /// All 28 slot values in their shuffled wire order. A receiver
    /// MUST treat the order as opaque — slots are tested by
    /// membership, not by position.
    let slots: [Data]

    // MARK: - Build (sender side)

    /// Construct a beacon from the sender's real slots plus
    /// CSPRNG padding to fill to `slotsPerBeacon`. Throws if
    /// the caller supplied more real slots than fit.
    ///
    /// `realSlots` must each be exactly `slotBytes` long.
    static func build(epoch t: UInt32,
                      nonce: Data,
                      realSlots: [Data]) throws -> BBEBeacon {
        guard nonce.count == BBEConstants.beaconNonceBytes else {
            throw BBEError.internalInputError(reason: "build: nonce must be \(BBEConstants.beaconNonceBytes) B")
        }
        guard realSlots.count <= BBEConstants.slotsPerBeacon else {
            throw BBEError.internalInputError(reason: "build: too many real slots (\(realSlots.count) > \(BBEConstants.slotsPerBeacon))")
        }
        for (i, s) in realSlots.enumerated() {
            guard s.count == BBEConstants.slotBytes else {
                throw BBEError.internalInputError(reason: "build: real slot #\(i) must be \(BBEConstants.slotBytes) B")
            }
        }

        // Generate random padding to fill remaining positions.
        let paddingCount = BBEConstants.slotsPerBeacon - realSlots.count
        var allSlots: [Data] = []
        allSlots.reserveCapacity(BBEConstants.slotsPerBeacon)
        allSlots.append(contentsOf: realSlots)
        for _ in 0..<paddingCount {
            var pad = Data(count: BBEConstants.slotBytes)
            let status = pad.withUnsafeMutableBytes { ptr -> Int32 in
                guard let base = ptr.baseAddress else { return -1 }
                return SecRandomCopyBytes(kSecRandomDefault, BBEConstants.slotBytes, base)
            }
            guard status == errSecSuccess else {
                throw BBEError.internalInputError(reason: "build: SecRandomCopyBytes failed for padding slot")
            }
            allSlots.append(pad)
        }

        // CSPRNG Fisher-Yates shuffle. Don't use `Array.shuffled()` —
        // that uses `SystemRandomNumberGenerator`, which on iOS is
        // CSPRNG-backed but we want the explicit dependency in the
        // audit trail.
        var shuffled = allSlots
        for i in stride(from: shuffled.count - 1, to: 0, by: -1) {
            // Random integer in [0, i] using rejection sampling.
            let j = try cryptoRandomInt(upperBoundExclusive: UInt32(i + 1))
            shuffled.swapAt(i, Int(j))
        }

        return BBEBeacon(epoch: t, nonce: nonce, slots: shuffled)
    }

    // MARK: - Encode (to wire bytes)

    /// Canonical byte representation suitable for placing into a
    /// BLE AUX_ADV_IND payload or Wi-Fi Aware service-info field.
    func encode() -> Data {
        var out = Data()
        out.reserveCapacity(BBEConstants.beaconTotalBytes)

        out.append(contentsOf: BBEConstants.beaconMagic)         // 4 B
        out.append(BBEConstants.beaconVersion)                    // 1 B
        out.append(BBERatchet.uint32BE(epoch))                    // 4 B
        out.append(nonce)                                         // 16 B
        precondition(slots.count == BBEConstants.slotsPerBeacon,
                     "BBEBeacon.slots must contain exactly \(BBEConstants.slotsPerBeacon) entries")
        for s in slots {
            precondition(s.count == BBEConstants.slotBytes)
            out.append(s)
        }
        return out
    }

    // MARK: - Parse (from wire bytes)

    /// Returns true if the prefix bytes look like a BBE beacon. Cheap
    /// O(4) check for use in receive paths before allocating a full
    /// parse.
    static func looksLikeBeacon(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return Array(data.prefix(4)) == BBEConstants.beaconMagic
    }

    /// Parse the canonical byte layout into a `BBEBeacon`. Throws
    /// `notABeacon` on magic mismatch so callers can fall through
    /// to non-BBE processing without raising an alarm.
    static func parse(_ data: Data) throws -> BBEBeacon {
        guard data.count == BBEConstants.beaconTotalBytes else {
            if data.count >= 4,
               Array(data.prefix(4)) == BBEConstants.beaconMagic {
                throw BBEError.sizeMismatch(expected: BBEConstants.beaconTotalBytes, got: data.count)
            }
            throw BBEError.notABeacon
        }

        let magicBytes = Array(data.prefix(4))
        guard magicBytes == BBEConstants.beaconMagic else {
            throw BBEError.notABeacon
        }
        let version = data[data.startIndex + 4]
        guard version == BBEConstants.beaconVersion else {
            throw BBEError.unsupportedVersion(found: version)
        }

        // Helper that slices [start, start+length) into a fresh Data
        // so callers don't carry slice base-offsets around.
        func slice(_ start: Int, _ length: Int) -> Data {
            let s = data.startIndex + start
            return Data(data[s ..< (s + length)])
        }

        // Epoch.
        let epochBytes = slice(5, 4)
        let epoch = (UInt32(epochBytes[0]) << 24) |
                    (UInt32(epochBytes[1]) << 16) |
                    (UInt32(epochBytes[2]) <<  8) |
                     UInt32(epochBytes[3])

        // Nonce.
        let nonce = slice(9, BBEConstants.beaconNonceBytes)

        // Slot field.
        var slots: [Data] = []
        slots.reserveCapacity(BBEConstants.slotsPerBeacon)
        for i in 0..<BBEConstants.slotsPerBeacon {
            let offset = BBEConstants.slotsOffset + i * BBEConstants.slotBytes
            slots.append(slice(offset, BBEConstants.slotBytes))
        }

        return BBEBeacon(epoch: epoch, nonce: nonce, slots: slots)
    }
}

// MARK: - CSPRNG helpers

/// Rejection-sampled uniform integer in [0, upperBoundExclusive).
/// Avoids the modulo bias that plain `% n` would introduce.
private func cryptoRandomInt(upperBoundExclusive bound: UInt32) throws -> UInt32 {
    guard bound > 0 else {
        throw BBEError.internalInputError(reason: "cryptoRandomInt: bound must be > 0")
    }
    // Largest multiple of `bound` <= UInt32.max
    let limit = UInt32.max - (UInt32.max % bound)
    while true {
        var rndBytes = Data(count: 4)
        let status = rndBytes.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, 4, base)
        }
        guard status == errSecSuccess else {
            throw BBEError.internalInputError(reason: "cryptoRandomInt: SecRandomCopyBytes failed")
        }
        let rnd = (UInt32(rndBytes[0]) << 24) |
                  (UInt32(rndBytes[1]) << 16) |
                  (UInt32(rndBytes[2]) <<  8) |
                   UInt32(rndBytes[3])
        if rnd < limit {
            return rnd % bound
        }
        // Else loop — bias-free rejection.
    }
}
