//
//  PVStealthLookupTag.swift
//  RAVEN — PROXIMA-VAULT Stealth
//
//  Lookup-tag derivation:
//
//      K_lookup^{dir} := HKDF-Expand(K_lookup_parent,
//                                    direction_label,
//                                    L = 32)
//      lookup_tag    := Trunc_128(HMAC-SHA256(K_lookup^{dir},
//                                             domain || lookup_nonce
//                                             || uint32_be(counter)))
//
//  Both ends derive the SAME tag for the SAME (direction, nonce,
//  counter) tuple because they share the K_lookup parent key from
//  the ATSAM key tree. Per-direction sub-key separation matches
//  the rest of PV (Patch 5/9).
//

import Foundation
import CryptoKit

enum PVStealthLookupTag {

    // MARK: - Per-direction key derivation

    /// Derive K_lookup^{forward} from the parent K_lookup. Receivers
    /// MUST cache this per-pair to avoid re-deriving on every
    /// envelope scan (HKDF is ~6 µs but compounds at M × window).
    static func directionalKey(parentKey kLookup: Data,
                               direction: PVDirection) throws -> Data {
        guard kLookup.count == 32 else {
            throw PVStealthError.internalInputError(reason: "kLookup must be 32 B")
        }
        let info: Data
        switch direction {
        case .forward: info = PVStealthConstants.directionLabelForward
        case .reverse: info = PVStealthConstants.directionLabelReverse
        }
        let derived = HKDF<SHA256>.expand(
            pseudoRandomKey: SymmetricKey(data: kLookup),
            info: info,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    // MARK: - Tag computation

    /// Compute the lookup tag for a given (kDir, lookupNonce, counter)
    /// triple.
    static func compute(directionalKey kDir: Data,
                        lookupNonce: Data,
                        counter: UInt32) throws -> Data {
        guard kDir.count == 32 else {
            throw PVStealthError.internalInputError(reason: "directionalKey must be 32 B")
        }
        guard lookupNonce.count == PVStealthConstants.lookupNonceBytes else {
            throw PVStealthError.internalInputError(reason: "lookupNonce must be \(PVStealthConstants.lookupNonceBytes) B")
        }

        var input = Data(capacity:
            PVStealthConstants.lookupTagDomain.count
            + PVStealthConstants.lookupNonceBytes
            + 4
        )
        input.append(PVStealthConstants.lookupTagDomain)
        input.append(lookupNonce)
        input.append(contentsOf: uint32BE(counter))

        let mac = HMAC<SHA256>.authenticationCode(
            for: input,
            using: SymmetricKey(data: kDir)
        )
        let macBytes = Data(mac)
        return macBytes.prefix(PVStealthConstants.lookupTagBytes)
    }

    /// Constant-time tag equality.
    static func tagsEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    // MARK: - Private helpers

    private static func uint32BE(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8)  & 0xFF),
            UInt8(value & 0xFF),
        ]
    }
}
