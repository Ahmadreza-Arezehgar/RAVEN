//
//  GHChallenge.swift
//  RAVEN — Ghost Handshake
//
//  Pure-data primitives: challenge struct + canonical MAC input
//  byte sequence. No I/O, no transport coupling.
//

import Foundation
import CryptoKit

/// One Ghost Handshake challenge issued by the initiator (A) to a
/// candidate peer (B). Carries the random `c_A`, the BBE beacon
/// context this is being issued against (epoch t and nonce r),
/// and an optional `transcript_hash` that binds the handshake to
/// the ATSAM pairing transcript.
///
/// Values are CARRIED PLAINTEXT on the wire (the security comes
/// from the responder needing K_live to compute a valid MAC over
/// these exact bytes, NOT from hiding them).
struct GHChallenge: Sendable, Equatable, Hashable {

    /// 16-byte challenger-chosen random value.
    let cA: Data

    /// BBE epoch t at which the original detection happened.
    let beaconEpoch: UInt32

    /// 16-byte nonce r from the original BBE beacon.
    let beaconNonce: Data

    /// 32-byte transcript hash binding this handshake to the
    /// pairing transcript. Strongly recommended (defeats relay
    /// attacks across distinct deployment contexts).
    let transcriptHash: Data

    // MARK: - Construction

    /// Generate a fresh challenge from CSPRNG bytes.
    static func generate(beaconEpoch: UInt32,
                         beaconNonce: Data,
                         transcriptHash: Data) throws -> GHChallenge {
        guard beaconNonce.count == 16 else {
            throw GHError.sizeMismatch(field: "beaconNonce", expected: 16, got: beaconNonce.count)
        }
        guard transcriptHash.count == 32 else {
            throw GHError.sizeMismatch(field: "transcriptHash", expected: 32, got: transcriptHash.count)
        }
        var rnd = Data(count: GHConstants.challengeBytes)
        let status = rnd.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, GHConstants.challengeBytes, base)
        }
        guard status == errSecSuccess else {
            throw GHError.randomFailure
        }
        return GHChallenge(
            cA: rnd,
            beaconEpoch: beaconEpoch,
            beaconNonce: beaconNonce,
            transcriptHash: transcriptHash
        )
    }
}

/// Canonical-bytes builder for the HMAC input. Used by both the
/// responder (to compute its MAC) and the verifier (to compute the
/// expected MAC). Producing the same bytes both sides = correctness
/// invariant of Ghost Handshake.
enum GHMACInput {

    /// Build the exact byte sequence that gets fed into HMAC.
    /// Layout (length-prefixed where variable):
    ///
    ///   domainString                      (variable, fixed at compile time)
    ///   role                              (1 byte)
    ///   version                           (1 byte)
    ///   cA                                (16 bytes, fixed)
    ///   cB                                (16 bytes, fixed)
    ///   beaconEpoch (big-endian uint32)   (4 bytes)
    ///   beaconNonce                       (16 bytes, fixed)
    ///   transcriptHash                    (32 bytes, fixed)
    ///
    /// All fixed-length fields are byte-position-stable, so no
    /// length prefix is needed.
    static func canonicalBytes(role: GHConstants.Role,
                               challenge: GHChallenge,
                               cB: Data) -> Data {
        precondition(challenge.cA.count == GHConstants.challengeBytes)
        precondition(cB.count == GHConstants.challengeBytes)
        precondition(challenge.beaconNonce.count == 16)
        precondition(challenge.transcriptHash.count == 32)

        var out = Data()
        out.reserveCapacity(
            GHConstants.domainString.count + 1 + 1
            + GHConstants.challengeBytes * 2
            + 4 + 16 + 32
        )

        out.append(GHConstants.domainString)
        out.append(role.rawValue)
        out.append(GHConstants.version)
        out.append(challenge.cA)
        out.append(cB)
        out.append(uint32BE(challenge.beaconEpoch))
        out.append(challenge.beaconNonce)
        out.append(challenge.transcriptHash)

        return out
    }

    private static func uint32BE(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8)  & 0xFF),
            UInt8(value & 0xFF),
        ])
    }
}
