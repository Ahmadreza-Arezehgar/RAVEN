//
//  GHConstants.swift
//  RAVEN — Ghost Handshake (ATSAM Stage 4)
//
//  Ghost Handshake turns a BBE candidate detection into a verified
//  live peer. After Stage 2's BBE detector returns a `BBECandidate`,
//  the application MUST issue a fresh challenge and verify the
//  response before treating the peer as present. This prevents the
//  trivial replay attack where an attacker records yesterday's
//  beacon at location X and re-broadcasts it today at location Y
//  to make the UI lie about presence.
//
//  Construction (ATSAM PDF §15, with role-binding fix from v3.1):
//
//      Initiator A → Responder B:
//          c_A := 16 random bytes (CSPRNG)
//          msg1 = c_A || epoch t || beacon_nonce r
//
//      B computes and returns:
//          response_B = HMAC(K_live_AB,
//                            "ATSAM/v1/GhostHandshake" ||
//                            role=0x02 || version=0x01 ||
//                            c_A || c_B || epoch || beacon_nonce ||
//                            transcript_hash)
//          where c_B := 16 random bytes (CSPRNG) chosen by B,
//          carried alongside the response so A can verify.
//
//      A verifies:
//          expected = HMAC(K_live_AB,
//                          "ATSAM/v1/GhostHandshake" ||
//                          role=0x02 || version=0x01 ||
//                          c_A || c_B || epoch || beacon_nonce ||
//                          transcript_hash)
//          constant_time_eq(response_B, expected) ⇒ live peer.
//
//  Properties:
//
//    • Replay resistance: c_A is fresh per attempt, so a recorded
//      old response cannot satisfy a new challenge.
//    • Role binding: explicit `role` byte (0x01 = initiator,
//      0x02 = responder) defeats reflection (A's challenge replayed
//      back to A as its own response).
//    • Transcript binding: optional `transcript_hash` ties the
//      handshake to the pairing transcript, so a man-in-the-middle
//      who acquired K_live cannot relay a challenge between
//      contexts.
//
//  Reference: ATSAM PDF §15 (Ghost Handshake), with role-binding
//  fix from our BBE v3.1 review (m6).
//

import Foundation

enum GHConstants {

    // MARK: - Version + sizes

    /// Protocol version for Ghost Handshake. Bumped only for a
    /// breaking change.
    static let version: UInt8 = 0x01

    /// Length of the random challenge `c_A` (initiator) and `c_B`
    /// (responder). 16 bytes / 128 bits — birthday-bound at 2⁻⁶⁴
    /// collision over the lifetime of a single pair (~10²⁰
    /// challenges).
    static let challengeBytes: Int = 16

    /// Length of the response MAC. HMAC-SHA256 truncated to 32 B
    /// (full output, no truncation — the MAC is on the hot path
    /// but only fires once per detection, so we don't need to
    /// shrink it).
    static let responseBytes: Int = 32

    // MARK: - Role discriminator (m6 of BBE v3.1 review)

    /// Role byte values. Always present in the MAC input to
    /// prevent reflection attacks where an adversary replays the
    /// challenger's own challenge back to it as a "response".
    enum Role: UInt8 {
        /// Initiator: the side that issues `c_A`.
        case initiator = 0x01
        /// Responder: the side that produces the MAC.
        case responder = 0x02
    }

    // MARK: - HMAC input domain

    /// Domain string prepended to every HMAC input. Defeats
    /// cross-protocol confusion (a Ghost Handshake response is
    /// distinguishable from any other HMAC under K_live).
    static let domainString: Data = Data("ATSAM/v1/GhostHandshake".utf8)

    // MARK: - Challenge freshness window

    /// How many epochs after the original BBE beacon a Ghost
    /// Handshake challenge is still accepted. Tight bound so
    /// queued or delayed challenges don't extend the attack
    /// window. 2 epochs = 10 minutes at the v1 epoch length.
    static let acceptableChallengeAgeEpochs: UInt32 = 2
}
