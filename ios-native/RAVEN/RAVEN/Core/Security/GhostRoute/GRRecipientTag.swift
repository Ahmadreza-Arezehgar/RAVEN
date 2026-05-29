//
//  GRRecipientTag.swift
//  RAVEN — Ghost Route
//
//  Per-message recipient-tag derivation.
//
//      recipient_tag(K_route, n_msg) =
//          Trunc_128(HMAC-SHA256(K_route,
//                                "ATSAM/v1/GhostRoute/recipient" || n_msg))
//
//  Both A (sender) and B (receiver) compute the same value because
//  they share K_route from the ATSAM key tree. To a relay or any
//  third party without K_route, the tag is computationally
//  indistinguishable from a uniform random 128-bit string.
//

import Foundation
import CryptoKit

enum GRRecipientTag {

    /// Compute the recipient_tag for (kRoute, nonce).
    static func compute(kRoute: Data, nonce: Data) throws -> Data {
        guard kRoute.count == 32 else {
            throw GRError.internalInputError(reason: "kRoute must be 32 B")
        }
        guard nonce.count == GRConstants.nonceBytes else {
            throw GRError.internalInputError(reason: "nonce must be \(GRConstants.nonceBytes) B")
        }

        var input = Data(capacity: GRConstants.recipientTagDomain.count + nonce.count)
        input.append(GRConstants.recipientTagDomain)
        input.append(nonce)

        let mac = HMAC<SHA256>.authenticationCode(
            for: input,
            using: SymmetricKey(data: kRoute)
        )
        let macBytes = Data(mac)
        return macBytes.prefix(GRConstants.recipientTagBytes)
    }

    /// Constant-time equality check. Use this for receiver-side
    /// matching to avoid timing side-channels that would leak
    /// which pairing matched.
    static func tagsEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }
}
