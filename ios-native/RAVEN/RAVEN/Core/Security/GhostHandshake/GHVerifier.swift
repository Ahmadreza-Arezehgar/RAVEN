//
//  GHVerifier.swift
//  RAVEN — Ghost Handshake
//
//  Verifier-side (initiator A): given the challenge A previously
//  sent, the response B returned, and the per-pair K_live, decide
//  if the response is valid.
//
//  Returns a discriminated outcome rather than a Bool so callers
//  can distinguish stale-challenge from MAC-mismatch in telemetry.
//

import Foundation
import CryptoKit

enum GHVerifier {

    /// Result of a verification attempt.
    enum Outcome: Sendable, Equatable {
        /// Response is valid; peer is verified live.
        case verifiedLive
        /// Response did not match the expected MAC.
        case mismatch
        /// Challenge was issued too long ago for the current epoch.
        case stale
    }

    /// Verify a response against the challenge A issued + the
    /// pair's K_live. Performs freshness check first (epoch
    /// distance), then the constant-time MAC compare.
    static func verify(challenge: GHChallenge,
                       response: GHResponse,
                       kLive: Data,
                       currentEpoch: UInt32) throws -> Outcome {
        guard kLive.count == 32 else {
            throw GHError.sizeMismatch(field: "kLive", expected: 32, got: kLive.count)
        }
        guard response.cB.count == GHConstants.challengeBytes else {
            throw GHError.sizeMismatch(field: "response.cB",
                                       expected: GHConstants.challengeBytes,
                                       got: response.cB.count)
        }
        guard response.mac.count == GHConstants.responseBytes else {
            throw GHError.sizeMismatch(field: "response.mac",
                                       expected: GHConstants.responseBytes,
                                       got: response.mac.count)
        }

        // 1. Freshness — reject before doing crypto work.
        let age = Int64(currentEpoch) - Int64(challenge.beaconEpoch)
        if age < 0 || age > Int64(GHConstants.acceptableChallengeAgeEpochs) {
            return .stale
        }

        // 2. Recompute expected MAC with role=.responder + the
        //    SAME canonical-input layout the responder used.
        let input = GHMACInput.canonicalBytes(
            role: .responder,
            challenge: challenge,
            cB: response.cB
        )
        let expected = HMAC<SHA256>.authenticationCode(
            for: input,
            using: SymmetricKey(data: kLive)
        )
        let expectedBytes = Data(expected)

        // 3. Constant-time compare.
        return constantTimeEqual(expectedBytes, response.mac) ? .verifiedLive : .mismatch
    }

    /// Reflection-attack defense smoke test. Returns true if
    /// the response was computed with role=.initiator (i.e. the
    /// attacker tried to reflect the challenger's own challenge
    /// back as a "response"). Production verifiers don't need to
    /// call this — the standard `verify(...)` rejects reflection
    /// automatically because it uses role=.responder. Exposed for
    /// tests + telemetry.
    static func looksLikeReflection(challenge: GHChallenge,
                                    response: GHResponse,
                                    kLive: Data) -> Bool {
        let initiatorInput = GHMACInput.canonicalBytes(
            role: .initiator,
            challenge: challenge,
            cB: response.cB
        )
        let initiatorMac = HMAC<SHA256>.authenticationCode(
            for: initiatorInput,
            using: SymmetricKey(data: kLive)
        )
        return constantTimeEqual(Data(initiatorMac), response.mac)
    }

    /// Constant-time byte comparison.
    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }
}
