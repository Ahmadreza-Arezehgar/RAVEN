//
//  GHResponder.swift
//  RAVEN — Ghost Handshake
//
//  Responder-side: given a challenge from A and the per-pair
//  K_live, produce the MAC that A will verify. Also generates a
//  fresh `c_B` so the responder contributes randomness to the
//  transcript (defeats a malicious initiator who tries to lock
//  the responder into a transcript of their choosing).
//

import Foundation
import CryptoKit

/// One Ghost Handshake response. Carries `c_B` (responder's
/// fresh random) plus the MAC tag.
struct GHResponse: Sendable, Equatable, Hashable {
    /// 16-byte responder-chosen random value.
    let cB: Data
    /// 32-byte HMAC-SHA256 over the canonical input.
    let mac: Data
}

enum GHResponder {

    /// Produce a response for `challenge` using the pair's
    /// `kLive` key. Generates a fresh `c_B` via CSPRNG.
    ///
    /// `kLive` is the per-pair `K_live` sub-key from the ATSAM key
    /// tree (`ATSAMKeyTree.ghostHandshakeKey`).
    static func respond(toChallenge challenge: GHChallenge,
                        kLive: Data) throws -> GHResponse {
        guard kLive.count == 32 else {
            throw GHError.sizeMismatch(field: "kLive", expected: 32, got: kLive.count)
        }

        // Fresh c_B from CSPRNG.
        var cB = Data(count: GHConstants.challengeBytes)
        let status = cB.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, GHConstants.challengeBytes, base)
        }
        guard status == errSecSuccess else {
            throw GHError.randomFailure
        }

        let input = GHMACInput.canonicalBytes(
            role: .responder,
            challenge: challenge,
            cB: cB
        )
        let mac = HMAC<SHA256>.authenticationCode(
            for: input,
            using: SymmetricKey(data: kLive)
        )
        return GHResponse(cB: cB, mac: Data(mac))
    }
}
