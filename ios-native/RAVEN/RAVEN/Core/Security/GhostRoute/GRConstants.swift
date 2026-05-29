//
//  GRConstants.swift
//  RAVEN — Ghost Route (ATSAM Stage 5)
//
//  Ghost Route is the per-message recipient-tag layer. When a
//  message moves through a mesh of relays, no relay should learn
//  who the final recipient is. Stable recipient identifiers
//  (username, phone number, public key) would let any relay build
//  a social graph from observed traffic alone.
//
//  Construction (ATSAM PDF §16, with k_route from the ATSAM
//  key tree):
//
//      For per-message nonce n_msg (16 random bytes):
//        recipient_tag = Trunc_128(HMAC(K_route_AB,
//                                       "ATSAM/v1/GhostRoute/recipient" ||
//                                       n_msg))
//
//      Envelope on wire:
//        route_version || recipient_tag || n_msg || encrypted_payload
//
//      Relays see only:
//        • A 128-bit tag that LOOKS random to anyone without K_route
//        • An opaque encrypted_payload they cannot read
//
//      Receiver-side matching:
//        For every active pair, compute the expected
//        recipient_tag with that pair's K_route + the received
//        n_msg. If any matches, that's the addressed pair.
//        Constant-time compare per pair.
//
//  Properties:
//    • Per-message tag (n_msg is fresh per message) ⇒ relays
//      cannot link successive envelopes to the same recipient.
//    • The encrypted_payload is opaque; relays cannot read content.
//    • The sender is not in the envelope (Sealed Sender style
//      sender hiding lives at a different layer).
//
//  Honest limits (PDF §16):
//    • Relays still see timing + envelope size patterns. Defeating
//      global passive traffic analysis requires cover traffic +
//      shaping, which is a separate concern.
//    • A relay set that controls a large fraction of mesh nodes
//      (Sybil) can correlate timing across hops even with rotating
//      tags. This is a known residual risk.
//

import Foundation

enum GRConstants {

    // MARK: - Wire format

    /// Magic bytes (4 ASCII) prepended to every Ghost Route
    /// envelope. Lets a receiver quickly recognise the envelope
    /// type before any crypto.
    static let envelopeMagic: [UInt8] = [0x47, 0x52, 0x31, 0x21]  // "GR1!"

    /// Protocol version byte.
    static let version: UInt8 = 0x01

    // MARK: - Sizes (bytes)

    /// Recipient-tag width on the wire. 16 bytes / 128 bits ⇒
    /// random-collision probability ≤ M · 2⁻¹²⁸ per envelope
    /// where M = number of active pairings on the receiver,
    /// astronomically low.
    static let recipientTagBytes: Int = 16

    /// Per-message nonce length. 16 bytes / 128 bits — fresh
    /// per envelope, public, drives tag rotation.
    static let nonceBytes: Int = 16

    /// Header size in bytes: magic(4) + version(1) + reserved(1)
    /// + recipientTag(16) + nonce(16) + payloadLen(4) = 42.
    static let headerSize: Int = 42

    // MARK: - HMAC input domain

    /// String prepended to the HMAC input for recipient-tag
    /// derivation. Defeats cross-protocol HMAC confusion.
    static let recipientTagDomain: Data =
        Data("ATSAM/v1/GhostRoute/recipient".utf8)
}
