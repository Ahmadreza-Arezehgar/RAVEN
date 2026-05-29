//
//  GHErrors.swift
//  RAVEN — Ghost Handshake
//

import Foundation

enum GHError: Error, Equatable {

    /// Verifier rejected the response. Either the K_live mismatched
    /// (wrong peer / wrong pair), the role byte was off (reflection
    /// attempt), or the transcript bytes did not match what the
    /// challenger signed.
    case verificationFailed

    /// The challenge was issued for an epoch outside the
    /// acceptable freshness window (see
    /// `GHConstants.acceptableChallengeAgeEpochs`). Drop the
    /// response without verifying it.
    case challengeStale(challengeEpoch: UInt32, current: UInt32)

    /// An input field is the wrong size.
    case sizeMismatch(field: String, expected: Int, got: Int)

    /// CSPRNG failed at challenge-generation time.
    case randomFailure
}
